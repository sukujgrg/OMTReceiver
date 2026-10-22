import Foundation
@preconcurrency import Network
#if canImport(FoundationXML)
import FoundationXML
#endif

/// One source connection, with independent TCP streams for video/metadata and
/// audio. Network reads and callbacks never run on the main thread. Reconnection
/// belongs to the session owner, which must reject callbacks from older sessions.
final class OMTConnection: @unchecked Sendable {
    private enum Role: String { case video = "Video", audio = "Audio" }
    // Network.framework delivers every callback on the connection's one queue.
    private final class Lane: @unchecked Sendable {
        let role: Role
        let connection: NWConnection
        var parser = OMTProtocolParser()
        var ready = false

        init(role: Role, endpoint: NWEndpoint) {
            self.role = role
            let options = NWProtocolTCP.Options()
            options.noDelay = true
            options.connectionTimeout = 8
            let parameters = NWParameters(tls: nil, tcp: options)
            parameters.includePeerToPeer = true
            connection = NWConnection(to: endpoint, using: parameters)
        }
    }

    private let endpoint: NWEndpoint
    private let queue = DispatchQueue(label: "org.openmediatransport.receiver.network", qos: .userInitiated)
    private let mailbox: OMTPacketMailbox
    private let onState: @Sendable (OMTConnectionState) -> Void
    private var lanes: [Role: Lane] = [:] // network queue only
    private var started = false
    private var quality: OMTQuality = .default
    private var programTally = true

    init(endpoint: NWEndpoint, onPacket: @escaping @Sendable (OMTPacket) -> Void,
         onState: @escaping @Sendable (OMTConnectionState) -> Void) {
        self.endpoint = endpoint
        self.mailbox = OMTPacketMailbox(onPacket: onPacket)
        self.onState = onState
    }

    func start() {
        queue.async { [self] in
            guard mailbox.isOpen, !started else { return }
            started = true
            onState(.connecting)
            for role in [Role.video, .audio] {
                let lane = Lane(role: role, endpoint: endpoint)
                lanes[role] = lane
                lane.connection.stateUpdateHandler = { [weak self, weak lane] state in
                    guard let self, let lane, self.admits(lane) else { return }
                    self.changed(state, lane: lane)
                }
                lane.connection.start(queue: queue)
            }
        }
    }

    /// Closes admission immediately, then cancels sockets asynchronously. It
    /// never waits for TCP, decoding, or an already admitted callback to finish.
    func stop() {
        mailbox.close()
        queue.async { [self] in cancelLanes() }
    }

    func sendQuality(_ value: OMTQuality) {
        queue.async { [self] in
            guard mailbox.isOpen else { return }
            quality = value
            if let lane = lanes[.video], lane.ready { send([OMTCommands.quality(value)], lane: lane) }
        }
    }

    func setTally(program: Bool) {
        queue.async { [self] in
            guard mailbox.isOpen else { return }
            programTally = program
            if let lane = lanes[.video], lane.ready { send([OMTCommands.tally(program: program)], lane: lane) }
        }
    }

    private func admits(_ lane: Lane) -> Bool { mailbox.isOpen && lanes[lane.role] === lane }

    private func changed(_ state: NWConnection.State, lane: Lane) {
        switch state {
        case .ready:
            guard !lane.ready else { return }
            lane.ready = true
            if lane.role == .video {
                send([OMTCommands.subscribeMetadata, OMTCommands.fullResolution, OMTCommands.subscribeVideo,
                      OMTCommands.quality(quality), OMTCommands.tally(program: programTally)], lane: lane)
                if mailbox.isOpen { onState(.connected) }
            } else {
                send([OMTCommands.subscribeAudio], lane: lane)
            }
            receive(lane)
        case .failed(let error), .waiting(let error):
            finish(.failed("\(lane.role.rawValue) connection failed: \(error.localizedDescription)"))
        case .cancelled:
            finish(lane.role == .audio ? .failed("Audio connection closed.") : .disconnected)
        default: break
        }
    }

    private func send(_ commands: [String], lane: Lane) {
        guard admits(lane) else { return }
        let bytes = commands.reduce(into: Data()) { $0.append(OMTCommands.frame($1)) }
        lane.connection.send(content: bytes, completion: .contentProcessed { [weak self, weak lane] error in
            guard let self, let lane, self.admits(lane), let error else { return }
            self.finish(.failed("\(lane.role.rawValue) subscription failed: \(error.localizedDescription)"))
        })
    }

    private func receive(_ lane: Lane) {
        guard admits(lane) else { return }
        lane.connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1_024) { [weak self, weak lane] data, _, complete, error in
            guard let self, let lane, self.admits(lane) else { return }
            do {
                if let data, !data.isEmpty {
                    try lane.parser.append(data) { [self] packet in self.handle(packet, lane: lane) }
                }
            } catch {
                self.finish(.failed(error.localizedDescription))
                return
            }
            guard self.admits(lane) else { return }
            if let error {
                self.finish(.failed("\(lane.role.rawValue) receive failed: \(error.localizedDescription)"))
            } else if complete {
                self.finish(lane.role == .audio ? .failed("The source closed its audio connection.") : .disconnected)
            } else {
                self.receive(lane)
            }
        }
    }

    private func handle(_ packet: OMTPacket, lane: Lane) {
        guard admits(lane) else { return }
        switch packet {
        case .video where lane.role != .video, .audio where lane.role != .audio:
            finish(.failed("The source sent media on an unsubscribed OMT connection."))
            return
        case .metadata(let string) where string.hasPrefix("<OMTRedirect"):
            do {
                let target = try OMTRedirectMetadata.destination(string)
                if !target.isEmpty {
                    finish(.failed("This source redirects to \(target). Connect directly to that source; router redirects are not supported in this prototype."))
                    return
                }
            } catch {
                finish(.failed(error.localizedDescription))
                return
            }
        default: break
        }
        if !mailbox.offer(packet), mailbox.isOpen {
            finish(.failed("The receiver could not keep up with OMT audio or metadata. Its bounded input queue filled."))
        }
    }

    private func finish(_ state: OMTConnectionState) {
        guard mailbox.close() else { return }
        cancelLanes()
        onState(state)
    }

    private func cancelLanes() {
        let old = lanes
        lanes.removeAll()
        for lane in old.values {
            lane.connection.stateUpdateHandler = nil
            lane.connection.cancel()
        }
    }

    deinit {
        mailbox.close()
        for lane in lanes.values { lane.connection.cancel() }
    }
}

/// Network callbacks offer directly under a short lock, so a slow decoder cannot
/// accumulate one dispatch closure per frame. One video replaces its predecessor;
/// audio is bounded and never silently dropped. Callbacks execute serially.
final class OMTPacketMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private let delivery = DispatchQueue(label: "org.openmediatransport.receiver.delivery", qos: .userInitiated)
    private let onPacket: @Sendable (OMTPacket) -> Void
    private var open = true
    private var scheduled = false
    private var video: OMTPacket?
    private var audio: [OMTAudioFrame] = []
    private var metadata: [String] = []
    private var audioBytes = 0
    private var metadataBytes = 0

    init(onPacket: @escaping @Sendable (OMTPacket) -> Void) { self.onPacket = onPacket }

    var isOpen: Bool { lock.withLock { open } }

    @discardableResult
    func offer(_ packet: OMTPacket) -> Bool {
        let result: (Bool, Bool) = lock.withLock {
            guard open else { return (false, false) }
            switch packet {
            case .video:
                video = packet
            case .audio(let frame):
                guard audio.count < 32, audioBytes + frame.payload.count <= 2 * 1_024 * 1_024 else { return (false, false) }
                audio.append(frame)
                audioBytes += frame.payload.count
            case .metadata(let string):
                let size = string.utf8.count
                guard metadata.count < 32, metadataBytes + size <= 128 * 1_024 else { return (false, false) }
                metadata.append(string)
                metadataBytes += size
            }
            let shouldSchedule = !scheduled
            scheduled = true
            return (true, shouldSchedule)
        }
        if result.1 { delivery.async { [weak self] in self?.drain() } }
        return result.0
    }

    @discardableResult
    func close() -> Bool {
        lock.withLock {
            let wasOpen = open
            open = false
            video = nil
            audio.removeAll()
            metadata.removeAll()
            audioBytes = 0
            metadataBytes = 0
            return wasOpen
        }
    }

    private func drain() {
        let packets: [OMTPacket] = lock.withLock {
            guard open else { scheduled = false; return [] }
            var result: [OMTPacket] = []
            if !audio.isEmpty {
                let frame = audio.removeFirst()
                audioBytes -= frame.payload.count
                result.append(.audio(frame))
            }
            if let video { result.append(video); self.video = nil }
            if !metadata.isEmpty {
                let string = metadata.removeFirst()
                metadataBytes -= string.utf8.count
                result.append(.metadata(string))
            }
            if result.isEmpty { scheduled = false }
            return result
        }
        guard !packets.isEmpty else { return }
        for packet in packets {
            guard isOpen else { return }
            onPacket(packet)
        }
        // Yield so this queue remains cancellable between callback batches.
        delivery.async { [weak self] in self?.drain() }
    }
}

enum OMTRedirectMetadata {
    static func destination(_ xml: String) throws -> String {
        guard !xml.localizedCaseInsensitiveContains("<!DOCTYPE"), !xml.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw OMTProtocolError.invalid("redirect declarations are unsupported.")
        }
        let delegate = RedirectXMLDelegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let address = delegate.address else {
            throw OMTProtocolError.invalid("invalid source redirect metadata.")
        }
        return address
    }
}

private final class RedirectXMLDelegate: NSObject, XMLParserDelegate {
    var address: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "OMTRedirect" { address = attributeDict["NewAddress"] }
    }
}
