import Foundation

public struct ReminderManager: Sendable {
    private let store: any ReminderCRUDStore
    private let ledger: Ledger
    private let calendarIdentifier: String
    private let sourceIdentifier: String
    private let lockPath: String?

    public init(store: any ReminderCRUDStore, ledger: Ledger, calendarIdentifier: String, sourceIdentifier: String, lockPath: String? = nil) {
        self.store = store; self.ledger = ledger; self.calendarIdentifier = calendarIdentifier; self.sourceIdentifier = sourceIdentifier; self.lockPath = lockPath
    }

    public func list(includeCompleted: Bool) async throws -> [ReminderSnapshot] {
        try await requireAccess()
        return try await inboxReminders().filter { includeCompleted || !$0.isCompleted }.sorted { ($0.dueDate ?? .distantFuture, $0.title) < ($1.dueDate ?? .distantFuture, $1.title) }
    }

    public func show(identifier: String) async throws -> ReminderSnapshot {
        try await requireAccess()
        return try await resolve(identifier: identifier)
    }

    public func create(_ draft: ReminderDraft) async throws -> ReminderSnapshot {
        try await requireAccess(); try validate(draft)
        let lock = try ProcessLock(path: lockPath); defer { lock.unlock() }
        return try await store.create(calendarIdentifier: calendarIdentifier, sourceIdentifier: sourceIdentifier, draft: draft)
    }

    public func edit(identifier: String, patch: ReminderPatch) async throws -> ReminderSnapshot {
        try await requireAccess(); try validate(patch)
        let lock = try ProcessLock(path: lockPath); defer { lock.unlock() }
        let reminder = try await resolve(identifier: identifier)
        let updated = try await store.update(localIdentifier: reminder.localIdentifier, calendarIdentifier: calendarIdentifier, patch: patch)
        if !reminder.isCompleted, let task = try ledger.task(matching: reminder), task.state == .succeeded {
            try ledger.supersede(taskID: task.taskID, detail: "operator edited a completion-pending reminder")
        }
        return updated
    }

    public func setCompleted(identifier: String, completed: Bool) async throws -> ReminderSnapshot {
        try await requireAccess()
        let lock = try ProcessLock(path: lockPath); defer { lock.unlock() }
        let reminder = try await resolve(identifier: identifier)
        let updated = try await store.setCompleted(localIdentifier: reminder.localIdentifier, calendarIdentifier: calendarIdentifier, completed: completed)
        if let task = try ledger.task(matching: reminder) {
            if !completed, task.state == .succeeded { try ledger.supersede(taskID: task.taskID, detail: "operator reopened source reminder") }
            if completed, [.discovered, .rejected, .awaitingApproval, .queued, .failed].contains(task.state) { try ledger.cancel(taskID: task.taskID) }
        }
        return updated
    }

    public func delete(identifier: String, expectedFingerprint: String? = nil) async throws {
        try await requireAccess()
        let lock = try ProcessLock(path: lockPath); defer { lock.unlock() }
        let reminder = try await resolve(identifier: identifier)
        if let expectedFingerprint, reminder.fingerprint != expectedFingerprint { throw ProcessorError(code: "source_changed", message: "The reminder changed after confirmation and was not deleted.") }
        try await store.delete(localIdentifier: reminder.localIdentifier, calendarIdentifier: calendarIdentifier)
        if let task = try ledger.task(matching: reminder), [.discovered, .rejected, .awaitingApproval, .queued, .failed].contains(task.state) { try ledger.cancel(taskID: task.taskID) }
    }

    private func inboxReminders() async throws -> [ReminderSnapshot] {
        try await store.fetchAll(calendarIdentifier: calendarIdentifier).filter { $0.calendarIdentifier == calendarIdentifier && $0.sourceIdentifier == sourceIdentifier }
    }

    private func resolve(identifier: String) async throws -> ReminderSnapshot {
        let reminders = try await inboxReminders()
        if let task = try ledger.task(id: identifier) {
            guard task.calendarIdentifier == calendarIdentifier, task.sourceIdentifier == sourceIdentifier else { throw ProcessorError(code: "outside_inbox", message: "The task belongs to a different reminder list.") }
            if let external = task.externalIdentifier {
            let matches = reminders.filter { $0.externalIdentifier == external }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw ProcessorError(code: "ambiguous_reminder", message: "Multiple inbox reminders share this external identifier; use a current reminder identifier.") }
                throw missing()
            }
            if let local = reminders.first(where: { $0.localIdentifier == task.localIdentifier && $0.fingerprint == task.fingerprint }) { return local }
            throw missing()
        }
        if let exact = reminders.first(where: { $0.localIdentifier == identifier }) { return exact }
        throw missing()
    }

    private func requireAccess() async throws {
        let status = await store.authorizationStatus()
        guard status == .fullAccess else { throw ProcessorError(code: "access_\(status.rawValue)", message: "Full Reminders access is required.") }
    }

    private func validate(_ draft: ReminderDraft) throws {
        try validateTitle(draft.title)
        try validateNotes(draft.notes)
        try validateAlarms(draft.alarms)
    }

    private func validate(_ patch: ReminderPatch) throws {
        if let title = patch.title { try validateTitle(title) }
        if case .set(let notes) = patch.notes { try validateNotes(notes) }
        try validateAlarms(patch.addAlarms)
    }

    private func validateTitle(_ title: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 500 else { throw ProcessorError(code: "invalid_title", message: "Title must contain 1 to 500 characters.") }
        guard !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ProcessorError(code: "invalid_title", message: "Title cannot contain control characters.") }
    }

    private func validateAlarms(_ alarms: [Date]) throws {
        guard alarms.count <= 10 else { throw ProcessorError(code: "too_many_alarms", message: "At most 10 alarms may be added at once.") }
    }

    private func validateNotes(_ notes: String?) throws {
        guard let notes else { return }
        guard notes.count <= 4_000 else { throw ProcessorError(code: "notes_too_long", message: "Notes must be 4,000 characters or fewer.") }
        let forbidden = notes.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }
        guard !forbidden else { throw ProcessorError(code: "invalid_notes", message: "Notes cannot contain control characters other than newline or tab.") }
    }

    private func missing() -> ProcessorError { ProcessorError(code: "reminder_missing", message: "No reminder with that identifier exists in the configured inbox.") }
}
