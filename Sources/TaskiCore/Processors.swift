import Foundation

public struct ProcessorRegistry: Sendable {
    private let processors: [String: any TaskProcessor]

    public init(_ processors: [any TaskProcessor]) {
        self.processors = Dictionary(uniqueKeysWithValues: processors.map { ($0.name, $0) })
    }

    public subscript(name: String) -> (any TaskProcessor)? { processors[name] }

    public static func standard(reportDirectory: URL) -> ProcessorRegistry {
        ProcessorRegistry([
            DailyReportProcessor(),
            SystemReportProcessor(),
            MessageDraftProcessor(directory: reportDirectory),
        ])
    }
}

public struct DailyReportProcessor: TaskProcessor {
    public let name = "daily-report"
    public init() {}
    public func validate(_ task: ParsedTask) throws {
        guard task == .run(workflow: name) else { throw ProcessorError(code: "invalid_parameters", message: "daily-report accepts no parameters.") }
    }
    public func execute(_ task: ParsedTask, taskID: String) async throws -> TaskResult {
        let formatter = ISO8601DateFormatter()
        return TaskResult(summary: "Daily report completed at \(formatter.string(from: Date())).")
    }
}

public struct SystemReportProcessor: TaskProcessor {
    public let name = "report"
    public init() {}
    public func validate(_ task: ParsedTask) throws {
        guard task == .report(name: "system") else { throw ProcessorError(code: "unknown_report", message: "Only the system report is enabled.") }
    }
    public func execute(_ task: ParsedTask, taskID: String) async throws -> TaskResult {
        let process = ProcessInfo.processInfo
        return TaskResult(summary: "System report: \(process.operatingSystemVersionString); uptime \(Int(process.systemUptime)) seconds.")
    }
}

public struct MessageDraftProcessor: TaskProcessor {
    public let name = "message-draft"
    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func validate(_ task: ParsedTask) throws {
        guard case .message(let recipient, let body) = task, recipient.count <= 80, body.count <= 300 else {
            throw ProcessorError(code: "invalid_message", message: "Message parameters are invalid.")
        }
    }
    public func execute(_ task: ParsedTask, taskID: String) async throws -> TaskResult {
        guard case .message(let recipient, let body) = task else { throw ProcessorError(code: "invalid_message", message: "Message parameters are invalid.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("message-\(taskID).txt")
        try "To: \(recipient)\n\n\(body)\n".write(to: destination, atomically: true, encoding: .utf8)
        return TaskResult(summary: "Approved message draft created for \(recipient).")
    }
}
