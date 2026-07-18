import Foundation

public actor Reconciler {
    private let store: any ReminderStore
    private let ledger: Ledger
    private let registry: ProcessorRegistry
    private let parser: TaskParser
    private let timeoutSeconds: Double

    public init(store: any ReminderStore, ledger: Ledger, registry: ProcessorRegistry, parser: TaskParser = TaskParser(), timeoutSeconds: Double = 120) {
        self.store = store
        self.ledger = ledger
        self.registry = registry
        self.parser = parser
        self.timeoutSeconds = timeoutSeconds
    }

    public func reconcile(calendarIdentifier: String) async throws {
        guard await store.authorizationStatus() == .fullAccess else {
            throw ProcessorError(code: "reminders_authorization", message: "Full Reminders access is required. Run `taski setup` interactively.")
        }
        let reminders = try await store.fetchIncomplete(calendarIdentifier: calendarIdentifier)
        for reminder in reminders {
            let record = try ledger.discover(reminder)
            switch record.state {
            case .succeeded:
                try await complete(reminder, taskID: record.taskID)
            case .discovered:
                try await classifyAndRun(reminder, record: record)
            case .queued:
                try await run(reminder, record: record)
            case .running:
                try ledger.transition(taskID: record.taskID, to: .failed, summary: nil, error: ProcessorError(code: "interrupted", message: "The daemon stopped while this task was running; inspect before retrying."))
            default:
                continue
            }
        }
    }

    private func classifyAndRun(_ reminder: ReminderSnapshot, record: TaskRecord) async throws {
        do {
            let parsed = try parser.parse(title: reminder.title)
            guard registry[parsed.processorName] != nil else {
                let error = ProcessorError(code: "unknown_processor", message: "Processor \(parsed.processorName) is not enabled.")
                try ledger.transition(taskID: record.taskID, to: .rejected, processor: parsed.processorName, summary: nil, error: error)
                try? await store.updateNote(localIdentifier: reminder.localIdentifier, status: "Rejected: unsupported processor")
                return
            }
            if parsed.requiresApproval {
                try ledger.transition(taskID: record.taskID, to: .awaitingApproval, processor: parsed.processorName, summary: nil, error: nil)
                try? await store.updateNote(localIdentifier: reminder.localIdentifier, status: "Awaiting explicit approval")
                return
            }
            try ledger.transition(taskID: record.taskID, to: .queued, processor: parsed.processorName, summary: nil, error: nil)
            try await run(reminder, record: try ledger.task(id: record.taskID)!)
        } catch let rejection as TaskRejection {
            let error = ProcessorError(code: rejection.code, message: rejection.explanation)
            try ledger.transition(taskID: record.taskID, to: .rejected, summary: nil, error: error)
            try? await store.updateNote(localIdentifier: reminder.localIdentifier, status: "Rejected: \(rejection.explanation)")
        }
    }

    private func run(_ reminder: ReminderSnapshot, record: TaskRecord) async throws {
        let parsed: ParsedTask
        do { parsed = try parser.parse(title: reminder.title) }
        catch let rejection as TaskRejection {
            try ledger.transition(taskID: record.taskID, to: .rejected, summary: nil, error: ProcessorError(code: rejection.code, message: rejection.explanation)); return
        }
        guard let processor = registry[parsed.processorName] else { return }
        do {
            try processor.validate(parsed)
            try ledger.transition(taskID: record.taskID, to: .running, processor: processor.name, summary: nil, error: nil)
            let result = try await withThrowingTaskGroup(of: TaskResult.self) { group in
                group.addTask { try await processor.execute(parsed, taskID: record.taskID) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds * 1_000_000_000))
                    throw ProcessorError(code: "timeout", message: "Processor exceeded its time limit; its external outcome may be unknown.")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            try ledger.transition(taskID: record.taskID, to: .succeeded, summary: result.summary, error: nil)
            try await complete(reminder, taskID: record.taskID)
        } catch let error as ProcessorError {
            try ledger.transition(taskID: record.taskID, to: .failed, summary: nil, error: error)
            try? await store.updateNote(localIdentifier: reminder.localIdentifier, status: "Failed: \(error.code)")
        } catch {
            let safe = ProcessorError(code: "processor_failure", message: "Processor failed; inspect local diagnostics.")
            try ledger.transition(taskID: record.taskID, to: .failed, summary: nil, error: safe)
            try? await store.updateNote(localIdentifier: reminder.localIdentifier, status: "Failed: processor error")
        }
    }

    private func complete(_ reminder: ReminderSnapshot, taskID: String) async throws {
        do { try await store.complete(localIdentifier: reminder.localIdentifier) }
        catch { throw ProcessorError(code: "completion_failure", message: "Task succeeded, but its reminder could not be completed; reconciliation will retry.") }
    }
}
