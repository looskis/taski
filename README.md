# Taski

Taski is a per-user macOS background app that turns one dedicated iCloud Reminders list into a strict, durable task inbox. It uses public EventKit APIs, never evaluates reminder text as shell code, records state changes in SQLite, and completes a reminder only after its processor succeeds.

Version 1 supports:

- `run daily-report` — bounded, read-only daily timestamp report.
- `report system` — bounded, read-only macOS version and uptime report.
- `message <recipient>: <body>` — requires explicit approval and creates a local draft in Taski's application-support directory; it never sends a message.

Anything else is rejected and remains incomplete. Shared reminder lists are not supported in v1; select a private list you own.

## Requirements

- macOS 14 or later and Swift 5.10 or later.
- An iCloud Reminders list such as `Agent Inbox`.
- A stable Apple code-signing identity for normal installation. Ad-hoc signing is only for local build verification and should not be used across upgrades because privacy grants may not survive.

## Build, configure, and run

```sh
swift run taski-tests
TASKI_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/build-app.sh
dist/Taski.app/Contents/MacOS/taski setup
scripts/install-launch-agent.sh /absolute/path/to/Taski.app
```

The interactive `setup` is the only command that intentionally requests Reminders permission. It stores both EventKit identifiers and display names in `~/Library/Application Support/Taski/config.json`. The ledger and append-only audit history live beside it in `ledger.sqlite3`.

For an unsigned local packaging check, run `scripts/build-app.sh --unsigned`. Do not move or replace an installed app without reinstalling the LaunchAgent, because it contains the executable's absolute path.

## Operator commands

```text
taski probe --request-access   List sources/lists and observe store changes
taski run-once                 Reconcile immediately
taski daemon                   Run the foreground daemon
taski status                   Show authorization, inbox, and state counts
taski tasks                    List task IDs and states without reminder content
taski inspect TASK_ID          Show task details and audit history locally
taski approve TASK_ID          Durably approve, then reconcile
taski retry TASK_ID            Explicitly retry a failed or rejected task
taski cancel TASK_ID           Record local cancellation
```

The daemon reconciles at startup, after debounced `EKEventStoreChanged` notifications, and every 60 seconds. Every notification causes a full refetch; EventKit objects are not cached. Reconciliation is serialized, processors time out after 120 seconds, and no failure is automatically retried forever. A task left `running` by a crash is marked failed for operator inspection rather than assumed safe to repeat.

## Security and recovery

Reminder text is untrusted and is accepted only by the explicit grammar. Shell metacharacters and control characters are rejected, titles/bodies are length-limited, task lists and structured daemon logs omit reminder content, and consequential message drafts require a durable approval. Task identity matches external ID first, then local ID, then calendar/source plus normalized fingerprint. Editing an unapproved task resets its classification and invalidates the pending approval context.

The SQLite result is committed before EventKit completion. If completion fails, the succeeded task remains in the ledger and a later reconciliation retries only completion. Processors receive the stable task UUID as their idempotency key.

## Troubleshooting

- `access_denied`: enable Taski under System Settings → Privacy & Security → Reminders. Keep the bundle ID and signing identity stable across upgrades.
- `calendar_missing`: the selected list was deleted/recreated or its EventKit ID changed; run `taski setup` again. Names are retained for diagnosis but never used alone as identity.
- No iPhone/Siri task yet: confirm the same Apple account and list, wake the Mac, and allow iCloud time to synchronize. Delivery latency is not guaranteed.
- LaunchAgent: inspect `~/Library/Logs/Taski/taski.log`, `taski.error.log`, and `launchctl print gui/$UID/com.kevinloo.taski`.
- Remove the agent with `scripts/uninstall-launch-agent.sh`. It moves the plist to Trash and retains configuration, audit history, and results.

## Verification scope

`swift run taski-tests` exercises the public parser, ledger, audit/id recovery, approval-edit invalidation, successful completion, safe rejection, and repeated-reconciliation behavior with a fake reminder store. Real iCloud synchronization, Siri delivery, permission revocation, sleep/wake, signing upgrades, and multi-day soak behavior require a signed bundle and the user's Apple devices; use the acceptance matrix in the original build plan for that manual test pass.
