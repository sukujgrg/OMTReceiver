import Foundation

/// Compressed, self-contained VMX video frame. Timestamp units are 100 ns.
struct OMTVideoFrame: Sendable {
    let timestamp: Int64
    let codec: UInt32
    let width: Int
    let height: Int
    let frameRateN: Int
    let frameRateD: Int
    let aspectRatio: Float
    let flags: UInt32
    let colorSpace: Int
    let payload: Data
}

/// OMT stores both rate terms as signed 32-bit integers. Validate their ratio
/// without imposing a term size below that wire contract or changing metadata.
enum OMTFrameRate {
    static func isValid(numerator: Int, denominator: Int, maximum: Int) -> Bool {
        let terms = 1...Int(Int32.max)
        guard terms.contains(numerator), terms.contains(denominator), terms.contains(maximum) else { return false }
        // The product of two positive Int32 values fits in Int64.
        return Int64(numerator) <= Int64(denominator) * Int64(maximum)
    }
}

/// FPA1 keeps only the active planar Float32 channels on the wire. A missing
/// channel is silence, and is expanded by the audio renderer, not the transport.
struct OMTAudioFrame: Sendable {
    let timestamp: Int64
    let codec: UInt32
    let sampleRate: Int
    let samplesPerChannel: Int
    let channels: Int
    let activeChannels: UInt32
    let payload: Data
}

enum OMTPacket: Sendable {
    case video(OMTVideoFrame)
    case audio(OMTAudioFrame)
    case metadata(String)
}

enum OMTConnectionState: Sendable, Equatable {
    case connecting
    case connected
    case failed(String)
    case disconnected
}

enum OMTQuality: String, CaseIterable, Sendable, Identifiable {
    case `default` = "Default"
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }
}

enum OMTCodec {
    static let vmx1: UInt32 = 0x3158_4D56
    static let fpa1: UInt32 = 0x3141_5046
}
