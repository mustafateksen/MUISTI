import Foundation
import Network

struct EnrichmentStatus: Sendable, Equatable {
    var enriched = 0
    var failed = 0
    var online = true
    var hasKey = false
    var lastError: String?
}

/// Background queue that turns stored frames into structured records with Nemotron:
/// blurred keyframe + OCR text → {kind, name, phone, hours, …} (evidence rule applied) →
/// embedding. Lives entirely on the phone; pending rows survive app kills because the
/// queue *is* the database (`status = pending`). Offline / rate-limited: waits and resumes.
actor EnrichmentWorker {
    let statusStream: AsyncStream<EnrichmentStatus>
    private let statusContinuation: AsyncStream<EnrichmentStatus>.Continuation
    private(set) var status = EnrichmentStatus() {
        didSet { statusContinuation.yield(status) }
    }

    private let store: MemoryStore
    private let ai: NemotronClient
    private var worker: Task<Void, Never>?
    private var wakeup: CheckedContinuation<Void, Never>?
    private let monitor = NWPathMonitor()
    private var backoff: Double = 2

    init(store: MemoryStore, ai: NemotronClient) {
        self.store = store
        self.ai = ai
        (statusStream, statusContinuation) = AsyncStream.makeStream(of: EnrichmentStatus.self, bufferingPolicy: .bufferingNewest(1))
    }

    func start() {
        guard worker == nil else { return signal() }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { await self?.setOnline(online) }
        }
        monitor.start(queue: DispatchQueue(label: "fi.junction.muisti.enrich.path"))
        worker = Task { await self.run() }
    }

    func signal() {
        backoff = 2
        wakeup?.resume()
        wakeup = nil
    }

    private func setOnline(_ online: Bool) {
        status.online = online
        if online { signal() }
    }

    private func run() async {
        while !Task.isCancelled {
            status.hasKey = await ai.hasKey
            guard status.online, status.hasKey, let next = await store.pending(limit: 1).first else {
                await waitForWork(timeout: .seconds(30))
                continue
            }
            do {
                try await enrich(next)
                status.enriched += 1
                status.lastError = nil
                backoff = 2
            } catch {
                await store.markAttemptFailed(id: next.id)
                status.failed += 1
                status.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Log.net.error("enrich \(next.id) failed: \(self.status.lastError ?? "", privacy: .public)")
                if case NemotronClient.NemotronError.missingKey = error {
                    await waitForWork(timeout: .seconds(60))
                } else {
                    await waitForWork(timeout: .seconds(backoff))
                    backoff = min(backoff * 2, 60)
                }
            }
        }
    }

    private func enrich(_ record: MemoryRecord) async throws {
        let jpeg = try Data(contentsOf: store.frameURL(record))
        let time = record.seenAt.formatted(date: .abbreviated, time: .shortened)
        var extracted = try await ai.chatJSON(
            ExtractedRecord.self,
            system: MemoryPrompts.extractionSystem,
            user: MemoryPrompts.extractionUser(ocr: record.ocrText, street: record.street, time: time),
            image: .init(jpeg: jpeg),
            maxTokens: 500
        )
        // Evidence rule: literals the OCR does not contain are dropped, whatever the model said.
        extracted = EvidenceRule.clean(extracted, ocr: record.ocrText)

        let passage = [extracted.kind, extracted.name, extracted.caption, extracted.other_text,
                       extracted.keywords?.joined(separator: " "), record.street, record.ocrText]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let vector = try? await ai.embed(passage, as: .passage)
        await store.applyEnrichment(id: record.id, record: extracted, embedding: vector)
        Log.pipeline.info("enriched \(record.id): \(extracted.kind ?? "-", privacy: .public) / \(extracted.name ?? "-", privacy: .public)")
    }

    private var waitGeneration = 0

    private func waitForWork(timeout: Duration) async {
        waitGeneration += 1
        let generation = waitGeneration
        await withCheckedContinuation { continuation in
            wakeup = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeoutWake(generation)
            }
        }
    }

    /// Only wakes the wait it was scheduled for (a stale timer must not end a later wait).
    private func timeoutWake(_ generation: Int) {
        guard generation == waitGeneration else { return }
        wakeup?.resume()
        wakeup = nil
    }
}
