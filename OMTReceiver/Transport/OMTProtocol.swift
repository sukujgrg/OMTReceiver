import Foundation

enum OMTProtocolError: LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self { case .invalid(let message): return "Invalid OMT stream: \(message)" }
    }
}

/// Protocol 1.0 is little-endian, including its 16-byte TCP frame header.
/// This parser retains only a single bounded frame across arbitrary TCP splits.
struct OMTProtocolParser {
    static let maximumVideoBytes = 10 * 1_024 * 1_024
    static let maximumAudioBytes = 1_024 * 1_024
    static let maximumMetadataBytes = 65_535

    private struct Header {
        let type: UInt8
        let timestamp: Int64
        let metadataLength: Int
        let bodyLength: Int
        var extendedLength: Int { type == 2 ? 32 : type == 4 ? 24 : 0 }
    }

    private var header: Header?
    private var bytes = Data()
    var bufferedByteCount: Int { bytes.count }

    mutating func append(_ chunk: Data, onPacket: (OMTPacket) -> Void) throws {
        var cursor = chunk.startIndex
        while cursor < chunk.endIndex {
            let required = header?.bodyLength ?? 16
            let take = min(required - bytes.count, chunk.endIndex - cursor)
            if take > 0 {
                bytes.append(contentsOf: chunk[cursor..<(cursor + take)])
                cursor += take
            }
            guard bytes.count == required else { return }
            if let current = header {
                try decode(current, body: bytes, onPacket: onPacket)
                header = nil
                // Release a large payload instead of retaining its capacity for
                // the next 16-byte header (Data may be retained by the decoder).
                bytes = Data()
            } else {
                header = try decodeHeader(bytes)
                bytes = Data()
            }
        }
    }

    private func decodeHeader(_ data: Data) throws -> Header {
        guard data[0] == 1 else { throw OMTProtocolError.invalid("unsupported version \(data[0]).") }
        let type = data[1]
        guard type == 1 || type == 2 || type == 4 else {
            throw OMTProtocolError.invalid("unsupported frame type \(type).")
        }
        let count = Int(Int32(bitPattern: data.omtUInt32(at: 12)))
        let metadata = Int(data.omtUInt16(at: 10))
        let extended = type == 2 ? 32 : type == 4 ? 24 : 0
        let maximum = type == 2 ? Self.maximumVideoBytes : type == 4 ? Self.maximumAudioBytes : Self.maximumMetadataBytes
        guard count > 0, count >= extended + metadata, count <= extended + maximum + metadata,
              type != 1 || count <= Self.maximumMetadataBytes else {
            throw OMTProtocolError.invalid("frame length is outside the supported limit.")
        }
        return Header(type: type, timestamp: Int64(bitPattern: data.omtUInt64(at: 2)), metadataLength: metadata, bodyLength: count)
    }

    private func decode(_ header: Header, body: Data, onPacket: (OMTPacket) -> Void) throws {
        if header.type == 1 {
            onPacket(.metadata(try Self.string(body)))
            return
        }
        let end = body.count - header.metadataLength
        let payload = body.subdata(in: header.extendedLength..<end)
        let frameMetadata = header.metadataLength > 0 ? try Self.string(body.subdata(in: end..<body.count)) : nil
        if header.type == 2 {
            let width = body.omtInt(at: 4), height = body.omtInt(at: 8)
            let numerator = body.omtInt(at: 12), denominator = body.omtInt(at: 16)
            let aspect = Float(bitPattern: body.omtUInt32(at: 20))
            let color = body.omtInt(at: 28)
            guard (1...4_096).contains(width), (1...4_096).contains(height),
                  width * height <= 4_096 * 2_160,
                  (1...1_000_000).contains(numerator), (1...100_000).contains(denominator),
                  Double(numerator) / Double(denominator) <= 240,
                  aspect.isFinite, aspect > 0, aspect <= 100,
                  [0, 601, 709].contains(color), !payload.isEmpty else {
                throw OMTProtocolError.invalid("invalid video geometry, frame rate or color space.")
            }
            onPacket(.video(.init(timestamp: header.timestamp, codec: body.omtUInt32(at: 0), width: width, height: height,
                                  frameRateN: numerator, frameRateD: denominator, aspectRatio: aspect,
                                  flags: body.omtUInt32(at: 24), colorSpace: color, payload: payload)))
        } else {
            let rate = body.omtInt(at: 4), samples = body.omtInt(at: 8), channels = body.omtInt(at: 12)
            let active = body.omtUInt32(at: 16)
            guard body.omtUInt32(at: 0) == OMTCodec.fpa1,
                  (8_000...192_000).contains(rate), (1...rate).contains(samples), (1...32).contains(channels),
                  samples * channels * 4 <= Self.maximumAudioBytes else {
                throw OMTProtocolError.invalid("unsupported audio codec or invalid audio dimensions.")
            }
            let allowed: UInt32 = channels == 32 ? UInt32.max : (UInt32(1) << UInt32(channels)) - 1
            guard active & ~allowed == 0,
                  payload.count == active.nonzeroBitCount * samples * 4 else {
                throw OMTProtocolError.invalid("sparse audio channel mask does not match its payload.")
            }
            onPacket(.audio(.init(timestamp: header.timestamp, codec: OMTCodec.fpa1, sampleRate: rate,
                                  samplesPerChannel: samples, channels: channels, activeChannels: active, payload: payload)))
        }
        if let frameMetadata { onPacket(.metadata(frameMetadata)) }
    }

    private static func string(_ data: Data) throws -> String {
        // PROTOCOL.md and the C API describe null-terminated XML, but the
        // official sender's OMTChannel.Send -> OMTBuffer.FromMetadata encodes
        // exactly UTF8.GetBytes(xml), with no terminator. XMLToIntPtr adds NUL
        // only at the C API boundary. Accept either length-delimited wire form
        // or one terminal NUL, while rejecting embedded NUL and invalid UTF-8.
        let text = data.last == 0 ? data.dropLast() : data[...]
        guard !text.contains(0), let value = String(data: text, encoding: .utf8) else {
            throw OMTProtocolError.invalid("metadata must be valid UTF-8 without embedded null bytes.")
        }
        return value
    }
}

enum OMTCommands {
    static let subscribeVideo = "<OMTSubscribe Video=\"true\" />"
    static let subscribeAudio = "<OMTSubscribe Audio=\"true\" />"
    static let subscribeMetadata = "<OMTSubscribe Metadata=\"true\" />"
    static let fullResolution = "<OMTSettings Preview=\"false\" />"

    static func quality(_ value: OMTQuality) -> String { "<OMTSettings Quality=\"\(value.rawValue)\" />" }

    // The upstream protocol intentionally requires the double equals sign.
    static func tally(program: Bool) -> String { "<OMTTally Preview=\"false\" Program==\"\(program ? "true" : "false")\" />" }

    static func frame(_ string: String) -> Data {
        // Match the official wire encoder, not its null-terminated C API.
        // Its receiver decodes the entire length before exact-string matching;
        // a terminal NUL would make every subscription command fail to match.
        let payload = Data(string.utf8)
        precondition(!payload.isEmpty && !payload.contains(0) && payload.count <= OMTProtocolParser.maximumMetadataBytes)
        var data = Data([1, 1])
        data.omtAppend(UInt64(0))
        data.omtAppend(UInt16(0))
        data.omtAppend(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

extension Data {
    fileprivate func omtUInt16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    fileprivate func omtUInt32(at offset: Int) -> UInt32 {
        var result: UInt32 = 0
        for index in 0..<4 { result |= UInt32(self[startIndex + offset + index]) << UInt32(index * 8) }
        return result
    }

    fileprivate func omtUInt64(at offset: Int) -> UInt64 {
        UInt64(omtUInt32(at: offset)) | UInt64(omtUInt32(at: offset + 4)) << 32
    }

    fileprivate func omtInt(at offset: Int) -> Int { Int(Int32(bitPattern: omtUInt32(at: offset))) }

    mutating func omtAppend<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
