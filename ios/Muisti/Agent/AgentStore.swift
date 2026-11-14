import Foundation
import SQLite3

/// On-phone storage for the agent side of Muisti: what the user asked to be reminded of, named
/// places, what they told Muisti about themselves, and the log of everything Muisti brought up
/// by itself (or chose not to). Next to the memory database, same file protection; nothing on
/// a server.
actor AgentStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(fileName: String = "agent.sqlite") {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let root = support.appendingPathComponent("memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        if sqlite3_open_v2(root.appendingPathComponent(fileName).path, &handle,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            db = handle
        }
        try? (root as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        sqlite3_exec(handle, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS intents(
              id TEXT PRIMARY KEY, spec TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS places(
              id TEXT PRIMARY KEY, spec TEXT NOT NULL, set_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS facts(
              id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS interventions(
              id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, source TEXT, topic TEXT, urgency TEXT,
              level INTEGER, text TEXT, language TEXT, intent_id TEXT, record_id INTEGER, reason TEXT, outcome TEXT);
            CREATE INDEX IF NOT EXISTS interventions_at ON interventions(at);
            CREATE TABLE IF NOT EXISTS mutes(
              topic TEXT PRIMARY KEY, until REAL, at REAL NOT NULL);
            """, nil, nil, nil)
    }

    // MARK: Intents

    func intents(status: Intent.Status? = .open) -> [Intent] {
        let rows: [Intent] = status.map { query("SELECT spec FROM intents WHERE status=? ORDER BY created_at", [$0.rawValue], Self.decode) }
            ?? query("SELECT spec FROM intents ORDER BY created_at DESC LIMIT 200", [], Self.decode)
        return rows
    }

    func save(_ intent: Intent) {
        guard let spec = Self.encode(intent) else { return }
        run("INSERT INTO intents(id, spec, status, created_at) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET spec=excluded.spec, status=excluded.status",
            [intent.id, spec, intent.status.rawValue, intent.createdAt.timeIntervalSince1970])
    }

    func deleteIntent(_ id: String) { run("DELETE FROM intents WHERE id=?", [id]) }

    // MARK: Places

    func places() -> [NamedPlace] { query("SELECT spec FROM places ORDER BY set_at", [], Self.decode) }

    func save(_ place: NamedPlace) {
        guard let spec = Self.encode(place) else { return }
        run("INSERT INTO places(id, spec, set_at) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET spec=excluded.spec, set_at=excluded.set_at",
            [place.id, spec, place.setAt.timeIntervalSince1970])
    }

    func deletePlace(_ id: String) { run("DELETE FROM places WHERE id=?", [id]) }

    // MARK: Facts

    func facts() -> [UserFact] {
        query("SELECT id, text, at FROM facts ORDER BY at") { s in
            UserFact(id: sqlite3_column_int64(s, 0), text: Self.text(s, 1) ?? "", at: Self.date(s, 2) ?? Date())
        }
    }

    func add(fact text: String, at: Date = Date()) { run("INSERT INTO facts(text, at) VALUES(?,?)", [text, at.timeIntervalSince1970]) }

    func deleteFact(_ id: Int64) { run("DELETE FROM facts WHERE id=?", [id]) }

    // MARK: Interventions

    @discardableResult
    func insert(_ i: Intervention) -> Int64 {
        run("INSERT INTO interventions(at, source, topic, urgency, level, text, language, intent_id, record_id, reason, outcome) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            [i.at.timeIntervalSince1970, i.source, i.topic, i.urgency.rawValue, i.level.rawValue, i.text, i.language,
             i.intentID, i.recordID, i.reason, i.outcome?.rawValue])
        return sqlite3_last_insert_rowid(db)
    }

    func interventions(since: Date, limit: Int = 200) -> [Intervention] {
        query("SELECT id, at, source, topic, urgency, level, text, language, intent_id, record_id, reason, outcome FROM interventions WHERE at >= ? ORDER BY at DESC LIMIT \(limit)",
              [since.timeIntervalSince1970]) { s in
            Intervention(id: sqlite3_column_int64(s, 0), at: Self.date(s, 1) ?? Date(), source: Self.text(s, 2) ?? "agent",
                         topic: Self.text(s, 3) ?? "", urgency: Urgency(rawValue: Self.text(s, 4) ?? "") ?? .useful,
                         level: InterventionLevel(rawValue: Int(sqlite3_column_int(s, 5))) ?? .silent,
                         text: Self.text(s, 6) ?? "", language: Self.text(s, 7), intentID: Self.text(s, 8),
                         recordID: sqlite3_column_type(s, 9) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 9),
                         reason: Self.text(s, 10), outcome: Self.text(s, 11).flatMap(Intervention.Outcome.init(rawValue:)))
        }
    }

    func setOutcome(_ id: Int64, _ outcome: Intervention.Outcome) {
        run("UPDATE interventions SET outcome=? WHERE id=?", [outcome.rawValue, id])
    }

    func setLevel(_ id: Int64, _ level: InterventionLevel, reason: String?) {
        run("UPDATE interventions SET level=?, reason=? WHERE id=?", [level.rawValue, reason, id])
    }

    // MARK: Mutes

    func mutes(now: Date = Date()) -> [Mute] {
        run("DELETE FROM mutes WHERE until IS NOT NULL AND until < ?", [now.timeIntervalSince1970])
        return query("SELECT topic, until, at FROM mutes ORDER BY at") { s in
            Mute(topic: Self.text(s, 0) ?? "", until: Self.date(s, 1), at: Self.date(s, 2) ?? Date())
        }
    }

    func save(_ mute: Mute) {
        run("INSERT INTO mutes(topic, until, at) VALUES(?,?,?) ON CONFLICT(topic) DO UPDATE SET until=excluded.until, at=excluded.at",
            [mute.topic, mute.until?.timeIntervalSince1970, mute.at.timeIntervalSince1970])
    }

    func deleteMute(_ topic: String) { run("DELETE FROM mutes WHERE topic=?", [topic]) }

    // MARK: Forget / retention

    /// "Forget the last N minutes": what was noted and said in that time goes too.
    func delete(since: Date) {
        let t = since.timeIntervalSince1970
        run("DELETE FROM intents WHERE created_at >= ?", [t])
        run("DELETE FROM places WHERE set_at >= ?", [t])
        run("DELETE FROM facts WHERE at >= ?", [t])
        run("DELETE FROM interventions WHERE at >= ?", [t])
        run("DELETE FROM mutes WHERE at >= ?", [t])
    }

    func deleteAll() {
        for table in ["intents", "places", "facts", "interventions", "mutes"] { run("DELETE FROM \(table)", []) }
    }

    /// The log and finished intents follow the memory's retention; open intents, places and
    /// what the user told Muisti stay until they are done or removed.
    func purge(olderThanDays days: Int, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        run("DELETE FROM interventions WHERE at < ?", [cutoff])
        run("DELETE FROM intents WHERE status != 'open' AND created_at < ?", [cutoff])
    }

    // MARK: SQLite helpers

    private static func encode<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func decode<T: Decodable>(_ s: OpaquePointer) -> T? {
        text(s, 0).flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }

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

    private static func date(_ s: OpaquePointer, _ i: Int32) -> Date? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, i))
    }
}
