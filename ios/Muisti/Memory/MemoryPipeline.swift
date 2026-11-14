import Foundation

struct PipelineStats: Sendable, Equatable {
    var kept = 0
    var dropped: [DropReason: Int] = [:]

    var droppedTotal: Int { dropped.values.reduce(0, +) }
    var droppedSummary: String {
        DropReason.allCases.compactMap { reason in dropped[reason].map { "\(reason.label) \($0)" } }.joined(separator: ", ")
    }
}

/// Frame → (optional raw dataset copy) → perception on the phone → memory store → enrichment.
/// Runs off the main actor, one frame at a time, in capture order.
actor MemoryPipeline {
    let recorder: SessionRecorder
    let store: MemoryStore
    let worker: EnrichmentWorker
    private let perception = PerceptionEngine()
    private var recordRaw = false
    private var streamEveryN = 5
    private var streamCounter = 0
    private(set) var stats = PipelineStats()
    /// A frame with text was just kept (id, text read on it, blurred keyframe): the safety
    /// rules look at the text right away, before the slower image enrichment.
    private var onTextStored: (@Sendable (Int64, String, Data) async -> Void)?

    /// Kept frames wait here a few seconds before they are stored: if a private scene (bathroom,
    /// PIN pad…) comes into view meanwhile, the frames just before it are dropped too, since
    /// walking into such a room is often seen a moment before the classifier is sure.
    /// (From the Android side's hold buffer.) Frames added by hand skip it.
    private struct Held {
        let memory: NewMemory
        let frame: CapturedFrame
        let replaces: Int64?
        let heldAt: Date
    }
    private var held: [Held] = []
    static let holdSeconds: TimeInterval = 3
    private var flushTask: Task<Void, Never>?

    func setOnTextStored(_ handler: @escaping @Sendable (Int64, String, Data) async -> Void) { onTextStored = handler }

    init(recorder: SessionRecorder, store: MemoryStore, worker: EnrichmentWorker) {
        self.recorder = recorder
        self.store = store
        self.worker = worker
    }

    func configure(recordRaw: Bool, streamEveryN: Int, zones: [NoRecordZone]) async {
        self.recordRaw = recordRaw
        self.streamEveryN = max(1, streamEveryN)
        await perception.configure(zones: zones)
    }

    /// Returns the new memory id if the frame was kept.
    func handle(_ frame: CapturedFrame, street: String?, area: String? = nil) async -> Int64? {
        if recordRaw { await recorder.write(frame) }
        if frame.trigger == .stream {
            // OCR on every 7 fps frame would burn the battery; look at one in N.
            streamCounter += 1
            guard streamCounter % streamEveryN == 0 else { return nil }
        }
        let began = ContinuousClock.now
        let privateBefore = PerceptionEngine.lastPrivateScene.withLock { $0 }
        let outcome = await perception.process(frame, street: street, area: area)
        let perceptionMs = (ContinuousClock.now - began).milliseconds
        if PerceptionEngine.lastPrivateScene.withLock({ $0 }) > privateBefore {
            // A private scene: what was seen in the seconds before it is not kept either.
            let dropped = held.filter { frame.capturedAt.timeIntervalSince($0.frame.capturedAt) <= Self.holdSeconds }
            held.removeAll { frame.capturedAt.timeIntervalSince($0.frame.capturedAt) <= Self.holdSeconds }
            if !dropped.isEmpty { Trace.note("\(dropped.count) held frame(s) dropped: private scene followed") }
        }
        await release(before: frame.capturedAt.addingTimeInterval(-Self.holdSeconds), wallClock: false)
        switch outcome {
        case .drop(let reason):
            stats.dropped[reason, default: 0] += 1
            return nil
        case .keep(let memory, _, let replaces) where frame.trigger != .manual:
            held.append(Held(memory: memory, frame: frame, replaces: replaces, heldAt: Date()))
            scheduleFlush()
            return nil
        case .keep(let memory, _, let replaces):
            return await persist(memory, frame: frame, replaces: replaces, perceptionMs: perceptionMs)
        }
    }

    /// Stores held frames captured before `cutoff` (capture time), or held for the full wait
    /// on the wall clock when nothing newer arrives.
    private func release(before cutoff: Date, wallClock: Bool) async {
        let now = Date()
        let ready = held.filter { wallClock ? now.timeIntervalSince($0.heldAt) >= Self.holdSeconds : $0.frame.capturedAt <= cutoff }
        guard !ready.isEmpty else { return }
        held.removeAll { item in ready.contains { $0.frame.capturedAt == item.frame.capturedAt } }
        for item in ready {
            _ = await persist(item.memory, frame: item.frame, replaces: item.replaces, perceptionMs: 0)
        }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.holdSeconds + 0.1))
            guard !Task.isCancelled else { return }
            await self?.release(before: .distantPast, wallClock: true)
            if await self?.held.isEmpty == false { await self?.scheduleFlush() }
        }
    }

    private func persist(_ memory: NewMemory, frame: CapturedFrame, replaces: Int64?, perceptionMs: Int) async -> Int64? {
        do {
            guard let id = await store.insert(memory) else {
                stats.dropped[.unreadable, default: 0] += 1
                return nil
            }
            await perception.didStore(id: id, capturedAt: frame.capturedAt)
            if let old = replaces {
                await store.delete(id: old)
                stats.dropped[.duplicate, default: 0] += 1
            } else {
                stats.kept += 1
            }
            await worker.signal()
            Trace.note("frame #\(id) kept: perception \(perceptionMs) ms, stored \(String(format: "%.1f", Date().timeIntervalSince(frame.capturedAt))) s after capture, \(memory.ocrText.count) chars read")
            if let onTextStored, memory.ocrText.contains(where: \.isLetter) {
                let text = memory.ocrText, jpeg = memory.frameJPEG
                Task { await onTextStored(id, text, jpeg) }
            }
            return id
        }
    }
}
