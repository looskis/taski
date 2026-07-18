import Foundation
import SQLite3

public final class Ledger: @unchecked Sendable {
    private let db: OpaquePointer
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        var handle: OpaquePointer?
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            throw ProcessorError(code: "database_open", message: "Could not open the task ledger.")
        }
        db = handle
        try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try execute("""
        CREATE TABLE IF NOT EXISTS tasks (
          task_id TEXT PRIMARY KEY, local_id TEXT NOT NULL, external_id TEXT,
          calendar_id TEXT NOT NULL, source_id TEXT NOT NULL, fingerprint TEXT NOT NULL,
          original_title TEXT NOT NULL, original_notes TEXT, state TEXT NOT NULL,
          processor_name TEXT, attempt_count INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL, updated_at REAL NOT NULL, started_at REAL, finished_at REAL,
          approved_at REAL, result_summary TEXT, error_code TEXT, error_message TEXT
        );
        CREATE INDEX IF NOT EXISTS tasks_external ON tasks(external_id, calendar_id, source_id);
        CREATE INDEX IF NOT EXISTS tasks_local ON tasks(local_id, calendar_id);
        CREATE INDEX IF NOT EXISTS tasks_fingerprint ON tasks(fingerprint, calendar_id, source_id);
        CREATE TABLE IF NOT EXISTS audit (
          id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL,
          from_state TEXT, to_state TEXT NOT NULL, occurred_at REAL NOT NULL, detail TEXT,
          FOREIGN KEY(task_id) REFERENCES tasks(task_id)
        );
        CREATE TABLE IF NOT EXISTS metrics (key TEXT PRIMARY KEY, value REAL NOT NULL);
        PRAGMA user_version=1;
        """)
    }

    deinit { sqlite3_close(db) }

    public func discover(_ reminder: ReminderSnapshot, currentLocalIdentifiers: Set<String>? = nil) throws -> TaskRecord {
        try locked { try transaction {
            if let existing = try find(reminder, currentLocalIdentifiers: currentLocalIdentifiers) {
                let editableFailure = existing.state == .failed && existing.attemptCount == 0
                if ([.discovered, .rejected, .awaitingApproval, .queued].contains(existing.state) || editableFailure), existing.fingerprint != reminder.fingerprint {
                    try updateUnstarted(existing, reminder)
                } else if existing.localIdentifier != reminder.localIdentifier {
                    try run("UPDATE tasks SET local_id=?, updated_at=? WHERE task_id=?", [reminder.localIdentifier, Date().timeIntervalSince1970, existing.taskID])
                }
                return try get(existing.taskID)!
            }
            let taskID = UUID().uuidString.lowercased()
            let now = Date().timeIntervalSince1970
            let ambiguous = try hasAmbiguousRecovery(reminder, currentLocalIdentifiers: currentLocalIdentifiers)
            let initialState: TaskState = ambiguous ? .rejected : .discovered
            let errorCode = ambiguous ? "ambiguous_identity" : nil
            let errorMessage = ambiguous ? "Multiple prior tasks match this reminder; operator inspection is required to avoid duplicate execution." : nil
            try run("INSERT INTO tasks(task_id,local_id,external_id,calendar_id,source_id,fingerprint,original_title,original_notes,state,created_at,updated_at,error_code,error_message) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", [taskID, reminder.localIdentifier, reminder.externalIdentifier, reminder.calendarIdentifier, reminder.sourceIdentifier, reminder.fingerprint, reminder.title, reminder.notes, initialState.rawValue, now, now, errorCode, errorMessage])
            try auditLocked(taskID, nil, initialState, errorMessage ?? "reminder discovered")
            return try get(taskID)!
        } }
    }

    public func transition(taskID: String, to state: TaskState, processor: String? = nil, summary: String?, error: ProcessorError?) throws {
        try locked { try transaction {
            guard let current = try get(taskID) else { throw ProcessorError(code: "task_not_found", message: "Task not found.") }
            let now = Date().timeIntervalSince1970
            let started: Any? = state == .running ? now : nil
            let finished: Any? = [.succeeded, .failed, .rejected, .cancelled].contains(state) ? now : nil
            let attempts = current.attemptCount + (state == .running ? 1 : 0)
            try run("UPDATE tasks SET state=?,processor_name=COALESCE(?,processor_name),attempt_count=?,updated_at=?,started_at=COALESCE(?,started_at),finished_at=?,result_summary=?,error_code=?,error_message=? WHERE task_id=?", [state.rawValue, processor, attempts, now, started, finished, summary, error?.code, error?.message, taskID])
            try auditLocked(taskID, current.state, state, summary ?? error?.message)
        } }
    }

    public func approve(taskID: String) throws {
        try locked { try transaction {
            guard let current = try get(taskID), current.state == .awaitingApproval else { throw ProcessorError(code: "not_awaiting_approval", message: "Task is not awaiting approval.") }
            try run("UPDATE tasks SET state=?,approved_at=?,updated_at=? WHERE task_id=?", [TaskState.queued.rawValue, Date().timeIntervalSince1970, Date().timeIntervalSince1970, taskID])
            try auditLocked(taskID, current.state, .queued, "explicitly approved")
        } }
    }

    public func retry(taskID: String) throws {
        try locked { try transaction {
            guard let current = try get(taskID), [.failed, .rejected].contains(current.state) else { throw ProcessorError(code: "not_retryable", message: "Only failed or rejected tasks can be retried.") }
            guard !["timeout", "interrupted"].contains(current.errorCode) else { throw ProcessorError(code: "outcome_unknown", message: "This task may have produced an external effect. Inspect and resolve that outcome before creating a replacement task.") }
            try run("UPDATE tasks SET state=?,error_code=NULL,error_message=NULL,finished_at=NULL,updated_at=? WHERE task_id=?", [TaskState.discovered.rawValue, Date().timeIntervalSince1970, taskID])
            try auditLocked(taskID, current.state, .discovered, "explicit retry")
        } }
    }

    public func cancel(taskID: String) throws {
        try locked { try transaction {
            guard let current = try get(taskID) else { throw ProcessorError(code: "task_not_found", message: "Task not found.") }
            guard [.discovered, .rejected, .awaitingApproval, .queued, .failed].contains(current.state) else {
                throw ProcessorError(code: "not_cancellable", message: "Running or succeeded tasks cannot be cancelled safely.")
            }
            try run("UPDATE tasks SET state=?,finished_at=?,updated_at=? WHERE task_id=?", [TaskState.cancelled.rawValue, Date().timeIntervalSince1970, Date().timeIntervalSince1970, taskID])
            try auditLocked(taskID, current.state, .cancelled, "cancelled by operator before execution")
        } }
    }

    public func task(id: String) throws -> TaskRecord? { try locked { try get(id) } }
    public func tasks() throws -> [TaskRecord] { try locked { try queryTasks("SELECT * FROM tasks ORDER BY created_at DESC", []) } }
    public func audit(taskID: String) throws -> [AuditEntry] { try locked { try queryAudit(taskID) } }
    public func recordMetric(_ key: String, at date: Date = Date()) throws { try locked { try run("INSERT INTO metrics(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, date.timeIntervalSince1970]) } }
    public func metrics() throws -> [String: Date] {
        try locked {
            var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, "SELECT key,value FROM metrics", -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
            defer { sqlite3_finalize(statement) }; var result: [String: Date] = [:]
            while sqlite3_step(statement) == SQLITE_ROW { result[String(cString: sqlite3_column_text(statement, 0))] = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)) }
            return result
        }
    }

    private func find(_ reminder: ReminderSnapshot, currentLocalIdentifiers: Set<String>?) throws -> TaskRecord? {
        if let external = reminder.externalIdentifier, let match = try queryTasks("SELECT * FROM tasks WHERE external_id=? AND calendar_id=? AND source_id=? LIMIT 1", [external, reminder.calendarIdentifier, reminder.sourceIdentifier]).first { return match }
        if let match = try queryTasks("SELECT * FROM tasks WHERE local_id=? AND calendar_id=? LIMIT 1", [reminder.localIdentifier, reminder.calendarIdentifier]).first { return match }
        guard let currentLocalIdentifiers else { return nil }
        let candidates = try queryTasks("SELECT * FROM tasks WHERE fingerprint=? AND calendar_id=? AND source_id=?", [reminder.fingerprint, reminder.calendarIdentifier, reminder.sourceIdentifier])
        let recoverable = candidates.filter { !currentLocalIdentifiers.contains($0.localIdentifier) }
        return recoverable.count == 1 ? recoverable[0] : nil
    }

    private func hasAmbiguousRecovery(_ reminder: ReminderSnapshot, currentLocalIdentifiers: Set<String>?) throws -> Bool {
        guard let currentLocalIdentifiers else { return false }
        let candidates = try queryTasks("SELECT * FROM tasks WHERE fingerprint=? AND calendar_id=? AND source_id=?", [reminder.fingerprint, reminder.calendarIdentifier, reminder.sourceIdentifier])
        return candidates.filter { !currentLocalIdentifiers.contains($0.localIdentifier) }.count > 1
    }

    private func updateUnstarted(_ task: TaskRecord, _ reminder: ReminderSnapshot) throws {
        try run("UPDATE tasks SET local_id=?,external_id=?,fingerprint=?,original_title=?,original_notes=?,state=?,processor_name=NULL,approved_at=NULL,error_code=NULL,error_message=NULL,updated_at=? WHERE task_id=?", [reminder.localIdentifier, reminder.externalIdentifier, reminder.fingerprint, reminder.title, reminder.notes, TaskState.discovered.rawValue, Date().timeIntervalSince1970, task.taskID])
        try auditLocked(task.taskID, task.state, .discovered, "unstarted reminder changed; classification reset")
    }

    private func get(_ id: String) throws -> TaskRecord? { try queryTasks("SELECT * FROM tasks WHERE task_id=? LIMIT 1", [id]).first }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() } }

    private func run(_ sql: String, _ values: [Any?]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { bind(value, to: statement, at: Int32(offset + 1)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func queryTasks(_ sql: String, _ values: [Any?]) throws -> [TaskRecord] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { bind(value, to: statement, at: Int32(offset + 1)) }
        var result: [TaskRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(TaskRecord(taskID: text(statement, "task_id")!, localIdentifier: text(statement, "local_id")!, externalIdentifier: text(statement, "external_id"), calendarIdentifier: text(statement, "calendar_id")!, sourceIdentifier: text(statement, "source_id")!, fingerprint: text(statement, "fingerprint")!, originalTitle: text(statement, "original_title")!, originalNotes: text(statement, "original_notes"), state: TaskState(rawValue: text(statement, "state")!)!, processorName: text(statement, "processor_name"), attemptCount: Int(integer(statement, "attempt_count")), approvedAt: date(statement, "approved_at"), resultSummary: text(statement, "result_summary"), errorCode: text(statement, "error_code"), errorMessage: text(statement, "error_message")))
        }
        return result
    }

    private func queryAudit(_ taskID: String) throws -> [AuditEntry] {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT * FROM audit WHERE task_id=? ORDER BY id", -1, &statement, nil)
        guard let statement else { throw databaseError() }; defer { sqlite3_finalize(statement) }
        bind(taskID, to: statement, at: 1)
        var result: [AuditEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(AuditEntry(taskID: taskID, fromState: text(statement, "from_state").flatMap(TaskState.init), toState: TaskState(rawValue: text(statement, "to_state")!)!, occurredAt: Date(timeIntervalSince1970: double(statement, "occurred_at")), detail: text(statement, "detail"))) }
        return result
    }

    private func auditLocked(_ id: String, _ from: TaskState?, _ to: TaskState, _ detail: String?) throws { try run("INSERT INTO audit(task_id,from_state,to_state,occurred_at,detail) VALUES(?,?,?,?,?)", [id, from?.rawValue, to.rawValue, Date().timeIntervalSince1970, detail]) }
    private func bind(_ value: Any?, to statement: OpaquePointer, at index: Int32) {
        if value == nil { sqlite3_bind_null(statement, index) }
        else if let value = value as? String { sqlite3_bind_text(statement, index, value, -1, transient) }
        else if let value = value as? Double { sqlite3_bind_double(statement, index, value) }
        else if let value = value as? Int { sqlite3_bind_int64(statement, index, sqlite3_int64(value)) }
    }
    private func column(_ statement: OpaquePointer, _ name: String) -> Int32 { for index in 0..<sqlite3_column_count(statement) where String(cString: sqlite3_column_name(statement, index)) == name { return index }; return -1 }
    private func text(_ s: OpaquePointer, _ name: String) -> String? { let i = column(s, name); guard i >= 0, let p = sqlite3_column_text(s, i) else { return nil }; return String(cString: p) }
    private func integer(_ s: OpaquePointer, _ name: String) -> Int64 { sqlite3_column_int64(s, column(s, name)) }
    private func double(_ s: OpaquePointer, _ name: String) -> Double { sqlite3_column_double(s, column(s, name)) }
    private func date(_ s: OpaquePointer, _ name: String) -> Date? { let i = column(s, name); return i >= 0 && sqlite3_column_type(s, i) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(s, i)) : nil }
    private func databaseError() -> ProcessorError { ProcessorError(code: "database", message: String(cString: sqlite3_errmsg(db))) }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T { lock.lock(); defer { lock.unlock() }; return try body() }
}
