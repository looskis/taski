import Foundation
import TaskiCore

enum TestFailure: Error { case failed(String) }

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure.failed(message) }
}

func expectRejection(_ title: String, _ code: String) throws {
    do {
        _ = try TaskParser().parse(title: title)
        throw TestFailure.failed("Expected \(title) to be rejected")
    } catch let rejection as TaskRejection {
        try expect(rejection.code == code, "Expected \(code), got \(rejection.code)")
    }
}

@main
struct BehavioralTests {
    static func main() async throws {
        let parser = TaskParser()
        try expect(try parser.parse(title: "run daily-report") == .run(workflow: "daily-report"), "run parsing")
        try expect(try parser.parse(title: "report system") == .report(name: "system"), "report parsing")
        try expect(try parser.parse(title: "message ops: deployment finished") == .message(recipient: "ops", body: "deployment finished"), "message parsing")
        try expectRejection("run daily-report; rm -rf /", "unsafe_characters")
        try expectRejection("message ops deployment finished", "unsupported_format")
        try expectRejection("do anything", "unsupported_task")
        try expectRejection(String(repeating: "x", count: 501), "title_too_long")
        print("PASS parser behavior")

        try await testLedgerBehavior()
        try await testReconciliationBehavior()
        print("PASS all behavioral tests")
    }

    static func testLedgerBehavior() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let ledger = try Ledger(path: path)
        let reminder = ReminderSnapshot(localIdentifier: "local-1", externalIdentifier: "external-1", calendarIdentifier: "cal", sourceIdentifier: "source", title: "run daily-report", notes: nil)
        let first = try ledger.discover(reminder)
        let second = try ledger.discover(ReminderSnapshot(localIdentifier: "local-2", externalIdentifier: "external-1", calendarIdentifier: "cal", sourceIdentifier: "source", title: "run daily-report", notes: nil))
        try expect(first.taskID == second.taskID, "external identifier should preserve task identity")
        try ledger.transition(taskID: first.taskID, to: .queued, summary: nil, error: nil)
        try ledger.transition(taskID: first.taskID, to: .running, summary: nil, error: nil)
        try ledger.transition(taskID: first.taskID, to: .succeeded, summary: "done", error: nil)
        try expect(try ledger.task(id: first.taskID)?.state == .succeeded, "task transition should persist")
        try expect(try ledger.audit(taskID: first.taskID).count == 4, "audit trail should include discovery and transitions")

        let approvalReminder = ReminderSnapshot(localIdentifier: "approval", externalIdentifier: "approval-ext", calendarIdentifier: "cal", sourceIdentifier: "source", title: "message ops: first", notes: nil)
        let approvalTask = try ledger.discover(approvalReminder)
        try ledger.transition(taskID: approvalTask.taskID, to: .awaitingApproval, processor: "message-draft", summary: nil, error: nil)
        _ = try ledger.discover(ReminderSnapshot(localIdentifier: "approval", externalIdentifier: "approval-ext", calendarIdentifier: "cal", sourceIdentifier: "source", title: "message ops: changed", notes: nil))
        try expect(try ledger.task(id: approvalTask.taskID)?.state == .discovered, "editing an unapproved task should reset classification")
        print("PASS ledger behavior")
    }

    static func testReconciliationBehavior() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let ledger = try Ledger(path: path)
        let store = FakeReminderStore(reminders: [
            ReminderSnapshot(localIdentifier: "one", externalIdentifier: "ext-one", calendarIdentifier: "cal", sourceIdentifier: "source", title: "run daily-report", notes: nil),
            ReminderSnapshot(localIdentifier: "two", externalIdentifier: "ext-two", calendarIdentifier: "cal", sourceIdentifier: "source", title: "do anything", notes: nil),
        ])
        let reconciler = Reconciler(store: store, ledger: ledger, registry: ProcessorRegistry.standard(reportDirectory: FileManager.default.temporaryDirectory))
        try await reconciler.reconcile(calendarIdentifier: "cal")
        try await reconciler.reconcile(calendarIdentifier: "cal")
        let tasks = try ledger.tasks()
        try expect(tasks.count == 2, "reconciliation must be idempotent")
        try expect(tasks.first(where: { $0.originalTitle == "run daily-report" })?.state == .succeeded, "supported task should succeed")
        try expect(tasks.first(where: { $0.originalTitle == "do anything" })?.state == .rejected, "unsupported task should reject")
        let completed = await store.completedIdentifiers
        try expect(completed == ["one"], "successful reminder should complete exactly once")
        print("PASS reconciliation behavior")
    }
}

actor FakeReminderStore: ReminderStore {
    let reminders: [ReminderSnapshot]
    var completedIdentifiers: [String] = []
    init(reminders: [ReminderSnapshot]) { self.reminders = reminders }
    func authorizationStatus() async -> ReminderAuthorization { .fullAccess }
    func fetchIncomplete(calendarIdentifier: String) async throws -> [ReminderSnapshot] { reminders.filter { !completedIdentifiers.contains($0.localIdentifier) } }
    func complete(localIdentifier: String) async throws { completedIdentifiers.append(localIdentifier) }
    func updateNote(localIdentifier: String, status: String) async throws {}
}
