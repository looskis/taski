import Foundation

public enum TaskState: String, Codable, CaseIterable, Sendable {
    case discovered, rejected, awaitingApproval = "awaiting_approval", queued, running, succeeded, failed, cancelled
}

public struct ReminderSnapshot: Equatable, Sendable {
    public let localIdentifier: String
    public let externalIdentifier: String?
    public let calendarIdentifier: String
    public let sourceIdentifier: String
    public let title: String
    public let notes: String?

    public init(localIdentifier: String, externalIdentifier: String?, calendarIdentifier: String, sourceIdentifier: String, title: String, notes: String?) {
        self.localIdentifier = localIdentifier
        self.externalIdentifier = externalIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.sourceIdentifier = sourceIdentifier
        self.title = title
        self.notes = notes
    }

    public var fingerprint: String {
        let userNotes = (notes ?? "").split(separator: "\n").filter { !$0.hasPrefix("Taski: ") }.joined(separator: "\n")
        let normalized = [title, userNotes].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.joined(separator: "\u{1f}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in normalized.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(format: "%016llx", hash)
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
