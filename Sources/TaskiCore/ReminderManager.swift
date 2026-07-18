import Foundation

public struct ReminderManager: Sendable {
    private let store: any ReminderCRUDStore
    private let ledger: Ledger
    private let calendarIdentifier: String
    private let sourceIdentifier: String

    public init(store: any ReminderCRUDStore, ledger: Ledger, calendarIdentifier: String, sourceIdentifier: String) {
        self.store = store; self.ledger = ledger; self.calendarIdentifier = calendarIdentifier; self.sourceIdentifier = sourceIdentifier
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
        return try await store.create(calendarIdentifier: calendarIdentifier, sourceIdentifier: sourceIdentifier, draft: draft)
    }

    public func edit(identifier: String, patch: ReminderPatch) async throws -> ReminderSnapshot {
        try await requireAccess(); try validate(patch)
        let reminder = try await resolve(identifier: identifier)
        return try await store.update(localIdentifier: reminder.localIdentifier, calendarIdentifier: calendarIdentifier, patch: patch)
    }

    public func setCompleted(identifier: String, completed: Bool) async throws -> ReminderSnapshot {
        try await requireAccess()
        let reminder = try await resolve(identifier: identifier)
        return try await store.setCompleted(localIdentifier: reminder.localIdentifier, calendarIdentifier: calendarIdentifier, completed: completed)
    }

    public func delete(identifier: String) async throws {
        try await requireAccess()
        let reminder = try await resolve(identifier: identifier)
        try await store.delete(localIdentifier: reminder.localIdentifier, calendarIdentifier: calendarIdentifier)
    }

    private func inboxReminders() async throws -> [ReminderSnapshot] {
        try await store.fetchAll(calendarIdentifier: calendarIdentifier).filter { $0.calendarIdentifier == calendarIdentifier && $0.sourceIdentifier == sourceIdentifier }
    }

    private func resolve(identifier: String) async throws -> ReminderSnapshot {
        let reminders = try await inboxReminders()
        if let exact = reminders.first(where: { $0.localIdentifier == identifier }) { return exact }
        guard let task = try ledger.task(id: identifier) else { throw missing() }
        if let local = reminders.first(where: { $0.localIdentifier == task.localIdentifier }) { return local }
        if let external = task.externalIdentifier {
            let matches = reminders.filter { $0.externalIdentifier == external }
            if matches.count == 1 { return matches[0] }
        }
        let fingerprintMatches = reminders.filter { $0.fingerprint == task.fingerprint }
        guard fingerprintMatches.count == 1 else {
            if fingerprintMatches.count > 1 { throw ProcessorError(code: "ambiguous_reminder", message: "Multiple inbox reminders match this task; use a current reminder identifier.") }
            throw missing()
        }
        return fingerprintMatches[0]
    }

    private func requireAccess() async throws {
        let status = await store.authorizationStatus()
        guard status == .fullAccess else { throw ProcessorError(code: "access_\(status.rawValue)", message: "Full Reminders access is required.") }
    }

    private func validate(_ draft: ReminderDraft) throws {
        try validateTitle(draft.title)
        guard (draft.notes?.count ?? 0) <= 4_000 else { throw ProcessorError(code: "notes_too_long", message: "Notes must be 4,000 characters or fewer.") }
        try validateAlarms(draft.alarms)
    }

    private func validate(_ patch: ReminderPatch) throws {
        if let title = patch.title { try validateTitle(title) }
        if case .set(let notes) = patch.notes, notes.count > 4_000 { throw ProcessorError(code: "notes_too_long", message: "Notes must be 4,000 characters or fewer.") }
        try validateAlarms(patch.addAlarms)
    }

    private func validateTitle(_ title: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 500 else { throw ProcessorError(code: "invalid_title", message: "Title must contain 1 to 500 characters.") }
        guard !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ProcessorError(code: "invalid_title", message: "Title cannot contain control characters.") }
    }

    private func validateAlarms(_ alarms: [Date]) throws {
        guard alarms.count <= 10 else { throw ProcessorError(code: "too_many_alarms", message: "At most 10 alarms may be added at once.") }
    }

    private func missing() -> ProcessorError { ProcessorError(code: "reminder_missing", message: "No reminder with that identifier exists in the configured inbox.") }
}
