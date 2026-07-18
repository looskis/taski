import Foundation
import TaskiCore

@main
struct TaskiCLI {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch let error as ProcessorError { fputs("taski: \(error.code): \(error.message)\n", stderr); exit(1) }
        catch { fputs("taski: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func run(_ arguments: [String]) async throws {
        let command = arguments.first ?? "help"
        let paths = AppPaths()
        switch command {
        case "reminder": try await reminderCommand(paths: paths, arguments: Array(arguments.dropFirst()))
        case "setup": try await setup(paths: paths, arguments: Array(arguments.dropFirst()))
        case "probe": try await probe(request: arguments.contains("--request-access"))
        case "run-once": try await runOnce(paths: paths)
        case "daemon": try await daemon(paths: paths)
        case "status": try await status(paths: paths)
        case "tasks": try listTasks(paths: paths)
        case "inspect": try inspect(paths: paths, id: requiredID(arguments))
        case "approve": try await approve(paths: paths, id: requiredID(arguments))
        case "retry": try await retry(paths: paths, id: requiredID(arguments))
        case "cancel": try cancel(paths: paths, id: requiredID(arguments))
        case "help", "--help", "-h": help()
        default: throw ProcessorError(code: "unknown_command", message: "Unknown command `\(command)`. Run `taski help`.")
        }
    }

    static func setup(paths: AppPaths, arguments: [String]) async throws {
        let store = EventKitReminderStore()
        let status = await store.authorizationStatus()
        if status == .notDetermined {
            print("macOS will ask for full Reminders access for Taski.")
            guard try await store.requestAccess() else { throw ProcessorError(code: "access_denied", message: "Reminders access was not granted. Enable it in System Settings > Privacy & Security > Reminders.") }
        } else if status != .fullAccess {
            throw ProcessorError(code: "access_\(status.rawValue)", message: "Enable Taski in System Settings > Privacy & Security > Reminders, then run setup again.")
        }
        let lists = store.lists()
        guard !lists.isEmpty else { throw ProcessorError(code: "no_lists", message: "No reminder lists are available.") }
        for (index, list) in lists.enumerated() { print("[\(index + 1)] \(list.sourceName) / \(list.calendarName) (\(list.sourceType))") }
        let selected: ReminderListDescriptor
        if let requested = option("--list", in: arguments), let match = lists.first(where: { $0.calendarName == requested }) { selected = match }
        else {
            print("Select the dedicated inbox list [1-\(lists.count)]: ", terminator: "")
            guard let input = readLine(), let index = Int(input), lists.indices.contains(index - 1) else { throw ProcessorError(code: "invalid_selection", message: "No valid list was selected.") }
            selected = lists[index - 1]
        }
        print("Shared lists are unsupported. Confirm this is a private list you own [y/N]: ", terminator: "")
        guard ["y", "yes"].contains((readLine() ?? "").lowercased()) else {
            throw ProcessorError(code: "private_list_unconfirmed", message: "Select and confirm a private reminder list.")
        }
        let config = TaskiConfiguration(
            reminders: .init(sourceIdentifier: selected.sourceIdentifier, sourceName: selected.sourceName, calendarIdentifier: selected.calendarIdentifier, calendarName: selected.calendarName, pollIntervalSeconds: 60, notificationDebounceMilliseconds: 750),
            execution: .init(maxConcurrency: 2, defaultTimeoutSeconds: 120, maxAutomaticAttempts: 3)
        )
        try paths.save(config)
        _ = try Ledger(path: paths.database.path)
        print("Configured \(selected.sourceName) / \(selected.calendarName). Configuration: \(paths.configuration.path)")
    }

    static func probe(request: Bool) async throws {
        let store = EventKitReminderStore()
        let initialStatus = await store.authorizationStatus()
        if request && initialStatus == .notDetermined { _ = try await store.requestAccess() }
        let status = await store.authorizationStatus()
        print("Reminders authorization: \(status.rawValue)")
        guard status == .fullAccess else { throw ProcessorError(code: "access_\(status.rawValue)", message: "Run `taski probe --request-access` interactively or grant access in System Settings.") }
        for list in store.lists() {
            let reminders = try await store.fetchIncomplete(calendarIdentifier: list.calendarIdentifier)
            print("\(list.sourceName) / \(list.calendarName): id=\(list.calendarIdentifier), incomplete=\(reminders.count)")
            for reminder in reminders { print("  item=\(reminder.localIdentifier) external=\(reminder.externalIdentifier ?? "none") title_length=\(reminder.title.count)") }
        }
        print("Watching for EventKit changes; press Control-C to stop.")
        for await _ in store.changes() { print("EventKit changed at \(ISO8601DateFormatter().string(from: Date())); refetching is required.") }
    }

    static func makeRuntime(paths: AppPaths) throws -> (TaskiConfiguration, EventKitReminderStore, Ledger, Reconciler) {
        let config = try paths.load()
        let store = EventKitReminderStore()
        let ledger = try Ledger(path: paths.database.path)
        let registry = ProcessorRegistry.standard(reportDirectory: paths.reports)
        return (config, store, ledger, Reconciler(store: store, ledger: ledger, registry: registry, timeoutSeconds: Double(config.execution.defaultTimeoutSeconds), lockPath: paths.root.appendingPathComponent("reconcile.lock").path))
    }

    static func reminderCommand(paths: AppPaths, arguments: [String]) async throws {
        guard let command = arguments.first else { throw ProcessorError(code: "missing_reminder_command", message: "Use `taski reminder help`.") }
        if ["help", "--help", "-h"].contains(command) { reminderHelp(); return }
        guard ["create", "list", "show", "edit", "complete", "reopen", "delete"].contains(command) else { throw ProcessorError(code: "unknown_reminder_command", message: "Unknown reminder command `\(command)`. Use `taski reminder help`.") }
        let config = try paths.load()
        let store = EventKitReminderStore()
        let ledger = try Ledger(path: paths.database.path)
        let manager = ReminderManager(store: store, ledger: ledger, calendarIdentifier: config.reminders.calendarIdentifier, sourceIdentifier: config.reminders.sourceIdentifier, lockPath: paths.root.appendingPathComponent("reconcile.lock").path)
        let remainder = Array(arguments.dropFirst())
        switch command {
        case "create":
            let options = try CLIOptions(remainder, values: ["--title", "--notes", "--due", "--due-date", "--start", "--timezone", "--priority", "--alarm", "--alarm-relative", "--alarm-location", "--url", "--repeat", "--repeat-interval", "--repeat-count", "--repeat-until"], flags: [])
            let title = try options.required("--title")
            try options.requireExclusive("--due", "--due-date")
            let zone = try options.single("--timezone")
            let dueDate = try options.single("--due").map(parseDate) ?? options.single("--due-date").map { try parseAllDay($0, timeZoneIdentifier: zone) }
            let startDate = try options.single("--start").map(parseDate)
            let draft = ReminderDraft(title: title, notes: try options.single("--notes"), dueDate: dueDate, dueDateIsAllDay: options.contains("--due-date"), startDate: startDate, priority: try options.single("--priority").map(parsePriority) ?? .none, alarms: try options.all("--alarm").map(parseDate), relativeAlarms: try options.all("--alarm-relative").map(parseOffset), locationAlarms: try options.all("--alarm-location").map(parseLocationAlarm), url: try options.single("--url").map(parseURL), timeZoneIdentifier: zone, recurrence: try parseRecurrence(options).map { [$0] } ?? [])
            printReminder(try await manager.create(draft))
        case "list":
            let options = try CLIOptions(remainder, values: [], flags: ["--all"])
            let reminders = try await manager.list(includeCompleted: options.has("--all"))
            if reminders.isEmpty { print("No reminders in the configured inbox.") }
            for reminder in reminders { print("\(reminder.localIdentifier)  \(reminder.isCompleted ? "completed" : "incomplete")  \(safeText(reminder.title))") }
        case "show":
            guard remainder.count == 1 else { throw usage("show requires one reminder or task ID") }
            printReminder(try await manager.show(identifier: remainder[0]))
        case "edit":
            guard let identifier = remainder.first, !identifier.hasPrefix("--") else { throw usage("edit requires a reminder or task ID") }
            let options = try CLIOptions(Array(remainder.dropFirst()), values: ["--title", "--notes", "--due", "--due-date", "--start", "--timezone", "--priority", "--alarm", "--alarm-relative", "--alarm-location", "--url", "--repeat", "--repeat-interval", "--repeat-count", "--repeat-until"], flags: ["--clear-notes", "--clear-due", "--clear-start", "--clear-alarms", "--clear-url", "--clear-timezone", "--clear-repeat"])
            guard options.hasMutation else { throw usage("edit requires at least one field option") }
            if options.has("--clear-notes") && options.contains("--notes") { throw usage("use either --notes or --clear-notes") }
            if options.has("--clear-due") && (options.contains("--due") || options.contains("--due-date")) { throw usage("use either a due value or --clear-due") }
            if options.has("--clear-start") && options.contains("--start") { throw usage("use either --start or --clear-start") }
            try options.requireExclusive("--due", "--due-date")
            let notes: ReminderFieldUpdate<String> = options.has("--clear-notes") ? .clear : try options.single("--notes").map(ReminderFieldUpdate.set) ?? .unchanged
            let zone = try options.single("--timezone")
            let dueValue = try options.single("--due").map(parseDate) ?? options.single("--due-date").map { try parseAllDay($0, timeZoneIdentifier: zone) }
            let startValue = try options.single("--start").map(parseDate)
            let dueDate: ReminderFieldUpdate<Date> = options.has("--clear-due") ? .clear : dueValue.map(ReminderFieldUpdate.set) ?? .unchanged
            let startDate: ReminderFieldUpdate<Date> = options.has("--clear-start") ? .clear : startValue.map(ReminderFieldUpdate.set) ?? .unchanged
            let url: ReminderFieldUpdate<URL> = options.has("--clear-url") ? .clear : try options.single("--url").map { .set(try parseURL($0)) } ?? .unchanged
            let timeZone: ReminderFieldUpdate<String> = options.has("--clear-timezone") ? .clear : zone.map(ReminderFieldUpdate.set) ?? .unchanged
            let recurrence = try parseRecurrence(options).map { [$0] }
            let patch = ReminderPatch(title: try options.single("--title"), notes: notes, dueDate: dueDate, dueDateIsAllDay: options.contains("--due-date") ? true : options.contains("--due") ? false : nil, startDate: startDate, startDateIsAllDay: options.contains("--start") ? false : nil, priority: try options.single("--priority").map(parsePriority), addAlarms: try options.all("--alarm").map(parseDate), clearAlarms: options.has("--clear-alarms"), addRelativeAlarms: try options.all("--alarm-relative").map(parseOffset), addLocationAlarms: try options.all("--alarm-location").map(parseLocationAlarm), url: url, timeZoneIdentifier: timeZone, recurrence: recurrence, clearRecurrence: options.has("--clear-repeat"))
            printReminder(try await manager.edit(identifier: identifier, patch: patch))
        case "complete", "reopen":
            guard remainder.count == 1 else { throw usage("\(command) requires one reminder or task ID") }
            printReminder(try await manager.setCompleted(identifier: remainder[0], completed: command == "complete"))
        case "delete":
            guard let identifier = remainder.first, !identifier.hasPrefix("--") else { throw usage("delete requires a reminder or task ID") }
            let options = try CLIOptions(Array(remainder.dropFirst()), values: [], flags: ["--yes"])
            let target = try await manager.show(identifier: identifier)
            if !options.has("--yes") {
                print("Permanently delete `\(safeText(target.title))` (\(target.localIdentifier))? [y/N]: ", terminator: "")
                guard ["y", "yes"].contains((readLine() ?? "").lowercased()) else { throw ProcessorError(code: "delete_cancelled", message: "Reminder was not deleted.") }
            }
            try await manager.delete(identifier: target.localIdentifier, expectedFingerprint: target.fingerprint)
            print("Deleted reminder \(target.localIdentifier).")
        default: preconditionFailure("validated reminder command was not handled")
        }
    }

    static func runOnce(paths: AppPaths) async throws {
        let (config, _, _, reconciler) = try makeRuntime(paths: paths)
        try await reconciler.reconcile(calendarIdentifier: config.reminders.calendarIdentifier)
    }

    static func daemon(paths: AppPaths) async throws {
        let (config, store, ledger, reconciler) = try makeRuntime(paths: paths)
        let calendarID = config.reminders.calendarIdentifier
        try await reconciler.reconcile(calendarIdentifier: calendarID)
        log(event: "daemon_started", fields: ["calendar_id": calendarID])
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(config.reminders.pollIntervalSeconds) * 1_000_000_000)
                    do { try await reconciler.reconcile(calendarIdentifier: calendarID); log(event: "periodic_reconcile", fields: [:]) }
                    catch { log(event: "reconcile_failed", fields: ["error": safeCode(error)]) }
                }
            }
            group.addTask {
                var pending: Task<Void, Never>?
                for await _ in store.changes() {
                    try? ledger.recordMetric("last_observed_store_change")
                    pending?.cancel()
                    pending = Task {
                        do {
                            try await Task.sleep(nanoseconds: UInt64(config.reminders.notificationDebounceMilliseconds) * 1_000_000)
                            try await reconciler.reconcile(calendarIdentifier: calendarID)
                            log(event: "change_reconcile", fields: [:])
                        } catch is CancellationError {
                        } catch { log(event: "reconcile_failed", fields: ["error": safeCode(error)]) }
                    }
                }
                await pending?.value
            }
            await group.waitForAll()
        }
    }

    static func status(paths: AppPaths) async throws {
        let config = try paths.load()
        let store = EventKitReminderStore()
        let tasks = try Ledger(path: paths.database.path).tasks()
        let metrics = try Ledger(path: paths.database.path).metrics()
        let date = ISO8601DateFormatter()
        print("health: \((await store.authorizationStatus()) == .fullAccess ? "ready" : "needs_attention")")
        print("authorization: \((await store.authorizationStatus()).rawValue)")
        print("inbox: \(config.reminders.sourceName) / \(config.reminders.calendarName)")
        print("last_successful_fetch: \(metrics["last_successful_eventkit_fetch"].map(date.string) ?? "never")")
        print("last_store_change: \(metrics["last_observed_store_change"].map(date.string) ?? "never")")
        print("last_reminder_discovery: \(metrics["last_icloud_visible_reminder_discovery"].map(date.string) ?? "never")")
        for state in TaskState.allCases { print("\(state.rawValue): \(tasks.filter { $0.state == state }.count)") }
    }

    static func listTasks(paths: AppPaths) throws {
        for task in try Ledger(path: paths.database.path).tasks() { print("\(task.taskID)  \(task.state.rawValue)  processor=\(task.processorName ?? "unclassified")  attempts=\(task.attemptCount)") }
    }

    static func inspect(paths: AppPaths, id: String) throws {
        let ledger = try Ledger(path: paths.database.path)
        guard let task = try ledger.task(id: id) else { throw ProcessorError(code: "task_not_found", message: "Task not found.") }
        print("id: \(task.taskID)\nstate: \(task.state.rawValue)\ntitle: \(task.originalTitle)\nprocessor: \(task.processorName ?? "none")\nattempts: \(task.attemptCount)\nresult: \(task.resultSummary ?? "none")\nerror: \(task.errorCode ?? "none") \(task.errorMessage ?? "")")
        print("audit:")
        for entry in try ledger.audit(taskID: id) { print("  \(entry.occurredAt) \(entry.fromState?.rawValue ?? "none") -> \(entry.toState.rawValue) \(entry.detail ?? "")") }
    }

    static func approve(paths: AppPaths, id: String) async throws { try Ledger(path: paths.database.path).approve(taskID: id); try await runOnce(paths: paths) }
    static func retry(paths: AppPaths, id: String) async throws { try Ledger(path: paths.database.path).retry(taskID: id); try await runOnce(paths: paths) }
    static func cancel(paths: AppPaths, id: String) throws { try Ledger(path: paths.database.path).cancel(taskID: id) }

    static func requiredID(_ args: [String]) throws -> String { guard args.count == 2 else { throw ProcessorError(code: "missing_task_id", message: "This command requires one task ID.") }; return args[1] }
    static func option(_ name: String, in args: [String]) -> String? { guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }; return args[index + 1] }
    static func safeCode(_ error: Error) -> String { (error as? ProcessorError)?.code ?? "unknown" }
    static func parseDate(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter(); standard.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: value) ?? standard.date(from: value) else { throw ProcessorError(code: "invalid_date", message: "Use an RFC 3339 timestamp such as 2026-07-18T09:00:00-07:00.") }
        return date
    }
    static func parsePriority(_ value: String) throws -> ReminderPriority {
        guard let priority = ["none": ReminderPriority.none, "low": .low, "medium": .medium, "high": .high][value.lowercased()] else { throw ProcessorError(code: "invalid_priority", message: "Priority must be none, low, medium, or high.") }
        return priority
    }
    static func parseAllDay(_ value: String, timeZoneIdentifier: String?) throws -> Date {
        let parts = value.split(separator: "-"); guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { throw ProcessorError(code: "invalid_date", message: "Use YYYY-MM-DD for an all-day date.") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try parseTimeZone(timeZoneIdentifier)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { throw ProcessorError(code: "invalid_date", message: "The all-day date is invalid.") }; return date
    }
    static func parseTimeZone(_ identifier: String?) throws -> TimeZone {
        guard let identifier else { return .current }; guard let zone = TimeZone(identifier: identifier) else { throw ProcessorError(code: "invalid_timezone", message: "Use an IANA time zone such as America/Los_Angeles.") }; return zone
    }
    static func parseURL(_ value: String) throws -> URL { guard let url = URL(string: value), let scheme = url.scheme, ["https", "http"].contains(scheme.lowercased()) else { throw ProcessorError(code: "invalid_url", message: "URL must use http or https.") }; return url }
    static func parseOffset(_ value: String) throws -> TimeInterval { guard let seconds = Double(value), seconds.isFinite else { throw ProcessorError(code: "invalid_alarm_offset", message: "Relative alarm offset must be seconds, usually negative.") }; return seconds }
    static func parseLocationAlarm(_ value: String) throws -> ReminderLocationAlarmDraft {
        let parts = value.split(separator: ",", maxSplits: 4).map(String.init)
        guard parts.count == 5, ["enter", "leave"].contains(parts[0]), let latitude = Double(parts[1]), let longitude = Double(parts[2]), let radius = Double(parts[3]) else { throw ProcessorError(code: "invalid_location_alarm", message: "Use enter|leave,LATITUDE,LONGITUDE,RADIUS_METERS,NAME.") }
        return ReminderLocationAlarmDraft(name: parts[4], latitude: latitude, longitude: longitude, radiusMeters: radius, proximity: parts[0])
    }
    fileprivate static func parseRecurrence(_ options: CLIOptions) throws -> ReminderRecurrence? {
        guard let raw = try options.single("--repeat") else {
            if options.contains("--repeat-interval") || options.contains("--repeat-count") || options.contains("--repeat-until") { throw usage("--repeat is required with recurrence options") }; return nil
        }
        guard let frequency = ReminderRecurrenceFrequency(rawValue: raw.lowercased()) else { throw ProcessorError(code: "invalid_recurrence", message: "Repeat must be daily, weekly, monthly, or yearly.") }
        let interval = try options.single("--repeat-interval").flatMap(Int.init) ?? 1; guard interval > 0 else { throw ProcessorError(code: "invalid_recurrence", message: "Repeat interval must be positive.") }
        try options.requireExclusive("--repeat-count", "--repeat-until")
        let end: ReminderRecurrenceEnd
        if let count = try options.single("--repeat-count").flatMap(Int.init) { guard count > 0 else { throw ProcessorError(code: "invalid_recurrence", message: "Repeat count must be positive.") }; end = .occurrences(count) }
        else if let until = try options.single("--repeat-until") { end = .date(try parseDate(until)) }
        else { end = .never }
        return ReminderRecurrence(frequency: frequency, interval: interval, end: end)
    }
    static func printReminder(_ reminder: ReminderSnapshot) {
        let formatter = ISO8601DateFormatter()
        print("reminder_id: \(reminder.localIdentifier)\nexternal_id: \(reminder.externalIdentifier ?? "none")\nstate: \(reminder.isCompleted ? "completed" : "incomplete")\ntitle: \(safeText(reminder.title))\nnotes: \(reminder.notes.map(safeText) ?? "none")\nstart: \(reminder.startDate.map(formatter.string) ?? "none")\nstart_all_day: \(reminder.startDateIsAllDay)\ndue: \(reminder.dueDate.map(formatter.string) ?? "none")\ndue_all_day: \(reminder.dueDateIsAllDay)\ntimezone: \(reminder.timeZoneIdentifier ?? "floating/system")\nlocation: \(reminder.location.map(safeText) ?? "none")\nurl: \(reminder.url?.absoluteString ?? "none")\npriority: \(String(describing: reminder.priority))\ncreated: \(reminder.creationDate.map(formatter.string) ?? "unknown")\nmodified: \(reminder.lastModifiedDate.map(formatter.string) ?? "unknown")\ncompleted_at: \(reminder.completionDate.map(formatter.string) ?? "none")")
        if reminder.alarms.isEmpty { print("alarms: none") }
        else {
            for alarm in reminder.alarms {
                switch alarm {
                case .absolute(let date): print("alarm_absolute: \(formatter.string(from: date))")
                case .relative(let seconds): print("alarm_relative_seconds: \(seconds)")
                case .location(let name, let latitude, let longitude, let radius, let proximity):
                    let latitudeText = latitude.map { String($0) } ?? "unknown"
                    let longitudeText = longitude.map { String($0) } ?? "unknown"
                    print("alarm_location: name=\(safeText(name ?? "none")) latitude=\(latitudeText) longitude=\(longitudeText) radius_meters=\(radius) proximity=\(proximity)")
                }
            }
        }
        if reminder.recurrence.isEmpty { print("recurrence: none") }
        for rule in reminder.recurrence { print("recurrence: \(rule.frequency.rawValue) interval=\(rule.interval) end=\(recurrenceEndText(rule.end, formatter: formatter))") }
    }
    static func recurrenceEndText(_ end: ReminderRecurrenceEnd, formatter: ISO8601DateFormatter) -> String { switch end { case .never: return "never"; case .date(let date): return formatter.string(from: date); case .occurrences(let count): return "count:\(count)" } }
    static func usage(_ detail: String) -> ProcessorError { ProcessorError(code: "invalid_arguments", message: "\(detail). Use `taski reminder help`.") }
    static func safeText(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            if scalar == "\n" { return "\\n" }
            if scalar == "\t" { return "\\t" }
            if CharacterSet.controlCharacters.contains(scalar) { return "\\u{\(String(scalar.value, radix: 16))}" }
            return String(scalar)
        }.joined()
    }
    static func log(event: String, fields: [String: String]) { var value = fields; value["event"] = event; value["time"] = ISO8601DateFormatter().string(from: Date()); if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) { print(line) } }
    static func help() { print("""
    taski — safe Reminders task daemon

      setup                 Request access and select an inbox list
      reminder ...          Create, read, edit, complete, reopen, or delete reminders
      probe [--request-access]  Inspect lists and observe changes
      run-once              Reconcile immediately
      daemon                Run notification and timer reconciliation
      status | tasks        Show health or redacted task list
      inspect TASK_ID       Show one task and its audit history
      approve TASK_ID       Explicitly approve and run a task
      retry TASK_ID         Explicitly retry a failed/rejected task
      cancel TASK_ID        Cancel a pending/non-running task
    """) }
    static func reminderHelp() { print("""
    taski reminder — manage only the configured inbox

      create --title TEXT [FIELD OPTIONS]
      list [--all]
      show REMINDER_OR_TASK_ID
      edit REMINDER_OR_TASK_ID [FIELD OPTIONS]
      complete REMINDER_OR_TASK_ID
      reopen REMINDER_OR_TASK_ID
      delete REMINDER_OR_TASK_ID [--yes]

    Field options:
      --notes TEXT | --clear-notes
      --due RFC3339 | --due-date YYYY-MM-DD | --clear-due
      --start RFC3339 | --clear-start
      --timezone IANA | --clear-timezone
      --url HTTP_URL | --clear-url
      --priority none|low|medium|high
      --alarm RFC3339
      --alarm-relative SECONDS
      --alarm-location 'enter|leave,LAT,LON,RADIUS_METERS,NAME'
      --clear-alarms
      --repeat daily|weekly|monthly|yearly [--repeat-interval N]
               [--repeat-count N | --repeat-until RFC3339]
      --clear-repeat

    Alarm options may be repeated. Clear options are valid for edit only.
    """) }
}

private struct CLIOptions {
    private var valueMap: [String: [String]] = [:]
    private var flagSet: Set<String> = []

    init(_ arguments: [String], values: Set<String>, flags: Set<String>) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if flags.contains(argument) { flagSet.insert(argument); index += 1; continue }
            guard values.contains(argument) else { throw TaskiCLI.usage("unknown option `\(argument)`") }
            guard arguments.indices.contains(index + 1) else { throw TaskiCLI.usage("\(argument) requires a value") }
            valueMap[argument, default: []].append(arguments[index + 1]); index += 2
        }
    }

    var hasMutation: Bool { !valueMap.isEmpty || !flagSet.isEmpty }
    func has(_ name: String) -> Bool { flagSet.contains(name) }
    func contains(_ name: String) -> Bool { valueMap[name] != nil }
    func all(_ name: String) -> [String] { valueMap[name] ?? [] }
    func single(_ name: String) throws -> String? {
        let values = all(name); guard values.count <= 1 else { throw TaskiCLI.usage("\(name) may be supplied only once") }; return values.first
    }
    func required(_ name: String) throws -> String { guard let value = try single(name) else { throw TaskiCLI.usage("\(name) is required") }; return value }
    func requireExclusive(_ first: String, _ second: String) throws { if contains(first) && contains(second) { throw TaskiCLI.usage("use either \(first) or \(second)") } }
}
