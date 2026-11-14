import Foundation
import SQLite3

/// One remembered frame: the blurred keyframe + what was read in it + what Nemotron made of it.
struct MemoryRecord: Sendable, Identifiable, Hashable {
    enum Status: Int, Sendable { case pending = 0, enriched = 1, failed = 2 }

    let id: Int64
    let seenAt: Date
    let latitude: Double?
    let longitude: Double?
    let heading: Double?
    let street: String?
    let ocrText: String
    var kind: String?
    var name: String?
    var phone: String?
    var hours: String?
    var otherText: String?
    var caption: String?
    var keywords: String?
    /// Scene, visible things, spatial facts and pictures (labelled text from the vision model).
    var visual: String?
    var confidence: Double?
    let frameFile: String
    var status: Status
    /// The memory episode (one walk / visit) this frame belongs to.
    var episodeID: Int64?

    var title: String {
        if let name, !name.isEmpty { return kind.map { "\(name) · \($0)" } ?? name }
        if let kind { return kind }
        let firstLine = ocrText.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Frame" : firstLine
    }
}

/// One continuous stretch of a walk or visit: frames close in time and place, like a folder.
struct MemoryEpisode: Sendable, Identifiable, Hashable {
    let id: Int64
    let startedAt: Date
    let endedAt: Date
    let latitude: Double?
    let longitude: Double?
    let street: String?
    let title: String?
    let summary: String?
    let frameCount: Int
    let coverFile: String?

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        let time = startedAt.formatted(date: .omitted, time: .shortened)
        return street.map { "\($0) · \(time)" } ?? "Memory · \(time)"
    }
}

struct NewMemory: Sendable {
    let seenAt: Date
    let latitude: Double?
    let longitude: Double?
    let accuracy: Double?
    let heading: Double?
    let street: String?
    let ocrText: String
    let frameJPEG: Data      // blurred, downscaled keyframe
}

struct MemorySearch: Sendable {
    /// Free text matched by FTS5 (the question itself; bm25 down-weights common words).
    var keywords: [String] = []
    var embedding: [Float]?
    /// Candidates handed to grouping + reranking.
    var limit = 40
}

/// Why a record was retrieved (for ranking, the debug trace and tests).
struct RetrievalSignals: Sendable, Hashable {
    var ftsRank: Int?
    var vectorRank: Int?
    var cosine: Float?
    var fuzzy = false
    var rerankLogit: Double?
}

struct MemoryHit: Sendable, Identifiable {
    var id: Int64 { record.id }
    /// The most complete read of this sign/object.
    var record: MemoryRecord
    /// Fused (RRF) score; after reranking, the order follows the reranker.
    var score: Double
    var distanceMeters: Double?
    var signals = RetrievalSignals()
    /// Other reads of the same sign/object (duplicates, partial reads), newest first.
    var related: [MemoryRecord] = []

    var allRecords: [MemoryRecord] { [record] + related }
}

/// On-phone memory: SQLite in Application Support, FTS5 for keywords (accent-insensitive),
/// float32 embeddings as BLOBs, mirrored in an in-memory `VectorIndex`. No server; nothing leaves the phone except
/// the blurred keyframe + OCR text sent to Nemotron for structuring.
actor MemoryStore {
    nonisolated let framesDirectory: URL
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Vectors of `embedModel` only; vectors of another model are re-embedded by the worker.
    private var index = VectorIndex()
    private(set) var embedModel = ""

    init() {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let root = support.appendingPathComponent("memory", isDirectory: true)
        framesDirectory = root.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let path = root.appendingPathComponent("memory.sqlite").path
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            db = handle
        }
        // Protect at rest: unreadable while the phone is locked after first unlock.
        try? (root as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        Self.migrate(handle)
    }

    private static func migrate(_ db: OpaquePointer?) {
        let sql = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA temp_store=MEMORY;
        PRAGMA cache_size=-16000;
        PRAGMA mmap_size=134217728;
        CREATE TABLE IF NOT EXISTS memories(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          seen_at REAL NOT NULL, lat REAL, lon REAL, accuracy REAL, heading REAL, street TEXT,
          ocr_text TEXT NOT NULL DEFAULT '',
          kind TEXT, name TEXT, phone TEXT, hours TEXT, other_text TEXT, caption TEXT, keywords TEXT,
          confidence REAL, frame_file TEXT NOT NULL, embedding BLOB,
          status INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS idx_memories_seen ON memories(seen_at);
        CREATE INDEX IF NOT EXISTS idx_memories_status ON memories(status);
        CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
          ocr_text, kind, name, caption, other_text, keywords, street,
          tokenize='unicode61 remove_diacritics 2');
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            Log.pipeline.error("memory migrate failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
        }
        // v2: which embedding model produced the vector (a model change re-embeds).
        sqlite3_exec(db, "ALTER TABLE memories ADD COLUMN embed_model TEXT", nil, nil, nil)
        // v3: visual memory (objects, relations, pictures) as labelled text.
        sqlite3_exec(db, "ALTER TABLE memories ADD COLUMN visual_text TEXT", nil, nil, nil)
        // v4: memory episodes (frames grouped by time and place).
        sqlite3_exec(db, "ALTER TABLE memories ADD COLUMN episode_id INTEGER", nil, nil, nil)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS episodes(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              started_at REAL NOT NULL, ended_at REAL NOT NULL,
              lat REAL, lon REAL, street TEXT, title TEXT, summary TEXT,
              summarized_count INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS idx_episodes_time ON episodes(ended_at);
            CREATE INDEX IF NOT EXISTS idx_memories_episode ON memories(episode_id);
            """, nil, nil, nil)
    }

    /// Selects the embedding model in use and (re)loads its vectors into the in-memory index.
    func useEmbeddingModel(_ model: String) {
        guard model != embedModel else { return }
        embedModel = model
        index.removeAll()
        guard !model.isEmpty, let stmt = prepare("SELECT id, embedding FROM memories WHERE embedding IS NOT NULL AND embed_model = ?") else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, model)
        let started = ContinuousClock.now
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let vector = Self.vector(stmt, 1) { index.upsert(sqlite3_column_int64(stmt, 0), vector) }
        }
        Log.pipeline.info("vector index: \(self.index.count) × \(self.index.dimension) (\(model, privacy: .public)) in \((ContinuousClock.now - started).milliseconds) ms")
    }

    var indexedVectors: Int { index.count }

    // MARK: Write

    func insert(_ memory: NewMemory) -> Int64? {
        let file = "\(UUID().uuidString).jpg"
        do {
            try memory.frameJPEG.write(to: framesDirectory.appendingPathComponent(file), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Log.pipeline.error("keyframe write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let sql = "INSERT INTO memories(seen_at, lat, lon, accuracy, heading, street, ocr_text, frame_file) VALUES(?,?,?,?,?,?,?,?)"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, memory.seenAt.timeIntervalSince1970)
        bind(stmt, 2, memory.latitude)
        bind(stmt, 3, memory.longitude)
        bind(stmt, 4, memory.accuracy)
        bind(stmt, 5, memory.heading)
        bind(stmt, 6, memory.street)
        bind(stmt, 7, memory.ocrText)
        bind(stmt, 8, file)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        let id = sqlite3_last_insert_rowid(db)
        indexFTS(id: id, ocr: memory.ocrText, kind: nil, name: nil, caption: nil, other: nil, keywords: nil, street: memory.street)
        assignEpisode(id: id, seenAt: memory.seenAt, latitude: memory.latitude, longitude: memory.longitude, street: memory.street)
        return id
    }

    func applyEnrichment(id: Int64, record: ExtractedRecord, embedding: [Float]?, model: String) {
        let sql = """
        UPDATE memories SET kind=?, name=?, phone=?, hours=?, other_text=?, caption=?, keywords=?,
          confidence=?, embedding=?, embed_model=?, visual_text=?, status=1 WHERE id=?
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        let keywords = record.searchKeywords.joined(separator: " ")
        bind(stmt, 1, record.kindLabel)
        bind(stmt, 2, record.name)
        bind(stmt, 3, record.phone)
        bind(stmt, 4, record.hours)
        bind(stmt, 5, record.other_text)
        bind(stmt, 6, record.caption)
        bind(stmt, 7, keywords)
        bind(stmt, 8, record.confidence)
        if let embedding {
            let data = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 9, $0.baseAddress, Int32(data.count), transient) }
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        bind(stmt, 10, embedding == nil ? nil : model)
        bind(stmt, 11, record.visualText)
        sqlite3_bind_int64(stmt, 12, id)
        sqlite3_step(stmt)
        if let embedding, model == embedModel { index.upsert(id, embedding) } else { index.remove(id) }
        if let current = self.record(id: id) {
            indexFTS(id: id, ocr: current.ocrText, kind: record.kindLabel, name: record.name,
                     caption: [record.caption, record.visualText].compactMap { $0 }.joined(separator: "\n"),
                     other: record.other_text, keywords: keywords, street: current.street)
        }
    }

    func markAttemptFailed(id: Int64, giveUpAfter: Int = 5) {
        exec("UPDATE memories SET attempts = attempts + 1, status = CASE WHEN attempts + 1 >= \(giveUpAfter) THEN 2 ELSE status END WHERE id = \(id)")
    }

    /// "Unut": deletes everything seen at or after `since`. Returns how many were removed.
    @discardableResult
    func delete(since: Date) -> Int {
        deleteWhere("seen_at >= \(since.timeIntervalSince1970)")
    }

    /// Retention: deletes everything older than `days`.
    @discardableResult
    func purge(olderThanDays days: Int) -> Int {
        deleteWhere("seen_at < \(Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970)")
    }

    @discardableResult
    func deleteAll() -> Int { deleteWhere("1=1") }

    func delete(id: Int64) { _ = deleteWhere("id = \(id)") }

    private func deleteWhere(_ condition: String) -> Int {
        var files: [String] = []
        var ids: [Int64] = []
        if let stmt = prepare("SELECT id, frame_file FROM memories WHERE \(condition)") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(sqlite3_column_int64(stmt, 0))
                files.append(text(stmt, 1) ?? "")
            }
            sqlite3_finalize(stmt)
        }
        guard !ids.isEmpty else { return 0 }
        let list = ids.map(String.init).joined(separator: ",")
        exec("DELETE FROM memories WHERE id IN (\(list))")
        exec("DELETE FROM memories_fts WHERE rowid IN (\(list))")
        ids.forEach { index.remove($0) }
        refreshEpisodes()
        for file in files where !file.isEmpty {
            try? FileManager.default.removeItem(at: framesDirectory.appendingPathComponent(file))
        }
        return ids.count
    }

    // MARK: Read

    func count() -> (total: Int, pending: Int) {
        var total = 0, pending = 0
        if let stmt = prepare("SELECT COUNT(*), SUM(CASE WHEN status=0 THEN 1 ELSE 0 END) FROM memories") {
            if sqlite3_step(stmt) == SQLITE_ROW {
                total = Int(sqlite3_column_int64(stmt, 0))
                pending = Int(sqlite3_column_int64(stmt, 1))
            }
            sqlite3_finalize(stmt)
        }
        return (total, pending)
    }

    /// Enriched rows without a vector of the current model (embeddings were off, or the model changed).
    func missingEmbeddings(limit: Int) -> [MemoryRecord] {
        guard !embedModel.isEmpty, let stmt = prepare(
            "SELECT id FROM memories WHERE status = 1 AND (embedding IS NULL OR embed_model IS NOT ?) ORDER BY seen_at DESC LIMIT \(limit)"
        ) else { return [] }
        bind(stmt, 1, embedModel)
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
        sqlite3_finalize(stmt)
        return records(ids)
    }

    func setEmbedding(id: Int64, _ vector: [Float], model: String) {
        guard let stmt = prepare("UPDATE memories SET embedding = ?, embed_model = ? WHERE id = ?") else { return }
        defer { sqlite3_finalize(stmt) }
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(data.count), transient) }
        bind(stmt, 2, model)
        sqlite3_bind_int64(stmt, 3, id)
        sqlite3_step(stmt)
        if model == embedModel { index.upsert(id, vector) }
    }

    func pending(limit: Int) -> [MemoryRecord] {
        // Newest first: what the user is looking at now is understood within seconds (safety
        // rules, "what is this"); a backlog from a busy walk fills in behind it.
        rows("WHERE status = 0 ORDER BY seen_at DESC LIMIT \(limit)")
    }

    /// Words the speech recogniser should expect, taken from what was seen: sign names,
    /// streets, keywords and the most frequent words read on signs (so a name seen on a booth is
    /// not heard as a common word). Data-driven; no word lists.
    func vocabulary(limit: Int = 100) -> [String] {
        var weight: [String: Int] = [:]
        var display: [String: String] = [:]
        func add(_ raw: String, _ w: Int) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard t.count >= 3, t.count <= 40, t.split(separator: " ").count <= 3, t.contains(where: \.isLetter) else { return }
            let key = t.lowercased()
            weight[key, default: 0] += w
            if display[key] == nil { display[key] = t }
        }
        for r in recent(limit: 400) {
            if let name = r.name { add(name, 5) }
            if let street = r.street { add(street, 3) }
            for k in (r.keywords ?? "").split(whereSeparator: { ",;\n".contains($0) }) { add(String(k), 2) }
            for w in r.ocrText.split(whereSeparator: { !$0.isLetter }) where w.count >= 4 { add(String(w), 1) }
        }
        return weight.sorted { $0.value > $1.value }.prefix(limit).compactMap { display[$0.key] }
    }

    func recent(limit: Int) -> [MemoryRecord] {
        rows("ORDER BY seen_at DESC LIMIT \(limit)")
    }

    func record(id: Int64) -> MemoryRecord? {
        rows("WHERE id = \(id)").first
    }

    nonisolated func frameURL(_ record: MemoryRecord) -> URL {
        framesDirectory.appendingPathComponent(record.frameFile)
    }

    /// Hybrid retrieval, all on the phone. Ranked lists, fused by reciprocal rank (k = 60) so
    /// no scores of different scales are ever added:
    /// - FTS5 bm25 (name/kind weighted),
    /// - vector cosine (in-memory index),
    /// - in-word matching for partial OCR reads when FTS finds nothing,
    /// - recency (low weight): time references are resolved by the answer model, which sees
    ///   each record's age, so recent records must be among the candidates.
    /// Grouping and the Nemotron reranker run after this, in `QueryEngine`.
    func search(_ query: MemorySearch) -> [MemoryHit] {
        let k = 60.0
        var fused: [Int64: Double] = [:]
        var signals: [Int64: RetrievalSignals] = [:]
        func add(_ ranked: [Int64], weight: Double, _ mark: (inout RetrievalSignals, Int) -> Void) {
            for (i, id) in ranked.enumerated() {
                fused[id, default: 0] += weight / (k + Double(i + 1))
                mark(&signals[id, default: RetrievalSignals()], i + 1)
            }
        }

        let fts = keywordRanking(query.keywords, limit: 80)
        add(fts, weight: 1) { $0.ftsRank = $1 }

        if let embedding = query.embedding {
            let nearest = index.search(embedding, k: 80)
            add(nearest.map(\.id), weight: 1) { $0.vectorRank = $1 }
            for hit in nearest { signals[hit.id]?.cosine = hit.cosine }
        }

        // OCR often reads a sign half-way ("TEEKKI" for "APTEEKKI"); FTS prefix search misses that.
        if fts.isEmpty {
            add(fuzzyRanking(query.keywords), weight: 0.8) { s, _ in s.fuzzy = true }
        }

        add(recentIDs(limit: 20), weight: 0.5) { _, _ in }

        let top = fused.sorted { $0.value > $1.value }.prefix(query.limit)
        let byID = Dictionary(records(top.map(\.key)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return top.compactMap { id, score in
            byID[id].map { MemoryHit(record: $0, score: score, distanceMeters: nil, signals: signals[id] ?? RetrievalSignals()) }
        }
    }

    private func fuzzyRanking(_ keywords: [String]) -> [Int64] {
        let terms = Array(Set(Self.terms(keywords).filter { $0.count >= 4 }))
        guard !terms.isEmpty else { return [] }
        var scored: [(Int64, Int)] = []
        for record in rows("ORDER BY seen_at DESC LIMIT 1500") {
            let words = Set(Self.terms([record.ocrText, record.name ?? "", record.kind ?? "", record.keywords ?? "", record.caption ?? ""])
                .filter { $0.count >= 4 })
            let hits = terms.filter { t in words.contains { $0.contains(t) || ($0.count >= 5 && t.contains($0)) } }.count
            if hits > 0 { scored.append((record.id, hits)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(40).map(\.0)
    }

    private func recentIDs(limit: Int) -> [Int64] {
        guard let stmt = prepare("SELECT id FROM memories ORDER BY seen_at DESC LIMIT \(limit)") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
        return ids
    }

    func records(_ ids: [Int64]) -> [MemoryRecord] {
        guard !ids.isEmpty else { return [] }
        return rows("WHERE id IN (\(ids.map(String.init).joined(separator: ",")))")
    }

    // MARK: Episodes

    /// A new frame joins the episode it continues (within `episodeGap` of it in time and
    /// `episodeRadius` of its last position); otherwise it starts a new one.
    static let episodeGap: TimeInterval = 10 * 60
    static let episodeRadius: Double = 300

    private func assignEpisode(id: Int64, seenAt: Date, latitude: Double?, longitude: Double?, street: String?) {
        let t = seenAt.timeIntervalSince1970
        var chosen: Int64?
        if let stmt = prepare("""
            SELECT id, lat, lon FROM episodes WHERE ended_at >= ? AND started_at <= ?
            ORDER BY ABS(ended_at - ?) LIMIT 5
            """) {
            sqlite3_bind_double(stmt, 1, t - Self.episodeGap)
            sqlite3_bind_double(stmt, 2, t + Self.episodeGap)
            sqlite3_bind_double(stmt, 3, t)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let latitude, let longitude, let lat = double(stmt, 1), let lon = double(stmt, 2),
                   Self.haversine(latitude, longitude, lat, lon) > Self.episodeRadius { continue }
                chosen = sqlite3_column_int64(stmt, 0)
                break
            }
            sqlite3_finalize(stmt)
        }
        if let episode = chosen {
            guard let stmt = prepare("""
                UPDATE episodes SET started_at = MIN(started_at, ?), ended_at = MAX(ended_at, ?),
                  lat = CASE WHEN ? >= ended_at THEN COALESCE(?, lat) ELSE lat END,
                  lon = CASE WHEN ? >= ended_at THEN COALESCE(?, lon) ELSE lon END,
                  street = COALESCE(street, ?) WHERE id = ?
                """) else { return }
            sqlite3_bind_double(stmt, 1, t)
            sqlite3_bind_double(stmt, 2, t)
            sqlite3_bind_double(stmt, 3, t)
            bind(stmt, 4, latitude)
            sqlite3_bind_double(stmt, 5, t)
            bind(stmt, 6, longitude)
            bind(stmt, 7, street)
            sqlite3_bind_int64(stmt, 8, episode)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        } else {
            guard let stmt = prepare("INSERT INTO episodes(started_at, ended_at, lat, lon, street) VALUES(?,?,?,?,?)") else { return }
            sqlite3_bind_double(stmt, 1, t)
            sqlite3_bind_double(stmt, 2, t)
            bind(stmt, 3, latitude)
            bind(stmt, 4, longitude)
            bind(stmt, 5, street)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            chosen = sqlite3_last_insert_rowid(db)
        }
        if let chosen { exec("UPDATE memories SET episode_id = \(chosen) WHERE id = \(id)") }
    }

    /// Frames stored before episodes existed get one, oldest first.
    func assignMissingEpisodes() {
        guard let stmt = prepare("SELECT id, seen_at, lat, lon, street FROM memories WHERE episode_id IS NULL ORDER BY seen_at ASC") else { return }
        var rows: [(Int64, Date, Double?, Double?, String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((sqlite3_column_int64(stmt, 0), Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                         double(stmt, 2), double(stmt, 3), text(stmt, 4)))
        }
        sqlite3_finalize(stmt)
        for row in rows { assignEpisode(id: row.0, seenAt: row.1, latitude: row.2, longitude: row.3, street: row.4) }
    }

    /// After deletions: empty episodes go, the others get their time span recomputed.
    private func refreshEpisodes() {
        exec("DELETE FROM episodes WHERE id NOT IN (SELECT DISTINCT episode_id FROM memories WHERE episode_id IS NOT NULL)")
        exec("""
            UPDATE episodes SET
              started_at = (SELECT MIN(seen_at) FROM memories WHERE episode_id = episodes.id),
              ended_at = (SELECT MAX(seen_at) FROM memories WHERE episode_id = episodes.id),
              summarized_count = 0
            WHERE summarized_count != (SELECT COUNT(*) FROM memories WHERE episode_id = episodes.id AND status = 1)
            """)
    }

    func episodes(limit: Int) -> [MemoryEpisode] {
        episodeRows("ORDER BY e.ended_at DESC LIMIT \(limit)")
    }

    func episode(id: Int64) -> MemoryEpisode? {
        episodeRows("WHERE e.id = \(id)").first
    }

    func episodes(_ ids: [Int64]) -> [MemoryEpisode] {
        guard !ids.isEmpty else { return [] }
        return episodeRows("WHERE e.id IN (\(ids.map(String.init).joined(separator: ",")))")
    }

    /// Frames of an episode in the order they were seen.
    func records(inEpisode id: Int64) -> [MemoryRecord] {
        rows("WHERE episode_id = \(id) ORDER BY seen_at ASC")
    }

    /// An episode whose structured frames changed since its last summary, settled for `settle` seconds.
    func episodeNeedingSummary(settle: TimeInterval) -> (episode: MemoryEpisode, records: [MemoryRecord])? {
        let cutoff = Date().addingTimeInterval(-settle).timeIntervalSince1970
        guard let stmt = prepare("""
            SELECT e.id FROM episodes e
            WHERE e.ended_at <= \(cutoff)
              AND NOT EXISTS (SELECT 1 FROM memories m WHERE m.episode_id = e.id AND m.status = 0)
              AND e.summarized_count != (SELECT COUNT(*) FROM memories m WHERE m.episode_id = e.id AND m.status = 1)
            ORDER BY e.ended_at DESC LIMIT 1
            """) else { return nil }
        var id: Int64?
        if sqlite3_step(stmt) == SQLITE_ROW { id = sqlite3_column_int64(stmt, 0) }
        sqlite3_finalize(stmt)
        guard let id, let episode = episode(id: id) else { return nil }
        return (episode, records(inEpisode: id))
    }

    func setEpisodeSummary(id: Int64, title: String?, summary: String?, summarizedCount: Int) {
        guard let stmt = prepare("UPDATE episodes SET title = ?, summary = ?, summarized_count = ? WHERE id = ?") else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, title)
        bind(stmt, 2, summary)
        sqlite3_bind_int(stmt, 3, Int32(summarizedCount))
        sqlite3_bind_int64(stmt, 4, id)
        sqlite3_step(stmt)
    }

    private func episodeRows(_ tail: String) -> [MemoryEpisode] {
        guard let stmt = prepare("""
            SELECT e.id, e.started_at, e.ended_at, e.lat, e.lon, e.street, e.title, e.summary,
              (SELECT COUNT(*) FROM memories m WHERE m.episode_id = e.id),
              (SELECT m.frame_file FROM memories m WHERE m.episode_id = e.id
                 ORDER BY (m.name IS NOT NULL) DESC, LENGTH(m.ocr_text) DESC, m.seen_at ASC LIMIT 1)
            FROM episodes e \(tail)
            """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [MemoryEpisode] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(MemoryEpisode(
                id: sqlite3_column_int64(stmt, 0),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                endedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                latitude: double(stmt, 3),
                longitude: double(stmt, 4),
                street: text(stmt, 5),
                title: text(stmt, 6),
                summary: text(stmt, 7),
                frameCount: Int(sqlite3_column_int(stmt, 8)),
                coverFile: text(stmt, 9)
            ))
        }
        return out
    }

    nonisolated func coverURL(_ episode: MemoryEpisode) -> URL? {
        episode.coverFile.map { framesDirectory.appendingPathComponent($0) }
    }

    // MARK: Helpers

    /// Lower-cased, accent-folded word tokens.
    static func terms(_ texts: [String]) -> [String] {
        texts.flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
            .map { String($0).lowercased().folding(options: .diacriticInsensitive, locale: nil) }
    }

    /// FTS5 ids by bm25 (best first). Column weights: name and kind count most, street least.
    private func keywordRanking(_ keywords: [String], limit: Int) -> [Int64] {
        let terms = Set(Self.terms(keywords).filter { $0.count >= 2 })
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
        // columns: ocr_text, kind, name, caption, other_text, keywords, street
        guard let stmt = prepare("""
            SELECT rowid FROM memories_fts WHERE memories_fts MATCH ?
            ORDER BY bm25(memories_fts, 1.0, 3.0, 4.0, 1.0, 1.0, 2.0, 0.5) LIMIT \(limit)
            """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, match)
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
        return ids
    }

    private func indexFTS(id: Int64, ocr: String, kind: String?, name: String?, caption: String?, other: String?, keywords: String?, street: String?) {
        exec("DELETE FROM memories_fts WHERE rowid = \(id)")
        guard let stmt = prepare("INSERT INTO memories_fts(rowid, ocr_text, kind, name, caption, other_text, keywords, street) VALUES(?,?,?,?,?,?,?,?)") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        bind(stmt, 2, ocr)
        bind(stmt, 3, kind)
        bind(stmt, 4, name)
        bind(stmt, 5, caption)
        bind(stmt, 6, other)
        bind(stmt, 7, keywords)
        bind(stmt, 8, street)
        sqlite3_step(stmt)
    }

    private static let columns = "id, seen_at, lat, lon, heading, street, ocr_text, kind, name, phone, hours, other_text, caption, keywords, confidence, frame_file, status, visual_text, episode_id"

    private func rows(_ tail: String) -> [MemoryRecord] {
        guard let stmt = prepare("SELECT \(Self.columns) FROM memories \(tail)") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [MemoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(MemoryRecord(
                id: sqlite3_column_int64(stmt, 0),
                seenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                latitude: double(stmt, 2),
                longitude: double(stmt, 3),
                heading: double(stmt, 4),
                street: text(stmt, 5),
                ocrText: text(stmt, 6) ?? "",
                kind: text(stmt, 7),
                name: text(stmt, 8),
                phone: text(stmt, 9),
                hours: text(stmt, 10),
                otherText: text(stmt, 11),
                caption: text(stmt, 12),
                keywords: text(stmt, 13),
                visual: text(stmt, 17),
                confidence: double(stmt, 14),
                frameFile: text(stmt, 15) ?? "",
                status: MemoryRecord.Status(rawValue: Int(sqlite3_column_int(stmt, 16))) ?? .pending,
                episodeID: sqlite3_column_type(stmt, 18) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 18)
            ))
        }
        return result
    }

    private static func vector(_ stmt: OpaquePointer, _ index: Int32) -> [Float]? {
        let bytes = Int(sqlite3_column_bytes(stmt, index))
        guard bytes > 0, let blob = sqlite3_column_blob(stmt, index) else { return nil }
        return Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: bytes / MemoryLayout<Float>.size))
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.pipeline.error("sqlite prepare failed: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            return nil
        }
        return stmt
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, transient) } else { sqlite3_bind_null(stmt, index) }
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func double(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }

    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}
