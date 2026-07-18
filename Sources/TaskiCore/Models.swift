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
    public let priority: ReminderPriority
    public let alarms: [ReminderAlarm]

    public init(localIdentifier: String, externalIdentifier: String?, calendarIdentifier: String, sourceIdentifier: String, title: String, notes: String?, isCompleted: Bool = false, dueDate: Date? = nil, priority: ReminderPriority = .none, alarms: [ReminderAlarm] = []) {
        self.localIdentifier = localIdentifier
        self.externalIdentifier = externalIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.sourceIdentifier = sourceIdentifier
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.priority = priority
        self.alarms = alarms
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
    public let priority: ReminderPriority
    public let alarms: [Date]
    public init(title: String, notes: String? = nil, dueDate: Date? = nil, priority: ReminderPriority = .none, alarms: [Date] = []) {
        self.title = title; self.notes = notes; self.dueDate = dueDate; self.priority = priority; self.alarms = alarms
    }
}

public struct ReminderPatch: Sendable {
    public let title: String?
    public let notes: ReminderFieldUpdate<String>
    public let dueDate: ReminderFieldUpdate<Date>
    public let priority: ReminderPriority?
    public let addAlarms: [Date]
    public let clearAlarms: Bool
    public init(title: String? = nil, notes: ReminderFieldUpdate<String> = .unchanged, dueDate: ReminderFieldUpdate<Date> = .unchanged, priority: ReminderPriority? = nil, addAlarms: [Date] = [], clearAlarms: Bool = false) {
        self.title = title; self.notes = notes; self.dueDate = dueDate; self.priority = priority; self.addAlarms = addAlarms; self.clearAlarms = clearAlarms
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
