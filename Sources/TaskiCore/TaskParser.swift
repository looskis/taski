import Foundation

public enum ParsedTask: Equatable, Codable, Sendable {
    case run(workflow: String)
    case report(name: String)
    case message(recipient: String, body: String)

    public var processorName: String {
        switch self {
        case .run(let workflow): return workflow
        case .report: return "report"
        case .message: return "message-draft"
        }
    }

    public var requiresApproval: Bool {
        if case .message = self { return true }
        return false
    }
}

public struct TaskRejection: Error, Equatable, Sendable {
    public let code: String
    public let explanation: String

    public init(code: String, explanation: String) {
        self.code = code
        self.explanation = explanation
    }
}

public struct TaskParser: Sendable {
    public init() {}

    public func parse(title rawTitle: String) throws -> ParsedTask {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count <= 500 else {
            throw TaskRejection(code: "title_too_long", explanation: "Task titles must be 500 characters or fewer.")
        }
        guard !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !title.contains(";"), !title.contains("&&"), !title.contains("||"),
              !title.contains("`"), !title.contains("$(") else {
            throw TaskRejection(code: "unsafe_characters", explanation: "Shell syntax and control characters are not allowed.")
        }

        if title.hasPrefix("run ") {
            let workflow = String(title.dropFirst(4))
            guard isIdentifier(workflow) else { throw unsupportedFormat() }
            return .run(workflow: workflow)
        }
        if title.hasPrefix("report ") {
            let name = String(title.dropFirst(7))
            guard isIdentifier(name) else { throw unsupportedFormat() }
            return .report(name: name)
        }
        if title.hasPrefix("message ") {
            let payload = title.dropFirst(8)
            guard let colon = payload.firstIndex(of: ":") else { throw unsupportedFormat() }
            let recipient = payload[..<colon].trimmingCharacters(in: .whitespaces)
            let body = payload[payload.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard isIdentifier(recipient), !body.isEmpty, body.count <= 300 else { throw unsupportedFormat() }
            return .message(recipient: recipient, body: body)
        }
        throw TaskRejection(
            code: "unsupported_task",
            explanation: "Use: run <workflow>, report <name>, or message <recipient>: <body>."
        )
    }

    private func isIdentifier<S: StringProtocol>(_ value: S) -> Bool {
        guard !value.isEmpty, value.count <= 80 else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private func unsupportedFormat() -> TaskRejection {
        TaskRejection(code: "unsupported_format", explanation: "The task does not match the required command format.")
    }
}
