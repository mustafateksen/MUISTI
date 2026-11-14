import Foundation
import SQLite3

/// On-phone storage for Muisti Turva: rules, events, object states, alerts and the blurred
/// evidence frames. Next to the memory database, under the same file protection. Nothing is
/// stored on a server.
actor SafetyStore {
    nonisolated let framesDirectory: URL
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Events are kept 30 days, evidence frames 7 days.
    static let eventRetentionDays = 30
    static let frameRetentionDays = 7

    init(fileName: String = "safety.sqlite") {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let root = support.appendingPathComponent("memory", isDirectory: true)
        framesDirectory = root.appendingPathComponent("safety_frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        if sqlite3_open_v2(root.appendingPathComponent(fileName).path, &handle,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            db = handle
        }
        try? (root as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        sqlite3_exec(handle, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS rules(
              id TEXT PRIMARY KEY, spec TEXT NOT NULL, created_at REAL,
              enabled INTEGER DEFAULT 1, last_fired_at REAL);
            CREATE TABLE IF NOT EXISTS events(
              id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, kind TEXT NOT NULL,
              object TEXT, value TEXT, confidence REAL, source TEXT, frame_file TEXT,
              lat REAL, lon REAL, zone TEXT, detail TEXT);
            CREATE INDEX IF NOT EXISTS events_obj_at ON events(object, at);
            CREATE TABLE IF NOT EXISTS object_state(
              object TEXT PRIMARY KEY, state TEXT, since REAL, last_seen REAL, last_state_seen REAL,
              evidence_frame TEXT, pending_on_count INTEGER DEFAULT 0, source TEXT, place TEXT);
            CREATE TABLE IF NOT EXISTS alerts(
              id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL, rule_id TEXT, message TEXT,
              evidence_frame TEXT, severity TEXT, user_response TEXT);
            """, nil, nil, nil)
        // v2: hazards the frame model flags on its own.
        sqlite3_exec(handle, "ALTER TABLE object_state ADD COLUMN active INTEGER DEFAULT 0", nil, nil, nil)
        sqlite3_exec(handle, "ALTER TABLE object_state ADD COLUMN hazard INTEGER DEFAULT 0", nil, nil, nil)
    }

    // MARK: Frames

    /// Saves a blurred evidence frame; returns its file name.
    func saveFrame(_ jpeg: Data) -> String? {
        let name = "\(UUID().uuidString).jpg"
        do {
            try jpeg.write(to: framesDirectory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return name
        } catch {
            return nil
        }
    }

    nonisolated func frameURL(_ name: String) -> URL { framesDirectory.appendingPathComponent(name) }

    /// The frames just before an evidence frame (already masked), kept next to it so that "did
    /// I lock it?" can be answered with the few seconds in which it happened.
    func saveStrip(_ frames: [Data], before name: String) {
        for (i, jpeg) in frames.suffix(Self.stripLength).enumerated() {
            try? jpeg.write(to: framesDirectory.appendingPathComponent(Self.stripName(name, i)),
                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static let stripLength = 7
    private static func stripName(_ name: String, _ index: Int) -> String { "\(name.dropLast(4))_before\(index).jpg" }

    /// An evidence frame with the frames before it, oldest first (just the frame when it has none).
    nonisolated func sequenceURLs(_ name: String) -> [URL] {
        (0..<Self.stripLength).map { framesDirectory.appendingPathComponent(Self.stripName(name, $0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) } + [frameURL(name)]
    }

    // MARK: Rules

    func rules() -> [SafetyRule] {
        query("SELECT spec, enabled FROM rules ORDER BY created_at") { stmt in
            guard let spec = Self.text(stmt, 0), var rule = try? JSONDecoder().decode(SafetyRule.self, from: Data(spec.utf8)) else { return nil }
            rule.enabled = sqlite3_column_int(stmt, 1) != 0
            return rule
        }
    }

    func save(_ rule: SafetyRule) {
        guard let data = try? JSONEncoder().encode(rule), let spec = String(data: data, encoding: .utf8) else { return }
        run("INSERT INTO rules(id, spec, created_at, enabled) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET spec=excluded.spec, enabled=excluded.enabled",
            [rule.id, spec, Date().timeIntervalSince1970, rule.enabled ? 1 : 0])
    }

    func deleteRule(_ id: String) { run("DELETE FROM rules WHERE id=?", [id]) }

    func lastFired(_ id: String) -> Date? {
        query("SELECT last_fired_at FROM rules WHERE id=?", [id]) { Self.date($0, 0) }.first ?? nil
    }

    func setLastFired(_ id: String, _ date: Date) {
        run("UPDATE rules SET last_fired_at=? WHERE id=?", [date.timeIntervalSince1970, id])
    }

    // MARK: Events

    @discardableResult
    func insert(_ e: SafetyEvent) -> Int64 {
        run("INSERT INTO events(at, kind, object, value, confidence, source, frame_file, lat, lon, zone, detail) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            [e.at.timeIntervalSince1970, e.kind.rawValue, e.object, e.value, e.confidence, e.source.rawValue, e.frameFile,
             e.latitude, e.longitude, e.zone, e.detail])
        return sqlite3_last_insert_rowid(db)
    }

    func events(since: Date, object: String? = nil, kind: SafetyEventKind? = nil, value: String? = nil, limit: Int = 200) -> [SafetyEvent] {
        var sql = "SELECT id, at, kind, object, value, confidence, source, frame_file, lat, lon, zone, detail FROM events WHERE at >= ?"
        var args: [Any?] = [since.timeIntervalSince1970]
        if let object { sql += " AND object = ?"; args.append(object) }
        if let kind { sql += " AND kind = ?"; args.append(kind.rawValue) }
        if let value { sql += " AND value = ?"; args.append(value) }
        sql += " ORDER BY at DESC LIMIT \(limit)"
        return query(sql, args) { s in
            SafetyEvent(id: sqlite3_column_int64(s, 0), at: Self.date(s, 1) ?? Date(),
                        kind: SafetyEventKind(rawValue: Self.text(s, 2) ?? "") ?? .state,
                        object: Self.text(s, 3), value: Self.text(s, 4), confidence: Self.double(s, 5),
                        source: SafetySource(rawValue: Self.text(s, 6) ?? "") ?? .vision,
                        frameFile: Self.text(s, 7), latitude: Self.double(s, 8), longitude: Self.double(s, 9),
                        zone: Self.text(s, 10), detail: Self.text(s, 11))
        }
    }

    // MARK: Object state

    func states() -> [ObjectState] {
        query("SELECT object, state, since, last_seen, last_state_seen, evidence_frame, pending_on_count, source, place, active, hazard FROM object_state ORDER BY last_seen DESC") { s in
            ObjectState(object: Self.text(s, 0) ?? "", state: Self.text(s, 1) ?? "unknown",
                        since: Self.date(s, 2) ?? Date(), lastSeen: Self.date(s, 3) ?? Date(),
                        lastStateSeen: Self.date(s, 4) ?? Date(), evidenceFrame: Self.text(s, 5),
                        pendingOnCount: Int(sqlite3_column_int(s, 6)),
                        source: SafetySource(rawValue: Self.text(s, 7) ?? "") ?? .vision, place: Self.text(s, 8),
                        active: sqlite3_column_int(s, 9) != 0, hazard: sqlite3_column_int(s, 10) != 0)
        }
    }

    func save(_ st: ObjectState) {
        run("""
            INSERT INTO object_state(object, state, since, last_seen, last_state_seen, evidence_frame, pending_on_count, source, place, active, hazard)
            VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(object) DO UPDATE SET state=excluded.state, since=excluded.since,
            last_seen=excluded.last_seen, last_state_seen=excluded.last_state_seen, evidence_frame=excluded.evidence_frame,
            pending_on_count=excluded.pending_on_count, source=excluded.source, place=excluded.place,
            active=excluded.active, hazard=excluded.hazard
            """,
            [st.object, st.state, st.since.timeIntervalSince1970, st.lastSeen.timeIntervalSince1970,
             st.lastStateSeen.timeIntervalSince1970, st.evidenceFrame, st.pendingOnCount, st.source.rawValue, st.place,
             st.active ? 1 : 0, st.hazard ? 1 : 0])
    }

    // MARK: Alerts

    @discardableResult
    func insert(_ a: SafetyAlert) -> Int64 {
        run("INSERT INTO alerts(at, rule_id, message, evidence_frame, severity) VALUES(?,?,?,?,?)",
            [a.at.timeIntervalSince1970, a.ruleID, a.message, a.evidenceFrame, a.severity.rawValue])
        return sqlite3_last_insert_rowid(db)
    }

    func alerts(limit: Int = 30) -> [SafetyAlert] {
        query("SELECT id, at, rule_id, message, evidence_frame, severity, user_response FROM alerts ORDER BY at DESC LIMIT \(limit)") { s in
            SafetyAlert(id: sqlite3_column_int64(s, 0), at: Self.date(s, 1) ?? Date(), ruleID: Self.text(s, 2) ?? "",
                        message: Self.text(s, 3) ?? "", evidenceFrame: Self.text(s, 4),
                        severity: SafetyRule.Severity(rawValue: Self.text(s, 5) ?? "") ?? .medium,
                        response: Self.text(s, 6).flatMap(SafetyAlert.Response.init(rawValue:)))
        }
    }

    func respond(alert id: Int64, _ response: SafetyAlert.Response) {
        run("UPDATE alerts SET user_response=? WHERE id=?", [response.rawValue, id])
    }

    // MARK: Forget / retention

    /// "Forget the last N minutes" covers the safety log too.
    func delete(since: Date) {
        let files = query("SELECT frame_file FROM events WHERE at >= ? AND frame_file IS NOT NULL", [since.timeIntervalSince1970]) { Self.text($0, 0) }
        run("DELETE FROM events WHERE at >= ?", [since.timeIntervalSince1970])
        run("DELETE FROM alerts WHERE at >= ?", [since.timeIntervalSince1970])
        run("DELETE FROM object_state WHERE last_seen >= ?", [since.timeIntervalSince1970])
        files.forEach { try? FileManager.default.removeItem(at: frameURL($0)) }
    }

    func deleteAll() {
        run("DELETE FROM events", [])
        run("DELETE FROM alerts", [])
        run("DELETE FROM object_state", [])
        try? FileManager.default.removeItem(at: framesDirectory)
        try? FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
    }

    func purge(now: Date = Date()) {
        let eventCutoff = now.addingTimeInterval(-Double(Self.eventRetentionDays) * 86_400)
        run("DELETE FROM events WHERE at < ?", [eventCutoff.timeIntervalSince1970])
        run("DELETE FROM alerts WHERE at < ?", [eventCutoff.timeIntervalSince1970])
        let frameCutoff = now.addingTimeInterval(-Double(Self.frameRetentionDays) * 86_400)
        let names = (try? FileManager.default.contentsOfDirectory(at: framesDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for url in names {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            if created < frameCutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: SQLite helpers

    private func run(_ sql: String, _ args: [Any?]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        sqlite3_step(stmt)
    }

    private func query<T>(_ sql: String, _ args: [Any?] = [], _ map: (OpaquePointer) -> T?) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = map(stmt) { out.append(value) }
        }
        return out
    }

    private func bind(_ stmt: OpaquePointer, _ args: [Any?]) {
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, transient)
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, index, v)
            default: sqlite3_bind_null(stmt, index)
            }
        }
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard sqlite3_column_type(s, i) != SQLITE_NULL, let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }

    private static func double(_ s: OpaquePointer, _ i: Int32) -> Double? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
    }

    private static func date(_ s: OpaquePointer, _ i: Int32) -> Date? {
        double(s, i).map { Date(timeIntervalSince1970: $0) }
    }
}
