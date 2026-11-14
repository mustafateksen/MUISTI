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
    /// Called with every newly enriched record (record id, title, its text, its embedding, keyframe): the
    /// safety rules check it against what was just understood, without another image call.
    private var onEnriched: (@Sendable (Int64, String?, String, [Float]?, Data?) async -> Void)?

    func setOnEnriched(_ handler: @escaping @Sendable (Int64, String?, String, [Float]?, Data?) async -> Void) { onEnriched = handler }

    /// What the agent needs from a freshly enriched record.
    struct Noticed: Sendable {
        var recordID: Int64
        var seenAt: Date
        var title: String?
        var passage: String
        var vector: [Float]?
        var jpeg: Data
        /// The enrichment's own flag ("none", "warning", "time_limited", …) and its one-line reason.
        var attention: String?
        var reason: String?
    }

    private var onNoticed: (@Sendable (Noticed) async -> Void)?
    func setOnNoticed(_ handler: @escaping @Sendable (Noticed) async -> Void) { onNoticed = handler }

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

    /// Set by `signal()`, cleared when the loop looks for work. A signal that arrives while the
    /// loop is busy elsewhere (reading the queue, a backfill, a summary) is kept: before this a
    /// new frame could sit for the full 30 s idle wait.
    private var signaled = false

    func signal() {
        backoff = 2
        signaled = true
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
            signaled = false
            guard status.online, status.hasKey, let next = await store.pending(limit: 1).first else {
                if status.online, await backfillEmbedding() { continue }
                if status.online, await backfillImageEmbedding() { continue }
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
            } catch NemotronClient.NemotronError.preempted {
                // A question took the endpoint; try this frame again right after it.
                continue
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

    /// Adds a keyframe vector to one older record (frames from before image vectors, or a model
    /// change). Returns whether it did any work.
    private func backfillImageEmbedding() async -> Bool {
        guard await ai.imageEmbeddingsEnabled, let record = await store.missingImageEmbeddings(limit: 1).first else { return false }
        return await embedImage(of: record)
    }

    /// Embeds a record's stored (blurred) keyframe. Returns whether it did any work.
    private func embedImage(of record: MemoryRecord, jpeg: Data? = nil) async -> Bool {
        guard await ai.imageEmbeddingsEnabled else { return false }
        let model = await ai.embedModelName
        guard let data = jpeg ?? (try? Data(contentsOf: store.frameURL(record))) else {
            await store.setImageEmbedding(id: record.id, nil, model: model)   // frame file gone
            return true
        }
        do {
            await store.setImageEmbedding(id: record.id, try await ai.embedImage(data), model: model)
            return true
        } catch NemotronClient.NemotronError.http(let status, _) where (400..<500).contains(status) && status != 429 {
            // This picture was refused (and the host still takes images): don't retry it forever.
            guard await ai.imageEmbeddingsEnabled else { return false }
            await store.setImageEmbedding(id: record.id, nil, model: model)
            return true
        } catch {
            return false   // offline, rate limit, a question went first: the backfill tries again
        }
    }

    /// Title + summary for one settled episode whose frames changed. Returns whether it worked.
    private func summarizeEpisode() async -> Bool {
        guard let (episode, records) = await store.episodeNeedingSummary(settle: 90) else { return false }
        let enriched = records.filter { $0.status == .enriched }.count
        do {
            let result = try await ai.chatJSON(EpisodeSummary.self, system: MemoryPrompts.episodeSystem,
                                               user: MemoryPrompts.episodeUser(episode, records: records),
                                               jsonSchema: MemoryPrompts.episodeSchema, schemaName: "episode",
                                               maxTokens: 300, temperature: 0.2, background: true)
            await store.setEpisodeSummary(id: episode.id, title: result.title, summary: result.summary, summarizedCount: enriched)
            Log.pipeline.info("episode \(episode.id): \(result.title ?? "-", privacy: .public) (\(records.count) frames)")
            status.episodes += 1
            return true
        } catch NemotronClient.NemotronError.preempted {
            return false   // a question went first; summarise later
        } catch {
            // Do not retry in a tight loop: mark as done for now, the next new frame re-opens it.
            await store.setEpisodeSummary(id: episode.id, title: episode.title, summary: episode.summary, summarizedCount: enriched)
            Log.net.error("episode \(episode.id) summary failed: \((error as? LocalizedError)?.errorDescription ?? "", privacy: .public)")
            return false
        }
    }

    static func passage(for r: MemoryRecord) -> String {
        [r.kind, r.name, r.caption, r.otherText, r.visual, r.keywords, r.street, r.area, r.ocrText]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func enrich(_ record: MemoryRecord) async throws {
        let started = ContinuousClock.now
        let waited = Date().timeIntervalSince(record.seenAt)
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
                temperature: temperature,
                background: true
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
                       extracted.searchKeywords.joined(separator: " "), record.street, record.area, record.ocrText]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let model = await ai.embedModelName
        let extractedAt = ContinuousClock.now
        let vector = try? await ai.embed(passage, as: .passage)
        await store.applyEnrichment(id: record.id, record: extracted, embedding: vector, model: model)
        Trace.note("enrich #\(record.id): waited \(String(format: "%.1f", waited)) s · extract \((extractedAt - started).milliseconds) ms · embed \((ContinuousClock.now - extractedAt).milliseconds) ms")
        if let onEnriched {
            let frame = jpeg
            let title = extracted.name ?? extracted.kindLabel
            Task { await onEnriched(record.id, title, passage, vector, frame) }
        }
        if let onNoticed {
            let noticed = Noticed(recordID: record.id, seenAt: record.seenAt, title: extracted.name ?? extracted.kindLabel,
                                  passage: passage, vector: vector, jpeg: jpeg,
                                  attention: extracted.attention, reason: extracted.attention_reason)
            Task { await onNoticed(noticed) }
        }
        // The keyframe vector last: the record is already searchable and safety-checked; this
        // is one more paced embedding slot.
        _ = await embedImage(of: record, jpeg: jpeg)
        Log.pipeline.info("enriched \(record.id): \(extracted.kindLabel ?? "-", privacy: .public) / \(extracted.name ?? "-", privacy: .public) · \(extracted.objects.count) things, \(extracted.depictions.count) pictures")
    }

    private var waitGeneration = 0

    private func waitForWork(timeout: Duration) async {
        guard !signaled else { return }
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
