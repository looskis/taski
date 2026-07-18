import Foundation

public enum TaskState: String, Codable, CaseIterable, Sendable {
    case discovered, rejected, awaitingApproval = "awaiting_approval", queued, running, succeeded, failed, cancelled, superseded
}

public struct ReminderSnapshot: Equatable, Sendable {
    public let localIdentifier: String
    public let externalIdentifier: String?
    public let calendarIdentifier: String
    public let sourceIdentifier: String
    public let title: String
    public let notes: String?
    public let isCompleted: Bool
    public let dueDate: Date?
    public let dueDateIsAllDay: Bool
    public let startDate: Date?
    public let startDateIsAllDay: Bool
    public let priority: ReminderPriority
    public let alarms: [ReminderAlarm]
    public let location: String?
    public let url: URL?
    public let timeZoneIdentifier: String?
    public let recurrence: [ReminderRecurrence]
    public let creationDate: Date?
    public let lastModifiedDate: Date?
    public let completionDate: Date?

    public init(localIdentifier: String, externalIdentifier: String?, calendarIdentifier: String, sourceIdentifier: String, title: String, notes: String?, isCompleted: Bool = false, dueDate: Date? = nil, dueDateIsAllDay: Bool = false, startDate: Date? = nil, startDateIsAllDay: Bool = false, priority: ReminderPriority = .none, alarms: [ReminderAlarm] = [], location: String? = nil, url: URL? = nil, timeZoneIdentifier: String? = nil, recurrence: [ReminderRecurrence] = [], creationDate: Date? = nil, lastModifiedDate: Date? = nil, completionDate: Date? = nil) {
        self.localIdentifier = localIdentifier
        self.externalIdentifier = externalIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.sourceIdentifier = sourceIdentifier
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.dueDateIsAllDay = dueDateIsAllDay
        self.startDate = startDate
        self.startDateIsAllDay = startDateIsAllDay
        self.priority = priority
        self.alarms = alarms
        self.location = location
        self.url = url
        self.timeZoneIdentifier = timeZoneIdentifier
        self.recurrence = recurrence
        self.creationDate = creationDate
        self.lastModifiedDate = lastModifiedDate
        self.completionDate = completionDate
    }

    public var fingerprint: String {
        let userNotes = (notes ?? "").split(separator: "\n").filter { !$0.hasPrefix("Taski: ") }.joined(separator: "\n")
        let normalized = [title, userNotes].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.joined(separator: "\u{1f}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in normalized.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(format: "%016llx", hash)
    }

}

public enum ReminderPriority: Int, CaseIterable, Sendable {
    case none = 0
    case high = 1
    case medium = 5
    case low = 9
}

public enum ReminderAlarm: Equatable, Sendable {
    case absolute(Date)
    case relative(seconds: TimeInterval)
    case location(name: String?, latitude: Double?, longitude: Double?, radiusMeters: Double, proximity: String)
}

public enum ReminderRecurrenceFrequency: String, Sendable { case daily, weekly, monthly, yearly }
public enum ReminderRecurrenceEnd: Equatable, Sendable { case never, date(Date), occurrences(Int) }
public struct ReminderRecurrence: Equatable, Sendable {
    public let frequency: ReminderRecurrenceFrequency
    public let interval: Int
    public let end: ReminderRecurrenceEnd
    public init(frequency: ReminderRecurrenceFrequency, interval: Int = 1, end: ReminderRecurrenceEnd = .never) { self.frequency = frequency; self.interval = interval; self.end = end }
}

public struct ReminderLocationAlarmDraft: Equatable, Sendable {
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let radiusMeters: Double
    public let proximity: String
    public init(name: String, latitude: Double, longitude: Double, radiusMeters: Double, proximity: String) { self.name = name; self.latitude = latitude; self.longitude = longitude; self.radiusMeters = radiusMeters; self.proximity = proximity }
}

public enum ReminderFieldUpdate<Value: Sendable>: Sendable {
    case unchanged
    case set(Value)
    case clear

    public func applying(to current: Value?) -> Value? {
        switch self { case .unchanged: return current; case .set(let value): return value; case .clear: return nil }
    }
}

public struct ReminderDraft: Sendable {
    public let title: String
    public let notes: String?
    public let dueDate: Date?
    public let dueDateIsAllDay: Bool
    public let startDate: Date?
    public let startDateIsAllDay: Bool
    public let priority: ReminderPriority
    public let alarms: [Date]
    public let relativeAlarms: [TimeInterval]
    public let locationAlarms: [ReminderLocationAlarmDraft]
    public let location: String?
    public let url: URL?
    public let timeZoneIdentifier: String?
    public let recurrence: [ReminderRecurrence]
    public init(title: String, notes: String? = nil, dueDate: Date? = nil, dueDateIsAllDay: Bool = false, startDate: Date? = nil, startDateIsAllDay: Bool = false, priority: ReminderPriority = .none, alarms: [Date] = [], relativeAlarms: [TimeInterval] = [], locationAlarms: [ReminderLocationAlarmDraft] = [], location: String? = nil, url: URL? = nil, timeZoneIdentifier: String? = nil, recurrence: [ReminderRecurrence] = []) {
        self.title = title; self.notes = notes; self.dueDate = dueDate; self.dueDateIsAllDay = dueDateIsAllDay; self.startDate = startDate; self.startDateIsAllDay = startDateIsAllDay; self.priority = priority; self.alarms = alarms; self.relativeAlarms = relativeAlarms; self.locationAlarms = locationAlarms; self.location = location; self.url = url; self.timeZoneIdentifier = timeZoneIdentifier; self.recurrence = recurrence
    }
}

public struct ReminderPatch: Sendable {
    public let title: String?
    public let notes: ReminderFieldUpdate<String>
    public let dueDate: ReminderFieldUpdate<Date>
    public let dueDateIsAllDay: Bool?
    public let startDate: ReminderFieldUpdate<Date>
    public let startDateIsAllDay: Bool?
    public let priority: ReminderPriority?
    public let addAlarms: [Date]
    public let clearAlarms: Bool
    public let addRelativeAlarms: [TimeInterval]
    public let addLocationAlarms: [ReminderLocationAlarmDraft]
    public let location: ReminderFieldUpdate<String>
    public let url: ReminderFieldUpdate<URL>
    public let timeZoneIdentifier: ReminderFieldUpdate<String>
    public let recurrence: [ReminderRecurrence]?
    public let clearRecurrence: Bool
    public init(title: String? = nil, notes: ReminderFieldUpdate<String> = .unchanged, dueDate: ReminderFieldUpdate<Date> = .unchanged, dueDateIsAllDay: Bool? = nil, startDate: ReminderFieldUpdate<Date> = .unchanged, startDateIsAllDay: Bool? = nil, priority: ReminderPriority? = nil, addAlarms: [Date] = [], clearAlarms: Bool = false, addRelativeAlarms: [TimeInterval] = [], addLocationAlarms: [ReminderLocationAlarmDraft] = [], location: ReminderFieldUpdate<String> = .unchanged, url: ReminderFieldUpdate<URL> = .unchanged, timeZoneIdentifier: ReminderFieldUpdate<String> = .unchanged, recurrence: [ReminderRecurrence]? = nil, clearRecurrence: Bool = false) {
        self.title = title; self.notes = notes; self.dueDate = dueDate; self.dueDateIsAllDay = dueDateIsAllDay; self.startDate = startDate; self.startDateIsAllDay = startDateIsAllDay; self.priority = priority; self.addAlarms = addAlarms; self.clearAlarms = clearAlarms; self.addRelativeAlarms = addRelativeAlarms; self.addLocationAlarms = addLocationAlarms; self.location = location; self.url = url; self.timeZoneIdentifier = timeZoneIdentifier; self.recurrence = recurrence; self.clearRecurrence = clearRecurrence
    }
}

public struct TaskRecord: Sendable {
    public let taskID: String
    public let localIdentifier: String
    public let externalIdentifier: String?
    public let calendarIdentifier: String
    public let sourceIdentifier: String
    public let fingerprint: String
    public let originalTitle: String
    public let originalNotes: String?
    public let state: TaskState
    public let processorName: String?
    public let attemptCount: Int
    public let approvedAt: Date?
    public let resultSummary: String?
    public let errorCode: String?
    public let errorMessage: String?
}

public struct AuditEntry: Sendable {
    public let taskID: String
    public let fromState: TaskState?
    public let toState: TaskState
    public let occurredAt: Date
    public let detail: String?
}

public enum ReminderAuthorization: String, Sendable { case notDetermined, restricted, denied, fullAccess, unknown }

public protocol ReminderStore: Sendable {
    func authorizationStatus() async -> ReminderAuthorization
    func fetchIncomplete(calendarIdentifier: String) async throws -> [ReminderSnapshot]
    func complete(localIdentifier: String, expectedFingerprint: String) async throws
    func updateNote(localIdentifier: String, status: String) async throws
}

public protocol ReminderCRUDStore: Sendable {
    func authorizationStatus() async -> ReminderAuthorization
    func fetchAll(calendarIdentifier: String) async throws -> [ReminderSnapshot]
    func create(calendarIdentifier: String, sourceIdentifier: String, draft: ReminderDraft) async throws -> ReminderSnapshot
    func update(localIdentifier: String, calendarIdentifier: String, patch: ReminderPatch) async throws -> ReminderSnapshot
    func setCompleted(localIdentifier: String, calendarIdentifier: String, completed: Bool) async throws -> ReminderSnapshot
    func delete(localIdentifier: String, calendarIdentifier: String) async throws
}

public struct TaskResult: Sendable {
    public let summary: String
    public init(summary: String) { self.summary = summary }
}

public struct ProcessorError: Error, Sendable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}

public protocol TaskProcessor: Sendable {
    var name: String { get }
    func validate(_ task: ParsedTask) throws
    func execute(_ task: ParsedTask, taskID: String) async throws -> TaskResult
}
