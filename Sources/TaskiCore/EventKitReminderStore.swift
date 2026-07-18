import EventKit
import Foundation

public struct ReminderListDescriptor: Sendable {
    public let sourceIdentifier: String
    public let sourceName: String
    public let calendarIdentifier: String
    public let calendarName: String
    public let sourceType: String
}

public final class EventKitReminderStore: ReminderStore, @unchecked Sendable {
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
        guard let calendar = eventStore.calendar(withIdentifier: calendarIdentifier) else {
            throw ProcessorError(code: "calendar_missing", message: "The configured Reminders list no longer exists. Run `taski setup`.")
        }
        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [calendar])
        return try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let snapshots = (reminders ?? []).map { reminder in
                    ReminderSnapshot(localIdentifier: reminder.calendarItemIdentifier, externalIdentifier: reminder.calendarItemExternalIdentifier, calendarIdentifier: calendar.calendarIdentifier, sourceIdentifier: calendar.source.sourceIdentifier, title: reminder.title, notes: reminder.notes)
                }
                continuation.resume(returning: snapshots)
            }
        }
    }

    public func complete(localIdentifier: String) async throws {
        guard let reminder = eventStore.calendarItem(withIdentifier: localIdentifier) as? EKReminder else {
            throw ProcessorError(code: "reminder_missing", message: "The source reminder no longer exists.")
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

    private static func sourceType(_ type: EKSourceType) -> String {
        switch type { case .local: return "local"; case .exchange: return "exchange"; case .calDAV: return "caldav"; case .mobileMe: return "icloud"; case .subscribed: return "subscribed"; case .birthdays: return "birthdays"; @unknown default: return "unknown" }
    }
}
