import EventKit
import Foundation

public struct ReminderListDescriptor: Sendable {
    public let sourceIdentifier: String
    public let sourceName: String
    public let calendarIdentifier: String
    public let calendarName: String
    public let sourceType: String
}

public final class EventKitReminderStore: ReminderStore, ReminderCRUDStore, @unchecked Sendable {
    private let eventStore = EKEventStore()

    public init() {}

    public func authorizationStatus() async -> ReminderAuthorization {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess, .authorized: return .fullAccess
        default: return .unknown
        }
    }

    public func requestAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToReminders()
    }

    public func lists() -> [ReminderListDescriptor] {
        eventStore.calendars(for: .reminder).map { calendar in
            ReminderListDescriptor(sourceIdentifier: calendar.source.sourceIdentifier, sourceName: calendar.source.title, calendarIdentifier: calendar.calendarIdentifier, calendarName: calendar.title, sourceType: Self.sourceType(calendar.source.sourceType))
        }.sorted { ($0.sourceName, $0.calendarName) < ($1.sourceName, $1.calendarName) }
    }

    public func fetchIncomplete(calendarIdentifier: String) async throws -> [ReminderSnapshot] {
        let calendar = try configuredCalendar(identifier: calendarIdentifier)
        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [calendar])
        return await fetch(predicate: predicate)
    }

    public func fetchAll(calendarIdentifier: String) async throws -> [ReminderSnapshot] {
        let calendar = try configuredCalendar(identifier: calendarIdentifier)
        return await fetch(predicate: eventStore.predicateForReminders(in: [calendar]))
    }

    public func create(calendarIdentifier: String, sourceIdentifier: String, draft: ReminderDraft) async throws -> ReminderSnapshot {
        let calendar = try configuredCalendar(identifier: calendarIdentifier)
        guard calendar.source.sourceIdentifier == sourceIdentifier else { throw ProcessorError(code: "source_changed", message: "The configured reminder source changed; run setup again.") }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.dueDateComponents = draft.dueDate.map(dateComponents)
        reminder.priority = draft.priority.rawValue
        reminder.alarms = draft.alarms.map(EKAlarm.init(absoluteDate:))
        try eventStore.save(reminder, commit: true)
        return snapshot(reminder)
    }

    public func update(localIdentifier: String, calendarIdentifier: String, patch: ReminderPatch) async throws -> ReminderSnapshot {
        let reminder = try configuredReminder(localIdentifier: localIdentifier, calendarIdentifier: calendarIdentifier)
        if let title = patch.title { reminder.title = title }
        switch patch.notes { case .unchanged: break; case .set(let notes): reminder.notes = notes; case .clear: reminder.notes = nil }
        switch patch.dueDate { case .unchanged: break; case .set(let date): reminder.dueDateComponents = dateComponents(date); case .clear: reminder.dueDateComponents = nil }
        if let priority = patch.priority { reminder.priority = priority.rawValue }
        var alarms = patch.clearAlarms ? [] : reminder.alarms ?? []
        alarms.append(contentsOf: patch.addAlarms.map(EKAlarm.init(absoluteDate:)))
        reminder.alarms = alarms
        try eventStore.save(reminder, commit: true)
        return snapshot(reminder)
    }

    public func setCompleted(localIdentifier: String, calendarIdentifier: String, completed: Bool) async throws -> ReminderSnapshot {
        let reminder = try configuredReminder(localIdentifier: localIdentifier, calendarIdentifier: calendarIdentifier)
        reminder.isCompleted = completed
        try eventStore.save(reminder, commit: true)
        return snapshot(reminder)
    }

    public func delete(localIdentifier: String, calendarIdentifier: String) async throws {
        let reminder = try configuredReminder(localIdentifier: localIdentifier, calendarIdentifier: calendarIdentifier)
        try eventStore.remove(reminder, commit: true)
    }

    public func complete(localIdentifier: String, expectedFingerprint: String) async throws {
        guard let reminder = eventStore.calendarItem(withIdentifier: localIdentifier) as? EKReminder else {
            throw ProcessorError(code: "reminder_missing", message: "The source reminder no longer exists.")
        }
        let current = ReminderSnapshot(localIdentifier: reminder.calendarItemIdentifier, externalIdentifier: reminder.calendarItemExternalIdentifier, calendarIdentifier: reminder.calendar.calendarIdentifier, sourceIdentifier: reminder.calendar.source.sourceIdentifier, title: reminder.title, notes: reminder.notes)
        guard current.fingerprint == expectedFingerprint else {
            throw ProcessorError(code: "source_changed", message: "The reminder changed during execution and was not completed automatically.")
        }
        reminder.isCompleted = true
        reminder.completionDate = Date()
        try eventStore.save(reminder, commit: true)
    }

    public func updateNote(localIdentifier: String, status: String) async throws {
        guard status.count <= 160, let reminder = eventStore.calendarItem(withIdentifier: localIdentifier) as? EKReminder else { return }
        let existing = reminder.notes?.split(separator: "\n").filter { !$0.hasPrefix("Taski: ") }.joined(separator: "\n")
        reminder.notes = [existing, "Taski: \(status)"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        try eventStore.save(reminder, commit: true)
    }

    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let token = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: nil) { _ in continuation.yield(()) }
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token) }
        }
    }

    private func fetch(predicate: NSPredicate) async -> [ReminderSnapshot] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { [self] reminders in continuation.resume(returning: (reminders ?? []).map(snapshot)) }
        }
    }

    private func configuredCalendar(identifier: String) throws -> EKCalendar {
        guard let calendar = eventStore.calendar(withIdentifier: identifier) else { throw ProcessorError(code: "calendar_missing", message: "The configured Reminders list no longer exists. Run `taski setup`.") }
        return calendar
    }

    private func configuredReminder(localIdentifier: String, calendarIdentifier: String) throws -> EKReminder {
        guard let reminder = eventStore.calendarItem(withIdentifier: localIdentifier) as? EKReminder else { throw ProcessorError(code: "reminder_missing", message: "The reminder no longer exists.") }
        guard reminder.calendar.calendarIdentifier == calendarIdentifier else { throw ProcessorError(code: "outside_inbox", message: "The reminder is not in the configured inbox.") }
        return reminder
    }

    private func snapshot(_ reminder: EKReminder) -> ReminderSnapshot {
        let dueDate = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        let alarms: [ReminderAlarm] = (reminder.alarms ?? []).map { alarm in
            if let date = alarm.absoluteDate { return .absolute(date) }
            if let location = alarm.structuredLocation {
                let proximity: String
                switch alarm.proximity { case .enter: proximity = "enter"; case .leave: proximity = "leave"; case .none: proximity = "none"; @unknown default: proximity = "unknown" }
                return .location(name: location.title, latitude: location.geoLocation?.coordinate.latitude, longitude: location.geoLocation?.coordinate.longitude, radiusMeters: location.radius, proximity: proximity)
            }
            return .relative(seconds: alarm.relativeOffset)
        }
        return ReminderSnapshot(localIdentifier: reminder.calendarItemIdentifier, externalIdentifier: reminder.calendarItemExternalIdentifier, calendarIdentifier: reminder.calendar.calendarIdentifier, sourceIdentifier: reminder.calendar.source.sourceIdentifier, title: reminder.title, notes: reminder.notes, isCompleted: reminder.isCompleted, dueDate: dueDate, priority: ReminderPriority(rawValue: reminder.priority) ?? .none, alarms: alarms)
    }

    private func dateComponents(_ date: Date) -> DateComponents {
        var components = Calendar.current.dateComponents(in: TimeZone.current, from: date)
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        return components
    }

    private static func sourceType(_ type: EKSourceType) -> String {
        switch type { case .local: return "local"; case .exchange: return "exchange"; case .calDAV: return "caldav"; case .mobileMe: return "icloud"; case .subscribed: return "subscribed"; case .birthdays: return "birthdays"; @unknown default: return "unknown" }
    }
}
