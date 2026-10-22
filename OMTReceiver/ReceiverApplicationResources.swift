import AVFoundation
import OSLog
import UIKit

/// The application owns this service; each receive attempt owns a distinct
/// lease. Implementations may finish a native activation after cancellation,
/// so the application wrapper always releases that exact lease on failure.
protocol ReceiverAudioSessionManaging: Sendable {
    func acquire(_ id: UUID) async throws
    func release(_ id: UUID) async
}

/// Device-wide resources have one application owner. Multiple future view slots
/// can share this owner; stopping a slot cannot deactivate another slot's audio.
@MainActor
final class ReceiverApplicationResources {
    private let audioSession: any ReceiverAudioSessionManaging
    private var receivingOwners: Set<UUID> = []

    init(audioSession: any ReceiverAudioSessionManaging = ReceiverAudioSessionWorker()) {
        self.audioSession = audioSession
    }

    func acquire(_ id: UUID) async throws {
        do {
            try Task.checkCancellation()
            try await audioSession.acquire(id)
            try Task.checkCancellation()
        } catch {
            await audioSession.release(id)
            throw error
        }
    }

    func setReceiving(_ receiving: Bool, for id: UUID) {
        if receiving { receivingOwners.insert(id) } else { receivingOwners.remove(id) }
        UIApplication.shared.isIdleTimerDisabled = !receivingOwners.isEmpty
    }

    func release(_ id: UUID) async {
        setReceiving(false, for: id)
        await audioSession.release(id)
    }
}

/// setCategory/setActive can block while Core Audio changes device routing.
/// Confine those operations and their lease state to one off-main serial lane.
final class ReceiverAudioSessionWorker: ReceiverAudioSessionManaging, @unchecked Sendable {
    typealias Operation = @Sendable (Bool) throws -> Void
    private let queue = DispatchQueue(label: "OMTReceiver.application-audio", qos: .userInitiated)
    private let operation: Operation
    private var owners: Set<UUID> = [] // Audio queue only.
    private let logger = Logger(subsystem: "com.suku.OMTReceiver", category: "Playback")

    init(operation: @escaping Operation = { active in
        let session = AVAudioSession.sharedInstance()
        if active {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }) { self.operation = operation }

    func acquire(_ id: UUID) async throws {
        let cancellation = AudioLeaseCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    do {
                        if !owners.contains(id) {
                            if owners.isEmpty { try operation(true) }
                            owners.insert(id)
                        }
                        // A native call already in progress cannot be cancelled.
                        // The wrapper checks cancellation after this completion
                        // and releases only this UUID before returning an error.
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    func release(_ id: UUID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if owners.remove(id) != nil, owners.isEmpty {
                    do { try operation(false) }
                    catch { logger.error("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)") }
                }
                continuation.resume()
            }
        }
    }
}

private final class AudioLeaseCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
