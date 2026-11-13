import Foundation
import Network

struct EnrichmentStatus: Sendable, Equatable {
    var enriched = 0
    var failed = 0
    var episodes = 0
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
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
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
                if status.online, await backfillEmbedding() { continue }
                if status.online, status.hasKey, await summarizeEpisode() { continue }
                await waitForWork(timeout: .seconds(30))
                continue
            }
            // A question is being answered: let it have the endpoint first.
            while await ai.questionsInFlight > 0 { try? await Task.sleep(for: .milliseconds(300)) }
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

    /// Adds a vector to one older record when embeddings became available later. Returns
    /// whether it did any work (so the loop keeps going until none are missing).
    private func backfillEmbedding() async -> Bool {
        guard await ai.embeddingsEnabled, let record = await store.missingEmbeddings(limit: 1).first else { return false }
        let model = await ai.embedModelName
        guard let vector = try? await ai.embed(Self.passage(for: record), as: .passage) else { return false }
        await store.setEmbedding(id: record.id, vector, model: model)
        return true
    }

    /// Title + summary for one settled episode whose frames changed. Returns whether it worked.
    private func summarizeEpisode() async -> Bool {
        guard let (episode, records) = await store.episodeNeedingSummary(settle: 90) else { return false }
        let enriched = records.filter { $0.status == .enriched }.count
        do {
            let result = try await ai.chatJSON(EpisodeSummary.self, system: MemoryPrompts.episodeSystem,
                                               user: MemoryPrompts.episodeUser(episode, records: records),
                                               jsonSchema: MemoryPrompts.episodeSchema, schemaName: "episode",
                                               maxTokens: 300, temperature: 0.2)
            await store.setEpisodeSummary(id: episode.id, title: result.title, summary: result.summary, summarizedCount: enriched)
            Log.pipeline.info("episode \(episode.id): \(result.title ?? "-", privacy: .public) (\(records.count) frames)")
            status.episodes += 1
            return true
        } catch {
            // Do not retry in a tight loop: mark as done for now, the next new frame re-opens it.
            await store.setEpisodeSummary(id: episode.id, title: episode.title, summary: episode.summary, summarizedCount: enriched)
            Log.net.error("episode \(episode.id) summary failed: \((error as? LocalizedError)?.errorDescription ?? "", privacy: .public)")
            return false
        }
    }

    static func passage(for r: MemoryRecord) -> String {
        [r.kind, r.name, r.caption, r.otherText, r.visual, r.keywords, r.street, r.ocrText]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func enrich(_ record: MemoryRecord) async throws {
        let jpeg = try Data(contentsOf: store.frameURL(record))
        func extract(temperature: Double) async throws -> ExtractedRecord {
            try await ai.chatJSON(
                ExtractedRecord.self,
                system: MemoryPrompts.extractionSystem,
                user: MemoryPrompts.extractionUser(ocr: record.ocrText),
                image: .init(jpeg: jpeg),
                jsonSchema: MemoryPrompts.extractionSchema,
                schemaName: "memory_record",
                maxTokens: 2500,      // 8-15 objects + pictures; 800 / 1600 cut JSON off
                temperature: temperature
            )
        }
        var extracted: ExtractedRecord
        do {
            extracted = try await extract(temperature: 0.2)
        } catch NemotronClient.NemotronError.badResponse(let why) {
            // Broken / cut-off JSON: one more try, deterministic.
            Log.pipeline.info("enrich \(record.id): bad JSON (\(why.prefix(60), privacy: .public)), retrying at temperature 0")
            extracted = try await extract(temperature: 0)
        }
        // Nothing worth remembering (blur, floor, ceiling, a close-up of a person): drop the frame.
        if extracted.useful == false {
            await store.delete(id: record.id)
            Log.pipeline.info("enriched \(record.id): not useful, deleted")
            return
        }
        // Each literal must be on the OCR line the model cited, whatever the model said.
        extracted = ExtractionCheck.verify(extracted, ocr: record.ocrText)

        let passage = [extracted.kindLabel, extracted.name, extracted.caption, extracted.other_text, extracted.visualText,
                       extracted.searchKeywords.joined(separator: " "), record.street, record.ocrText]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let model = await ai.embedModelName
        let vector = try? await ai.embed(passage, as: .passage)
        await store.applyEnrichment(id: record.id, record: extracted, embedding: vector, model: model)
        Log.pipeline.info("enriched \(record.id): \(extracted.kindLabel ?? "-", privacy: .public) / \(extracted.name ?? "-", privacy: .public) · \(extracted.objects.count) things, \(extracted.depictions.count) pictures")
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
