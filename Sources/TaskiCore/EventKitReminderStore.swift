import EventKit
import Foundation
import CoreLocation

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
        reminder.timeZone = draft.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
        reminder.dueDateComponents = draft.dueDate.map { dateComponents($0, allDay: draft.dueDateIsAllDay, timeZone: reminder.timeZone) }
        reminder.startDateComponents = draft.startDate.map { dateComponents($0, allDay: draft.startDateIsAllDay, timeZone: reminder.timeZone) }
        reminder.priority = draft.priority.rawValue
        reminder.location = draft.location
        reminder.url = draft.url
        reminder.alarms = draft.alarms.map(EKAlarm.init(absoluteDate:)) + draft.relativeAlarms.map(EKAlarm.init(relativeOffset:)) + draft.locationAlarms.map(locationAlarm)
        reminder.recurrenceRules = draft.recurrence.map(recurrenceRule)
        try eventStore.save(reminder, commit: true)
        return snapshot(reminder)
    }

    public func update(localIdentifier: String, calendarIdentifier: String, patch: ReminderPatch) async throws -> ReminderSnapshot {
        let reminder = try configuredReminder(localIdentifier: localIdentifier, calendarIdentifier: calendarIdentifier)
        if let title = patch.title { reminder.title = title }
        switch patch.notes { case .unchanged: break; case .set(let notes): reminder.notes = notes; case .clear: reminder.notes = nil }
        switch patch.timeZoneIdentifier { case .unchanged: break; case .set(let identifier): reminder.timeZone = TimeZone(identifier: identifier); case .clear: reminder.timeZone = nil }
        if case .unchanged = patch.dueDate, var components = reminder.dueDateComponents, !isAllDay(components) { components.timeZone = reminder.timeZone; reminder.dueDateComponents = components }
        if case .unchanged = patch.startDate, var components = reminder.startDateComponents, !isAllDay(components) { components.timeZone = reminder.timeZone; reminder.startDateComponents = components }
        switch patch.dueDate { case .unchanged: break; case .set(let date): reminder.dueDateComponents = dateComponents(date, allDay: patch.dueDateIsAllDay ?? false, timeZone: reminder.timeZone); case .clear: reminder.dueDateComponents = nil }
        switch patch.startDate { case .unchanged: break; case .set(let date): reminder.startDateComponents = dateComponents(date, allDay: patch.startDateIsAllDay ?? false, timeZone: reminder.timeZone); case .clear: reminder.startDateComponents = nil }
        switch patch.location { case .unchanged: break; case .set(let value): reminder.location = value; case .clear: reminder.location = nil }
        switch patch.url { case .unchanged: break; case .set(let value): reminder.url = value; case .clear: reminder.url = nil }
        if let priority = patch.priority { reminder.priority = priority.rawValue }
        var alarms = patch.clearAlarms ? [] : reminder.alarms ?? []
        alarms.append(contentsOf: patch.addAlarms.map(EKAlarm.init(absoluteDate:)))
        alarms.append(contentsOf: patch.addRelativeAlarms.map(EKAlarm.init(relativeOffset:)))
        alarms.append(contentsOf: patch.addLocationAlarms.map(locationAlarm))
        reminder.alarms = alarms
        if patch.clearRecurrence { reminder.recurrenceRules = nil }
        else if let recurrence = patch.recurrence { reminder.recurrenceRules = recurrence.map(recurrenceRule) }
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
        let startDate = reminder.startDateComponents.flatMap { Calendar.current.date(from: $0) }
        let alarms: [ReminderAlarm] = (reminder.alarms ?? []).map { alarm in
            if let date = alarm.absoluteDate { return .absolute(date) }
            if let location = alarm.structuredLocation {
                let proximity: String
                switch alarm.proximity { case .enter: proximity = "enter"; case .leave: proximity = "leave"; case .none: proximity = "none"; @unknown default: proximity = "unknown" }
                return .location(name: location.title, latitude: location.geoLocation?.coordinate.latitude, longitude: location.geoLocation?.coordinate.longitude, radiusMeters: location.radius, proximity: proximity)
            }
            return .relative(seconds: alarm.relativeOffset)
        }
        return ReminderSnapshot(localIdentifier: reminder.calendarItemIdentifier, externalIdentifier: reminder.calendarItemExternalIdentifier, calendarIdentifier: reminder.calendar.calendarIdentifier, sourceIdentifier: reminder.calendar.source.sourceIdentifier, title: reminder.title, notes: reminder.notes, isCompleted: reminder.isCompleted, dueDate: dueDate, dueDateIsAllDay: reminder.dueDateComponents.map(isAllDay) ?? false, startDate: startDate, startDateIsAllDay: reminder.startDateComponents.map(isAllDay) ?? false, priority: ReminderPriority(rawValue: reminder.priority) ?? .none, alarms: alarms, location: reminder.location, url: reminder.url, timeZoneIdentifier: reminder.timeZone?.identifier ?? reminder.dueDateComponents?.timeZone?.identifier, recurrence: (reminder.recurrenceRules ?? []).map(recurrenceSnapshot), creationDate: reminder.creationDate, lastModifiedDate: reminder.lastModifiedDate, completionDate: reminder.completionDate)
    }

    private func dateComponents(_ date: Date, allDay: Bool, timeZone: TimeZone?) -> DateComponents {
        let zone = timeZone ?? TimeZone.current
        var components = Calendar.current.dateComponents(in: zone, from: date)
        if allDay { components.hour = nil; components.minute = nil; components.second = nil; components.nanosecond = nil }
        components.calendar = Calendar.current
        components.timeZone = allDay ? nil : zone
        return components
    }

    private func isAllDay(_ components: DateComponents) -> Bool { components.hour == nil && components.minute == nil && components.second == nil }

    private func locationAlarm(_ draft: ReminderLocationAlarmDraft) -> EKAlarm {
        let alarm = EKAlarm(relativeOffset: 0)
        let location = EKStructuredLocation(title: draft.name)
        location.geoLocation = CLLocation(latitude: draft.latitude, longitude: draft.longitude)
        location.radius = draft.radiusMeters
        alarm.structuredLocation = location
        alarm.proximity = draft.proximity == "leave" ? .leave : .enter
        return alarm
    }

    private func recurrenceRule(_ recurrence: ReminderRecurrence) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch recurrence.frequency { case .daily: frequency = .daily; case .weekly: frequency = .weekly; case .monthly: frequency = .monthly; case .yearly: frequency = .yearly }
        let end: EKRecurrenceEnd?
        switch recurrence.end { case .never: end = nil; case .date(let date): end = EKRecurrenceEnd(end: date); case .occurrences(let count): end = EKRecurrenceEnd(occurrenceCount: count) }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: recurrence.interval, end: end)
    }

    private func recurrenceSnapshot(_ rule: EKRecurrenceRule) -> ReminderRecurrence {
        let frequency: ReminderRecurrenceFrequency
        switch rule.frequency { case .daily: frequency = .daily; case .weekly: frequency = .weekly; case .monthly: frequency = .monthly; case .yearly: frequency = .yearly; @unknown default: frequency = .daily }
        let end: ReminderRecurrenceEnd
        if let recurrenceEnd = rule.recurrenceEnd, let date = recurrenceEnd.endDate { end = .date(date) }
        else if let recurrenceEnd = rule.recurrenceEnd, recurrenceEnd.occurrenceCount > 0 { end = .occurrences(recurrenceEnd.occurrenceCount) }
        else { end = .never }
        return ReminderRecurrence(frequency: frequency, interval: rule.interval, end: end)
    }

    private static func sourceType(_ type: EKSourceType) -> String {
        switch type { case .local: return "local"; case .exchange: return "exchange"; case .calDAV: return "caldav"; case .mobileMe: return "icloud"; case .subscribed: return "subscribed"; case .birthdays: return "birthdays"; @unknown default: return "unknown" }
    }
}
