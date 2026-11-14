import Foundation
import os

/// The recogniser's final pass for one listening session. Partial results are a first guess
/// that the recogniser revises once the audio ends; asking with the last partial (what Muisti
/// did) sent half-heard words to the model. `wait(timeout:)` returns the final text, or nil if
/// it does not come in time (the caller then keeps the last partial).
final class FinalTranscript: @unchecked Sendable {
    private struct State {
        var text: String?
        var done = false
        var waiter: CheckedContinuation<String?, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// From the recognition callback: the final text, or nil on error.
    func deliver(_ text: String?) {
        let waiter = state.withLock { s -> CheckedContinuation<String?, Never>? in
            guard !s.done else { return nil }
            s.done = true
            s.text = text
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(returning: text)
    }

    func wait(timeout: Double) async -> String? {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { s -> (Bool, String?) in
                if s.done { return (true, s.text) }
                s.waiter = continuation
                return (false, nil)
            }
            if ready.0 { continuation.resume(returning: ready.1); return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.expire()
            }
        }
    }

    private func expire() {
        let waiter = state.withLock { s -> CheckedContinuation<String?, Never>? in
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(returning: nil)
    }
}
