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
        try validateAlarms(draft.alarms, relative: draft.relativeAlarms, locations: draft.locationAlarms)
        try validateLocation(draft.location); try validateURL(draft.url); try validateTimeZone(draft.timeZoneIdentifier); try validateRecurrence(draft.recurrence)
    }

    private func validate(_ patch: ReminderPatch) throws {
        if let title = patch.title { try validateTitle(title) }
        if case .set(let notes) = patch.notes { try validateNotes(notes) }
        try validateAlarms(patch.addAlarms, relative: patch.addRelativeAlarms, locations: patch.addLocationAlarms)
        if case .set(let location) = patch.location { try validateLocation(location) }
        if case .set(let url) = patch.url { try validateURL(url) }
        if case .set(let zone) = patch.timeZoneIdentifier { try validateTimeZone(zone) }
        if let recurrence = patch.recurrence { try validateRecurrence(recurrence) }
        if patch.clearRecurrence && patch.recurrence != nil { throw ProcessorError(code: "invalid_recurrence", message: "Cannot set and clear recurrence together.") }
    }

    private func validateTitle(_ title: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 500 else { throw ProcessorError(code: "invalid_title", message: "Title must contain 1 to 500 characters.") }
        guard !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ProcessorError(code: "invalid_title", message: "Title cannot contain control characters.") }
    }

    private func validateAlarms(_ alarms: [Date], relative: [TimeInterval], locations: [ReminderLocationAlarmDraft]) throws {
        guard alarms.count + relative.count + locations.count <= 10 else { throw ProcessorError(code: "too_many_alarms", message: "At most 10 alarms may be added at once.") }
        guard relative.allSatisfy(\.isFinite) else { throw ProcessorError(code: "invalid_alarm_offset", message: "Relative alarm offsets must be finite seconds.") }
        guard locations.allSatisfy({ (-90.0...90.0).contains($0.latitude) && (-180.0...180.0).contains($0.longitude) && $0.radiusMeters >= 0 && ["enter", "leave"].contains($0.proximity) }) else { throw ProcessorError(code: "invalid_location_alarm", message: "Location alarm coordinates, radius, or proximity are invalid.") }
    }

    private func validateLocation(_ location: String?) throws { guard (location?.count ?? 0) <= 500 else { throw ProcessorError(code: "location_too_long", message: "Location must be 500 characters or fewer.") } }
    private func validateURL(_ url: URL?) throws { guard let url else { return }; guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { throw ProcessorError(code: "invalid_url", message: "URL must use http or https.") } }
    private func validateTimeZone(_ identifier: String?) throws { guard let identifier else { return }; guard TimeZone(identifier: identifier) != nil else { throw ProcessorError(code: "invalid_timezone", message: "Use a valid IANA time zone identifier.") } }
    private func validateRecurrence(_ rules: [ReminderRecurrence]) throws {
        guard rules.count <= 1 else { throw ProcessorError(code: "invalid_recurrence", message: "Taski supports one recurrence rule per reminder.") }
        for rule in rules { guard rule.interval > 0 else { throw ProcessorError(code: "invalid_recurrence", message: "Recurrence interval must be positive.") }; if case .occurrences(let count) = rule.end, count <= 0 { throw ProcessorError(code: "invalid_recurrence", message: "Recurrence count must be positive.") } }
    }

    private func validateNotes(_ notes: String?) throws {
        guard let notes else { return }
        guard notes.count <= 4_000 else { throw ProcessorError(code: "notes_too_long", message: "Notes must be 4,000 characters or fewer.") }
        let forbidden = notes.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }
        guard !forbidden else { throw ProcessorError(code: "invalid_notes", message: "Notes cannot contain control characters other than newline or tab.") }
    }

    private func missing() -> ProcessorError { ProcessorError(code: "reminder_missing", message: "No reminder with that identifier exists in the configured inbox.") }
}
