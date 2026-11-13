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
    func handle(_ frame: CapturedFrame, street: String?) async -> Int64? {
        if recordRaw { await recorder.write(frame) }
        if frame.trigger == .stream {
            // OCR on every 7 fps frame would burn the battery; look at one in N.
            streamCounter += 1
            guard streamCounter % streamEveryN == 0 else { return nil }
        }
        switch await perception.process(frame, street: street) {
        case .drop(let reason):
            stats.dropped[reason, default: 0] += 1
            return nil
        case .keep(let memory, _, let replaces):
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
            return id
        }
    }
}
