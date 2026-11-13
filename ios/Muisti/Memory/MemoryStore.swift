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
    var confidence: Double?
    let frameFile: String
    var status: Status

    var title: String {
        if let name, !name.isEmpty { return kind.map { "\(name) · \($0)" } ?? name }
        if let kind { return kind }
        let firstLine = ocrText.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Kare" : firstLine
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
    var since: Date?
    var near: (latitude: Double, longitude: Double, meters: Double)?
    var keywords: [String] = []
    var embedding: [Float]?
    var limit = 5
}

struct MemoryHit: Sendable, Identifiable {
    var id: Int64 { record.id }
    let record: MemoryRecord
    let score: Double
    let distanceMeters: Double?
}

/// On-phone memory: SQLite in Application Support, FTS5 for keywords (accent-insensitive),
/// float32 embeddings as BLOBs scored in Swift. No server; nothing leaves the phone except
/// the blurred keyframe + OCR text sent to Nemotron for structuring.
actor MemoryStore {
    nonisolated let framesDirectory: URL
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
    }

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
        return id
    }

    func applyEnrichment(id: Int64, record: ExtractedRecord, embedding: [Float]?) {
        let sql = """
        UPDATE memories SET kind=?, name=?, phone=?, hours=?, other_text=?, caption=?, keywords=?,
          confidence=?, embedding=?, status=1 WHERE id=?
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        let keywords = record.keywords?.joined(separator: " ")
        bind(stmt, 1, record.kind)
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
        sqlite3_bind_int64(stmt, 10, id)
        sqlite3_step(stmt)
        if let current = self.record(id: id) {
            indexFTS(id: id, ocr: current.ocrText, kind: record.kind, name: record.name, caption: record.caption,
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

    func pending(limit: Int) -> [MemoryRecord] {
        rows("WHERE status = 0 ORDER BY seen_at ASC LIMIT \(limit)")
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

    /// Time + place filter, then keyword (FTS5 bm25) and embedding (cosine) scoring.
    func search(_ query: MemorySearch) -> [MemoryHit] {
        var conditions: [String] = []
        if let since = query.since { conditions.append("seen_at >= \(since.timeIntervalSince1970)") }
        if let near = query.near {
            // Bounding box in SQL, exact distance below.
            let dLat = near.meters / 111_000
            let dLon = near.meters / (111_000 * max(0.1, cos(near.latitude * .pi / 180)))
            conditions.append("lat BETWEEN \(near.latitude - dLat) AND \(near.latitude + dLat)")
            conditions.append("lon BETWEEN \(near.longitude - dLon) AND \(near.longitude + dLon)")
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let candidates = rowsWithEmbedding("\(whereClause) ORDER BY seen_at DESC LIMIT 800")
        guard !candidates.isEmpty else { return [] }

        let ftsScores = keywordScores(query.keywords)
        let newest = candidates.first?.record.seenAt ?? Date()
        // OCR often reads a sign half-way ("TEEKKI" for "APTEEKKI"); FTS prefix search misses
        // that, so fall back to in-word matching when FTS finds nothing in this window.
        let fuzzyTerms = Self.terms(query.keywords).filter { $0.count >= 4 }
        let useFuzzy = !fuzzyTerms.isEmpty && !candidates.contains { ftsScores[$0.record.id] != nil }

        var hits: [MemoryHit] = []
        for (record, vector) in candidates {
            var score = 0.0
            var matched = false
            if let fts = ftsScores[record.id] {
                score += 1.0 + fts
                matched = true
            } else if useFuzzy {
                let haystack = Self.terms([record.ocrText, record.name ?? "", record.kind ?? "", record.keywords ?? "", record.caption ?? ""])
                    .filter { $0.count >= 4 }
                let hits = fuzzyTerms.filter { t in haystack.contains { $0.contains(t) || (t.contains($0) && $0.count >= 5) } }.count
                if hits > 0 {
                    score += 0.6 + 0.4 * Double(hits) / Double(fuzzyTerms.count)
                    matched = true
                }
            }
            if let q = query.embedding, let v = vector, q.count == v.count {
                let cosine = Self.cosine(q, v)
                if cosine > 0.25 { matched = true }
                score += Double(cosine) * 1.5
            }
            if query.keywords.isEmpty && query.embedding == nil { matched = true }
            guard matched else { continue }
            // Mild recency and legibility preference.
            let ageHours = newest.timeIntervalSince(record.seenAt) / 3600
            score += max(0, 0.2 - ageHours * 0.01) + (record.confidence ?? 0.5) * 0.2
            var distance: Double?
            if let near = query.near, let lat = record.latitude, let lon = record.longitude {
                let d = Self.haversine(near.latitude, near.longitude, lat, lon)
                guard d <= near.meters else { continue }
                distance = d
            }
            hits.append(MemoryHit(record: record, score: score, distanceMeters: distance))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(query.limit))
    }

    // MARK: Helpers

    /// Lower-cased, accent-folded word tokens.
    static func terms(_ texts: [String]) -> [String] {
        texts.flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
            .map { String($0).lowercased().folding(options: .diacriticInsensitive, locale: nil) }
    }

    private func keywordScores(_ keywords: [String]) -> [Int64: Double] {
        let terms = Self.terms(keywords).filter { $0.count >= 2 }
        guard !terms.isEmpty else { return [:] }
        let match = Set(terms).map { "\"\($0)\"*" }.joined(separator: " OR ")
        guard let stmt = prepare("SELECT rowid, bm25(memories_fts) FROM memories_fts WHERE memories_fts MATCH ? LIMIT 200") else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, match)
        var raw: [(Int64, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            raw.append((sqlite3_column_int64(stmt, 0), sqlite3_column_double(stmt, 1)))
        }
        // bm25: more negative = better. Normalise to 0…1.
        guard let best = raw.map(\.1).min(), let worst = raw.map(\.1).max() else { return [:] }
        let span = max(0.0001, worst - best)
        return Dictionary(raw.map { ($0.0, 1 - ($0.1 - best) / span) }, uniquingKeysWith: max)
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

    private static let columns = "id, seen_at, lat, lon, heading, street, ocr_text, kind, name, phone, hours, other_text, caption, keywords, confidence, frame_file, status, embedding"

    private func rows(_ tail: String) -> [MemoryRecord] {
        rowsWithEmbedding(tail).map(\.0)
    }

    private func rowsWithEmbedding(_ tail: String) -> [(record: MemoryRecord, vector: [Float]?)] {
        guard let stmt = prepare("SELECT \(Self.columns) FROM memories \(tail)") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [(MemoryRecord, [Float]?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let record = MemoryRecord(
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
                confidence: double(stmt, 14),
                frameFile: text(stmt, 15) ?? "",
                status: MemoryRecord.Status(rawValue: Int(sqlite3_column_int(stmt, 16))) ?? .pending
            )
            var vector: [Float]?
            let bytes = Int(sqlite3_column_bytes(stmt, 17))
            if bytes > 0, let blob = sqlite3_column_blob(stmt, 17) {
                vector = Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: bytes / MemoryLayout<Float>.size))
            }
            result.append((record, vector))
        }
        return result
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

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}
