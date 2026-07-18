import Foundation
import Darwin

public actor Reconciler {
    private let store: any ReminderStore
    private let ledger: Ledger
    private let registry: ProcessorRegistry
    private let parser: TaskParser
    private let timeoutSeconds: Double
    private let lockPath: String?
    private var reconciliationInProgress = false
    private var didRecoverInterruptedTasks = false

    public init(store: any ReminderStore, ledger: Ledger, registry: ProcessorRegistry, parser: TaskParser = TaskParser(), timeoutSeconds: Double = 120, lockPath: String? = nil) {
        self.store = store
        self.ledger = ledger
        self.registry = registry
        self.parser = parser
        self.timeoutSeconds = timeoutSeconds
        self.lockPath = lockPath
    }

    public func reconcile(calendarIdentifier: String) async throws {
        guard !reconciliationInProgress else { return }
        reconciliationInProgress = true
        defer { reconciliationInProgress = false }
        let processLock = try ProcessLock(path: lockPath)
        defer { processLock.unlock() }
        guard await store.authorizationStatus() == .fullAccess else {
            throw ProcessorError(code: "reminders_authorization", message: "Full Reminders access is required. Run `taski setup` interactively.")
        }
        let reminders = try await store.fetchIncomplete(calendarIdentifier: calendarIdentifier)
        try ledger.recordMetric("last_successful_eventkit_fetch")
        let currentLocalIdentifiers = Set(reminders.map(\.localIdentifier))
        if !didRecoverInterruptedTasks {
            for interrupted in try ledger.tasks().filter({ $0.state == .running }) {
                try ledger.transition(taskID: interrupted.taskID, to: .failed, summary: nil, error: ProcessorError(code: "interrupted", message: "The daemon stopped while this task was running; inspect its external outcome before retrying."))
            }
            didRecoverInterruptedTasks = true
        }
        for reminder in reminders {
            let record = try ledger.discover(reminder, currentLocalIdentifiers: currentLocalIdentifiers)
            try ledger.recordMetric("last_icloud_visible_reminder_discovery")
            switch record.state {
            case .succeeded:
                do { try await complete(reminder, taskID: record.taskID) }
                catch { try? await store.updateNote(localIdentifier: reminder.localIdentifier, status: "Succeeded; completion pending") }
            case .discovered:
                try await classifyAndRun(reminder, record: record)
            case .queued:
                try await run(reminder, record: record)
            case .running:
                continue
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
            let result = try await raceWithTimeout(seconds: timeoutSeconds) { try await processor.execute(parsed, taskID: record.taskID) }
            try ledger.transition(taskID: record.taskID, to: .succeeded, summary: result.summary, error: nil)
            do { try await complete(reminder, taskID: record.taskID) }
            catch {
                try? await store.updateNote(localIdentifier: reminder.localIdentifier, status: "Succeeded; completion pending")
                return
            }
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
        guard let task = try ledger.task(id: taskID) else { return }
        do { try await store.complete(localIdentifier: reminder.localIdentifier, expectedFingerprint: task.fingerprint) }
        catch { throw ProcessorError(code: "completion_failure", message: "Task succeeded, but its reminder could not be completed; reconciliation will retry.") }
    }
}

final class ProcessLock: @unchecked Sendable {
    private var descriptor: Int32 = -1
    init(path: String?) throws {
        guard let path else { return }
        descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            throw ProcessorError(code: "reconcile_busy", message: "Another Taski process is reconciling this inbox.")
        }
    }
    func unlock() { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { unlock() }
}

private final class TimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private let continuation: CheckedContinuation<TaskResult, Error>
    init(_ continuation: CheckedContinuation<TaskResult, Error>) { self.continuation = continuation }
    func resolve(_ result: Result<TaskResult, Error>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !resolved else { return false }; resolved = true; continuation.resume(with: result); return true
    }
}

private func raceWithTimeout(seconds: Double, operation: @escaping @Sendable () async throws -> TaskResult) async throws -> TaskResult {
    try await withCheckedThrowingContinuation { continuation in
        let race = TimeoutRace(continuation)
        let work = Task { do { _ = race.resolve(.success(try await operation())) } catch { _ = race.resolve(.failure(error)) } }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if race.resolve(.failure(ProcessorError(code: "timeout", message: "Processor exceeded its time limit; its external outcome may be unknown."))) { work.cancel() }
        }
    }
}
