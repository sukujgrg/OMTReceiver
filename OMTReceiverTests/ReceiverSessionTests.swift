import AVFoundation
import Combine
import Network
import XCTest
@testable import OMTReceiver

@MainActor
final class ReceiverSessionTests: XCTestCase {
    private var subscriptions: Set<AnyCancellable> = []

    func testBrowsingAndReselectingCurrentSourceKeepTheSamePlaybackAndConnections() async throws {
        let lanes = expectation(description: "Initial video and audio lanes accepted")
        let server = try await makeServer(accepted: { count in if count == 2 { lanes.fulfill() } })
        defer { server.stop() }
        let session = ReceiverSession(applicationResources: ReceiverApplicationResources())
        defer { session.disconnect() }
        let source = try OMTSource.manual(address: "127.0.0.1:\(server.port)")
        let connected = next(.waitingForVideo, session: session)
        session.selectSource(source)
        await fulfillment(of: [connected, lanes], timeout: 5)
        let playback = session.playback
        let connections = server.acceptedConnectionCount
        for _ in 0..<50 {
            session.revealSources()
            XCTAssertTrue(session.sourcesVisible)
            session.revealControls()
            session.revealSources()
            session.selectSource(source)
            XCTAssertEqual(session.overlay, .hidden)
            await Task.yield()
        }
        XCTAssertTrue(session.playback === playback)
        XCTAssertEqual(server.acceptedConnectionCount, connections)
        XCTAssertEqual(session.selectedSource, source)
        XCTAssertEqual(session.phase, .waitingForVideo)
    }

    func testRapidSourceSwitchCannotBeOverwrittenByLatePreviousActivation() async throws {
        let first = expectation(description: "First source activation")
        let second = expectation(description: "Replacement source activation")
        let released = expectation(description: "Old source late activation released")
        let audio = ControlledReceiverAudioSession(requested: { count in
            if count == 1 { first.fulfill() }
            if count == 2 { second.fulfill() }
        }, firstReleased: { released.fulfill() })
        let oldServer = try await makeServer(), newServer = try await makeServer()
        defer { oldServer.stop(); newServer.stop() }
        let session = ReceiverSession(applicationResources: ReceiverApplicationResources(audioSession: audio))
        defer { session.disconnect() }
        let oldSource = try OMTSource.manual(address: "127.0.0.1:\(oldServer.port)")
        let newSource = try OMTSource.manual(address: "127.0.0.1:\(newServer.port)")
        session.selectSource(oldSource)
        await fulfillment(of: [first], timeout: 3)
        session.selectSource(newSource)
        await fulfillment(of: [second], timeout: 3)
        let leases = await audio.requestedIDs
        let old = try XCTUnwrap(leases.first), replacement = try XCTUnwrap(leases.last)
        let connected = next(.waitingForVideo, session: session)
        await audio.complete(replacement)
        await fulfillment(of: [connected], timeout: 5)
        let playback = session.playback
        await audio.complete(old)
        await fulfillment(of: [released], timeout: 3)
        XCTAssertEqual(session.selectedSource, newSource)
        XCTAssertTrue(session.playback === playback)
        XCTAssertEqual(oldServer.acceptedConnectionCount, 0)
        XCTAssertGreaterThan(newServer.acceptedConnectionCount, 0)
        let active = await audio.activeIDs
        XCTAssertEqual(active, [replacement])
    }

    func testSwitchingSourceDuringRetryCancelsOldSourceAndDisconnectStaysDisconnected() async throws {
        let oldServer = try await makeServer(), newServer = try await makeServer()
        defer { oldServer.stop(); newServer.stop() }
        let session = ReceiverSession(applicationResources: ReceiverApplicationResources())
        defer { session.disconnect() }
        let oldSource = try OMTSource.manual(address: "127.0.0.1:\(oldServer.port)")
        let newSource = try OMTSource.manual(address: "127.0.0.1:\(newServer.port)")
        let connected = next(.waitingForVideo, session: session)
        session.selectSource(oldSource)
        await fulfillment(of: [connected], timeout: 5)
        let failed = next(.reconnecting, session: session)
        oldServer.stop()
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertTrue(session.sourcesVisible)
        XCTAssertNotNil(session.message)
        let replaced = next(.waitingForVideo, session: session)
        session.selectSource(newSource)
        XCTAssertNil(session.message, "A new source must not display the previous source's failure.")
        await fulfillment(of: [replaced], timeout: 5)
        let playback = session.playback
        // Cross the old retry deadline: a stale retry must not revive that source.
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(session.selectedSource, newSource)
        XCTAssertTrue(session.playback === playback)
        session.disconnect()
        session.revealSources()
        session.dismissOverlay()
        XCTAssertTrue(session.controlsVisible)
        XCTAssertNil(session.selectedSource)
        XCTAssertEqual(session.phase, .idle)
    }

    func testFavouritesPersistWithoutInventingMissingSourcesAndRetainCurrentManualSource() throws {
        let suite = "OMTReceiver.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try OMTSource.manual(address: "127.0.0.1:6400")
        let favourite = try OMTSource.manual(address: "127.0.0.1:6401")
        let manual = try OMTSource.manual(address: "127.0.0.1:6402")
        let preferences = ReceiverSourcePreferences(defaults: defaults)
        preferences.toggleFavourite(favourite)
        let restored = ReceiverSourcePreferences(defaults: defaults)
        XCTAssertEqual(restored.orderedSources([first, favourite, first], selected: manual).map(\.id),
                       [favourite.id, first.id, manual.id])
        XCTAssertEqual(restored.orderedSources([], selected: manual), [manual])
        XCTAssertTrue(restored.orderedSources([], selected: nil).isEmpty)
        restored.toggleFavourite(favourite)
        XCTAssertTrue(ReceiverSourcePreferences(defaults: defaults).favourites.isEmpty)
    }

    func testFieldOrderChangeRebuildsSameSourceAndDoesNotRestartAfterDisconnect() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let session = ReceiverSession(applicationResources: ReceiverApplicationResources())
        defer { session.disconnect() }
        session.fieldOrder = .bottomFirst
        XCTAssertFalse(session.hasSelection)
        XCTAssertEqual(session.phase, .idle)
        let source = try OMTSource.manual(address: "127.0.0.1:\(server.port)")
        let connected = next(.waitingForVideo, session: session)
        session.connect(to: source)
        await fulfillment(of: [connected], timeout: 5)
        let old = session.playback
        let changed = next(.waitingForVideo, session: session)
        session.fieldOrder = .topFirst
        await fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(session.sourceName, source.name)
        XCTAssertFalse(session.playback === old, "The old field pipeline must be retired before applying a new order.")
        let current = session.playback
        session.fieldOrder = .topFirst
        XCTAssertTrue(session.playback === current, "An unchanged order must not restart playback.")
        session.disconnect()
        session.fieldOrder = .bottomFirst
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.hasSelection)
    }

    func testAudioInterruptionClosesAndRebuildsTheSelectedSource() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let session = ReceiverSession(applicationResources: ReceiverApplicationResources())
        defer { session.disconnect() }
        let source = try OMTSource.manual(address: "127.0.0.1:\(server.port)")
        let connected = next(.waitingForVideo, session: session)
        session.connect(to: source)
        await fulfillment(of: [connected], timeout: 5)
        let previousGraph = session.playback
        let interrupted = next(.suspended, session: session)
        postInterruption(.began)
        await fulfillment(of: [interrupted], timeout: 3)
        let resumed = next(.waitingForVideo, session: session)
        postInterruption(.ended, resume: true)
        await fulfillment(of: [resumed], timeout: 5)
        XCTAssertEqual(session.sourceName, source.name)
        XCTAssertFalse(session.playback === previousGraph, "A stopped AVFoundation graph must be replaced on interruption recovery.")
    }

    func testForegroundDoesNotRestartDuringAnAudioInterruption() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let session = ReceiverSession(applicationResources: ReceiverApplicationResources())
        defer { session.disconnect() }
        let connected = next(.waitingForVideo, session: session)
        session.connect(to: try OMTSource.manual(address: "127.0.0.1:\(server.port)"))
        await fulfillment(of: [connected], timeout: 5)
        session.audioInterruptionBegan()
        session.suspend()
        session.resume()
        XCTAssertEqual(session.phase, .suspended)
        let resumed = next(.waitingForVideo, session: session)
        session.audioInterruptionEnded(shouldResume: true)
        await fulfillment(of: [resumed], timeout: 5)
    }

    func testDisconnectDuringInterruptionPreventsResumeAndServiceResetRevival() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let session = ReceiverSession(applicationResources: ReceiverApplicationResources())
        let connected = next(.waitingForVideo, session: session)
        session.connect(to: try OMTSource.manual(address: "127.0.0.1:\(server.port)"))
        await fulfillment(of: [connected], timeout: 5)
        session.audioInterruptionBegan()
        session.disconnect()
        session.audioInterruptionEnded(shouldResume: true)
        session.audioServicesReset()
        session.resume()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.hasSelection)
    }

    func testMediaServicesResetReplacesRenderersWithoutChangingSource() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let session = ReceiverSession(applicationResources: ReceiverApplicationResources())
        defer { session.disconnect() }
        let source = try OMTSource.manual(address: "127.0.0.1:\(server.port)")
        let connected = next(.waitingForVideo, session: session)
        session.connect(to: source)
        await fulfillment(of: [connected], timeout: 5)
        let old = session.playback
        let recovered = next(.waitingForVideo, session: session)
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await fulfillment(of: [recovered], timeout: 5)
        XCTAssertFalse(session.playback === old)
        XCTAssertEqual(session.sourceName, source.name)
    }

    func testNativeAudioLeaseOperationsRunOffMainAndCancelCleanly() async throws {
        let entered = expectation(description: "Audio activation entered its worker")
        let probe = AudioOperationProbe(entered: entered, blocksFirstActivation: true)
        let resources = ReceiverApplicationResources(audioSession: ReceiverAudioSessionWorker(operation: { probe.perform($0) }))
        let lease = UUID()
        let activation = Task { try await resources.acquire(lease) }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertFalse(probe.events.contains { $0.onMain })
        // The native operation remains gated while MainActor still accepts work.
        let responsive = expectation(description: "Main actor remains responsive")
        Task { @MainActor in responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 1)
        activation.cancel()
        probe.unblock()
        do { try await activation.value; XCTFail("Cancelled activation must not return a lease") }
        catch { XCTAssertTrue(error is CancellationError) }
        await resources.release(lease)
        XCTAssertEqual(probe.events.map(\.active), [true, false])
        XCTAssertFalse(probe.events.contains { $0.onMain })
    }

    func testStoppingOneAudioLeasePreservesAnotherReceiver() async throws {
        let probe = AudioOperationProbe()
        let resources = ReceiverApplicationResources(audioSession: ReceiverAudioSessionWorker(operation: { probe.perform($0) }))
        let first = UUID(), second = UUID()
        try await resources.acquire(first)
        try await resources.acquire(second)
        await resources.release(first)
        XCTAssertEqual(probe.events.map(\.active), [true], "Another receiver still owns the device audio session")
        await resources.release(second)
        XCTAssertEqual(probe.events.map(\.active), [true, false])
    }

    func testLateCancelledActivationCannotReleaseTheReplacementAttempt() async throws {
        let first = expectation(description: "First lease requested")
        let second = expectation(description: "Replacement lease requested")
        let oldReleased = expectation(description: "Late old activation released its own lease")
        let audio = ControlledReceiverAudioSession(requested: { count in
            if count == 1 { first.fulfill() }
            if count == 2 { second.fulfill() }
        }, firstReleased: { oldReleased.fulfill() })
        let resources = ReceiverApplicationResources(audioSession: audio)
        let server = try await makeServer()
        defer { server.stop() }
        let session = ReceiverSession(applicationResources: resources)
        defer { session.disconnect() }
        let source = try OMTSource.manual(address: "127.0.0.1:\(server.port)")
        session.connect(to: source)
        await fulfillment(of: [first], timeout: 3)
        session.reconnect()
        await fulfillment(of: [second], timeout: 3)
        let leases = await audio.requestedIDs
        XCTAssertEqual(leases.count, 2)
        let old = try XCTUnwrap(leases.first), replacement = try XCTUnwrap(leases.last)
        XCTAssertNotEqual(old, replacement)
        let connected = next(.waitingForVideo, session: session)
        await audio.complete(replacement)
        await fulfillment(of: [connected], timeout: 5)
        let graph = session.playback
        await audio.complete(old)
        await fulfillment(of: [oldReleased], timeout: 3)
        let active = await audio.activeIDs
        XCTAssertEqual(active, [replacement])
        XCTAssertEqual(session.phase, .waitingForVideo)
        XCTAssertEqual(session.sourceName, source.name)
        // An unmatched or duplicate ended event must never create another
        // unowned transport or replace the currently healthy graph.
        session.audioInterruptionEnded(shouldResume: true)
        session.audioInterruptionEnded(shouldResume: true)
        XCTAssertTrue(session.playback === graph)
        let afterEnded = await audio.requestedIDs
        XCTAssertEqual(afterEnded, leases)
    }

    func testDisconnectWhileActivationIsPendingCannotReviveTransport() async throws {
        let requested = expectation(description: "Pending activation")
        let released = expectation(description: "Cancelled lease cleaned up after native completion")
        let audio = ControlledReceiverAudioSession(requested: { _ in requested.fulfill() }, firstReleased: { released.fulfill() })
        let server = try await makeServer()
        defer { server.stop() }
        let session = ReceiverSession(applicationResources: ReceiverApplicationResources(audioSession: audio))
        session.connect(to: try OMTSource.manual(address: "127.0.0.1:\(server.port)"))
        await fulfillment(of: [requested], timeout: 3)
        let requestedIDs = await audio.requestedIDs
        let lease = try XCTUnwrap(requestedIDs.first)
        session.disconnect()
        await audio.complete(lease)
        await fulfillment(of: [released], timeout: 3)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.hasSelection)
        XCTAssertEqual(server.acceptedConnectionCount, 0)
        let active = await audio.activeIDs
        XCTAssertTrue(active.isEmpty)
    }

    func testSessionDeinitDoesNotWaitForPendingAudioActivation() async throws {
        let requested = expectation(description: "Pending activation before deinit")
        let released = expectation(description: "Deinitialized session's late lease cleaned up")
        let audio = ControlledReceiverAudioSession(requested: { _ in requested.fulfill() }, firstReleased: { released.fulfill() })
        let resources = ReceiverApplicationResources(audioSession: audio)
        var session: ReceiverSession? = ReceiverSession(applicationResources: resources)
        let isSessionReleased = { [weak session] in session == nil }
        session?.connect(to: try OMTSource.manual(address: "127.0.0.1:6400"))
        await fulfillment(of: [requested], timeout: 3)
        let requestedIDs = await audio.requestedIDs
        let lease = try XCTUnwrap(requestedIDs.first)
        session = nil
        XCTAssertTrue(isSessionReleased(), "The suspended activation task must not retain its session")
        await audio.complete(lease)
        await fulfillment(of: [released], timeout: 3)
        let active = await audio.activeIDs
        XCTAssertTrue(active.isEmpty)
    }

    private func next(_ phase: ReceiverSession.Phase, session: ReceiverSession) -> XCTestExpectation {
        let expectation = expectation(description: "Session reaches \(phase)")
        session.$phase.dropFirst().filter { $0 == phase }.first().sink { _ in expectation.fulfill() }
            .store(in: &subscriptions)
        return expectation
    }

    private func postInterruption(_ type: AVAudioSession.InterruptionType, resume: Bool = false) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: NSNumber(value: type.rawValue),
            AVAudioSessionInterruptionOptionKey: NSNumber(value: resume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0)
        ])
    }

    private func makeServer(accepted: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> IdleOMTServer {
        let server = try IdleOMTServer(accepted: accepted)
        let ready = expectation(description: "Isolated TCP fixture ready")
        server.start { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 5)
        return server
    }
}

/// Holds accepted TCP lanes without sending media. It establishes a real
/// transport connection without a production source, external tools or sleeps.
private final class IdleOMTServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "OMTReceiver.tests.listener")
    private var clients: [NWConnection] = []
    private let countLock = NSLock()
    private let accepted: @Sendable (Int) -> Void
    private var acceptedCount = 0
    var port: UInt16 { listener.port!.rawValue }
    var acceptedConnectionCount: Int { countLock.lock(); defer { countLock.unlock() }; return acceptedCount }

    init(accepted: @escaping @Sendable (Int) -> Void = { _ in }) throws {
        self.accepted = accepted
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start(ready: @escaping @Sendable () -> Void) {
        listener.stateUpdateHandler = { state in if case .ready = state { ready() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.countLock.lock(); self.acceptedCount += 1; let count = self.acceptedCount; self.countLock.unlock()
            self.accepted(count)
            self.clients.append(connection)
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in clients.forEach { $0.cancel() }; clients.removeAll() }
    }
}

/// A native operation can finish after its caller is cancelled. Complete these
/// acquisitions in a controlled order to exercise that boundary without sleeps.
private actor ControlledReceiverAudioSession: ReceiverAudioSessionManaging {
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var requestedIDs: [UUID] = []
    private(set) var activeIDs: Set<UUID> = []
    private let requested: @Sendable (Int) -> Void
    private let firstReleased: @Sendable () -> Void
    private var reportedFirstRelease = false

    init(requested: @escaping @Sendable (Int) -> Void, firstReleased: @escaping @Sendable () -> Void) {
        self.requested = requested; self.firstReleased = firstReleased
    }
    func acquire(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation { pending[id] = $0; requestedIDs.append(id); requested(requestedIDs.count) }
    }
    func complete(_ id: UUID) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        activeIDs.insert(id)
        continuation.resume()
    }
    func release(_ id: UUID) async {
        if activeIDs.remove(id) != nil, id == requestedIDs.first, !reportedFirstRelease {
            reportedFirstRelease = true; firstReleased()
        }
    }
}

private final class AudioOperationProbe: @unchecked Sendable {
    struct Event { let active: Bool; let onMain: Bool }
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let entered: XCTestExpectation?
    private let blocksFirstActivation: Bool
    private var recorded: [Event] = []
    var events: [Event] { lock.lock(); defer { lock.unlock() }; return recorded }

    init(entered: XCTestExpectation? = nil, blocksFirstActivation: Bool = false) {
        self.entered = entered; self.blocksFirstActivation = blocksFirstActivation
    }
    func perform(_ active: Bool) {
        let onMain = Thread.isMainThread
        lock.lock()
        let first = recorded.isEmpty
        recorded.append(.init(active: active, onMain: onMain))
        lock.unlock()
        if first && active {
            entered?.fulfill()
            // A regression must fail its assertion instead of deadlocking the
            // main actor inside this controlled test fixture.
            if blocksFirstActivation && !onMain { gate.wait() }
        }
    }
    func unblock() { gate.signal() }
}
