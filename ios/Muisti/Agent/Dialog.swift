import Foundation
import SQLite3

/// One entry of the conversation between the user and Muisti, in either direction.
struct DialogTurn: Sendable, Identifiable, Equatable {
    enum Speaker: String, Sendable {
        case user
        /// Muisti answering the user.
        case muisti
        /// Muisti speaking by itself (a reminder, a warning, a question of its own).
        case proactive = "muisti_proactive"
        /// Something Muisti decided without saying it (it stayed silent, and why).
        case note = "system_note"
    }

    var id: Int64 = 0
    var at: Date
    var speaker: Speaker
    var text: String
    /// The tool the turn ended in ("search_memory", "remember_intent", …), for "the reminder
    /// you just set".
    var tool: String?
    /// Memory records the reply relied on.
    var recordIDs: [Int64] = []
    /// Intents the turn made or touched.
    var intentIDs: [String] = []
    /// The reply looked through the glasses.
    var looked = false
}

/// The conversation, kept on the phone and across restarts (pipeline v2, §4): every user turn,
/// every reply, everything Muisti said by itself and every decision to stay silent go into one
/// stream; older turns are folded into summaries instead of being forgotten; short notes the
/// model keeps for itself ("in a meeting until 15:00") live here with an expiry.
actor DialogStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(fileName: String = "dialog.sqlite") {
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
            CREATE TABLE IF NOT EXISTS turns(
              id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, speaker TEXT NOT NULL, text TEXT NOT NULL,
              tool TEXT, record_ids TEXT, intent_ids TEXT, looked INTEGER NOT NULL DEFAULT 0, thread_id INTEGER);
            CREATE INDEX IF NOT EXISTS turns_at ON turns(at);
            CREATE TABLE IF NOT EXISTS summaries(
              id INTEGER PRIMARY KEY AUTOINCREMENT, from_turn INTEGER, to_turn INTEGER, at REAL NOT NULL, level TEXT NOT NULL, text TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS open_threads(
              id INTEGER PRIMARY KEY AUTOINCREMENT, opened_at REAL NOT NULL, kind TEXT, prompt TEXT, state TEXT, expires_at REAL);
            CREATE TABLE IF NOT EXISTS working_memory(
              key TEXT PRIMARY KEY, value TEXT NOT NULL, at REAL NOT NULL, expires_at REAL);
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value REAL);
            CREATE TABLE IF NOT EXISTS events(
              id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, kind TEXT NOT NULL, state TEXT NOT NULL, detail TEXT, record_id INTEGER);
            CREATE INDEX IF NOT EXISTS events_at ON events(at);
            """, nil, nil, nil)
    }

    // MARK: Turns

    @discardableResult
    func append(_ turn: DialogTurn) -> Int64 {
        run("INSERT INTO turns(at, speaker, text, tool, record_ids, intent_ids, looked) VALUES(?,?,?,?,?,?,?)",
            [turn.at.timeIntervalSince1970, turn.speaker.rawValue, turn.text, turn.tool,
             turn.recordIDs.isEmpty ? nil : turn.recordIDs.map(String.init).joined(separator: ","),
             turn.intentIDs.isEmpty ? nil : turn.intentIDs.joined(separator: ","), turn.looked ? 1 : 0])
        return sqlite3_last_insert_rowid(db)
    }

    /// The reply actually given replaced the one written down (a warning took its place).
    func setText(id: Int64, _ text: String) { run("UPDATE turns SET text=? WHERE id=?", [text, id]) }

    private static let columns = "id, at, speaker, text, tool, record_ids, intent_ids, looked"

    private static func turn(_ s: OpaquePointer) -> DialogTurn? {
        func text(_ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
        return DialogTurn(id: sqlite3_column_int64(s, 0), at: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                          speaker: DialogTurn.Speaker(rawValue: text(2) ?? "") ?? .user, text: text(3) ?? "", tool: text(4),
                          recordIDs: (text(5) ?? "").split(separator: ",").compactMap { Int64($0) },
                          intentIDs: (text(6) ?? "").split(separator: ",").map(String.init), looked: sqlite3_column_int(s, 7) != 0)
    }

    /// When the current conversation began ("new chat" moves it; summaries of before stay).
    var sessionStart: Date {
        Date(timeIntervalSince1970: query("SELECT value FROM meta WHERE key='session_start'", []) { sqlite3_column_double($0, 0) }.first ?? 0)
    }

    func startSession(at date: Date = Date()) {
        run("INSERT INTO meta(key, value) VALUES('session_start', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [date.timeIntervalSince1970])
    }

    /// Id of the last turn already folded into a summary.
    var summarizedThrough: Int64 {
        query("SELECT MAX(to_turn) FROM summaries WHERE level='session'", []) { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    /// The spoken turns not yet summarised, oldest first (what the model reads word for word).
    func openTurns(since: Date, includeNotes: Bool = false) -> [DialogTurn] {
        let floor = max(since.timeIntervalSince1970, sessionStart.timeIntervalSince1970)
        return query("SELECT \(Self.columns) FROM turns WHERE at >= ? AND id > ?\(includeNotes ? "" : " AND speaker != 'system_note'") ORDER BY id ASC",
                     [floor, summarizedThrough], Self.turn)
    }

    /// The newest turns, oldest first (for rebuilding the conversation after a restart).
    func latest(limit: Int) -> [DialogTurn] {
        query("SELECT \(Self.columns) FROM turns WHERE speaker != 'system_note' AND at >= ? ORDER BY id DESC LIMIT \(limit)",
              [sessionStart.timeIntervalSince1970], Self.turn).reversed()
    }

    /// Earlier turns that mention the words asked for, best first (the `recall_dialog` tool).
    func search(_ words: String, limit: Int = 6) -> [DialogTurn] {
        let terms = Set(words.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 })
        guard !terms.isEmpty else { return [] }
        let rows = query("SELECT \(Self.columns) FROM turns WHERE speaker != 'system_note' ORDER BY id DESC LIMIT 2000", [], Self.turn)
        return rows.map { turn -> (DialogTurn, Int) in
            let text = turn.text.lowercased()
            return (turn, terms.filter { text.contains($0) }.count)
        }
        .filter { $0.1 > 0 }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id > $1.0.id }.prefix(limit).map(\.0)
    }

    // MARK: Summaries

    struct Summary: Sendable { var at: Date; var level: String; var text: String }

    func addSummary(from: Int64, to: Int64, level: String, text: String, at: Date = Date()) {
        run("INSERT INTO summaries(from_turn, to_turn, at, level, text) VALUES(?,?,?,?,?)", [from, to, at.timeIntervalSince1970, level, text])
    }

    func summaries(since: Date) -> [Summary] {
        query("SELECT at, level, text FROM summaries WHERE at >= ? ORDER BY id ASC", [since.timeIntervalSince1970]) { s in
            Summary(at: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)),
                    level: sqlite3_column_text(s, 1).map { String(cString: $0) } ?? "session",
                    text: sqlite3_column_text(s, 2).map { String(cString: $0) } ?? "")
        }
    }

    // MARK: Working memory

    /// A short note the model keeps for itself, until `ttl` runs out (nil: until replaced).
    func remember(key: String, value: String, ttl: TimeInterval?, now: Date = Date()) {
        run("INSERT INTO working_memory(key, value, at, expires_at) VALUES(?,?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, at=excluded.at, expires_at=excluded.expires_at",
            [key, value, now.timeIntervalSince1970, ttl.map { now.addingTimeInterval($0).timeIntervalSince1970 }])
    }

    func forget(key: String) { run("DELETE FROM working_memory WHERE key=?", [key]) }

    func notes(now: Date = Date()) -> [(key: String, value: String, until: Date?)] {
        run("DELETE FROM working_memory WHERE expires_at IS NOT NULL AND expires_at < ?", [now.timeIntervalSince1970])
        return query("SELECT key, value, expires_at FROM working_memory ORDER BY at ASC", []) { s in
            (sqlite3_column_text(s, 0).map { String(cString: $0) } ?? "", sqlite3_column_text(s, 1).map { String(cString: $0) } ?? "",
             sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 2)))
        }
    }

    // MARK: Events

    /// What reached the agent and what became of it (pipeline v2: no event is dropped without
    /// a trace): `queued`, `handled`, `merged` into a newer one, or `expired`, with the reason.
    func logEvent(kind: String, state: String, detail: String? = nil, recordID: Int64? = nil, at: Date = Date()) {
        run("INSERT INTO events(at, kind, state, detail, record_id) VALUES(?,?,?,?,?)",
            [at.timeIntervalSince1970, kind, state, detail.map { String($0.prefix(300)) }, recordID])
    }

    /// Counts per kind and state since a time ("record.noticed handled: 12").
    func eventCounts(since: Date) -> [String] {
        query("SELECT kind, state, COUNT(*) FROM events WHERE at >= ? GROUP BY kind, state ORDER BY kind, state", [since.timeIntervalSince1970]) { s in
            "\(sqlite3_column_text(s, 0).map { String(cString: $0) } ?? "") \(sqlite3_column_text(s, 1).map { String(cString: $0) } ?? ""): \(sqlite3_column_int(s, 2))"
        }
    }

    // MARK: Housekeeping

    func delete(since: Date) {
        let t = since.timeIntervalSince1970
        run("DELETE FROM turns WHERE at >= ?", [t])
        run("DELETE FROM summaries WHERE at >= ?", [t])
        run("DELETE FROM working_memory WHERE at >= ?", [t])
    }

    func deleteAll() {
        for table in ["turns", "summaries", "open_threads", "working_memory", "meta", "events"] { run("DELETE FROM \(table)", []) }
    }

    func purge(olderThanDays days: Int, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        run("DELETE FROM turns WHERE at < ?", [cutoff])
        run("DELETE FROM summaries WHERE at < ?", [cutoff])
        run("DELETE FROM events WHERE at < ?", [cutoff])
    }

    // MARK: SQLite

    private func run(_ sql: String, _ args: [Any?]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        sqlite3_step(stmt)
    }

    private func query<T>(_ sql: String, _ args: [Any?], _ map: (OpaquePointer) -> T?) -> [T] {
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
}
