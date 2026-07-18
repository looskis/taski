import Foundation

public struct TaskiConfiguration: Codable, Sendable {
    public struct Reminders: Codable, Sendable {
        public var sourceIdentifier: String
        public var sourceName: String
        public var calendarIdentifier: String
        public var calendarName: String
        public var pollIntervalSeconds: Int
        public var notificationDebounceMilliseconds: Int
        public init(sourceIdentifier: String, sourceName: String, calendarIdentifier: String, calendarName: String, pollIntervalSeconds: Int, notificationDebounceMilliseconds: Int) {
            self.sourceIdentifier = sourceIdentifier; self.sourceName = sourceName; self.calendarIdentifier = calendarIdentifier; self.calendarName = calendarName; self.pollIntervalSeconds = pollIntervalSeconds; self.notificationDebounceMilliseconds = notificationDebounceMilliseconds
        }
    }
    public struct Execution: Codable, Sendable {
        public var maxConcurrency: Int
        public var defaultTimeoutSeconds: Int
        public var maxAutomaticAttempts: Int
        public init(maxConcurrency: Int, defaultTimeoutSeconds: Int, maxAutomaticAttempts: Int) {
            self.maxConcurrency = maxConcurrency; self.defaultTimeoutSeconds = defaultTimeoutSeconds; self.maxAutomaticAttempts = maxAutomaticAttempts
        }
    }
    public var reminders: Reminders
    public var execution: Execution
    public init(reminders: Reminders, execution: Execution) { self.reminders = reminders; self.execution = execution }
}

public struct AppPaths: Sendable {
    public let root: URL
    public var configuration: URL { root.appendingPathComponent("config.json") }
    public var database: URL { root.appendingPathComponent("ledger.sqlite3") }
    public var reports: URL { root.appendingPathComponent("results", isDirectory: true) }

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Taski", isDirectory: true)
    }

    public func prepare() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    public func load() throws -> TaskiConfiguration {
        try JSONDecoder().decode(TaskiConfiguration.self, from: Data(contentsOf: configuration))
    }
    public func save(_ value: TaskiConfiguration) throws {
        try prepare()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: configuration, options: [.atomic])
    }
}
