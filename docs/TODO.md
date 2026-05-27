# TODO

Backlog items proposed by adversarial architecture/code and UX/product reviews. These are follow-ups only; they are not implementation commitments.

## Architecture And Code Review Follow-Ups

## Codex App Comparison Follow-Ups

Computer Use could inspect this app, but direct Computer Use access to `com.openai.codex` was blocked by the environment. These follow-ups are based on Codex-style coding-agent features visible from the current desktop context and prior screenshots in this project thread.

## User follow-ups

### 2026-05-26 Deep UX And Design Audit

Clear fixes to work down:

- Redact credentials and token-like payloads from daemon/client error surfaces before they reach status banners, Settings, or logs intended for users.
- Stop formatting the daemon port with locale grouping separators in Settings.
- Make the inspector tab bar and inspector header actions adapt cleanly at narrow widths; current segmented controls and action buttons clip on Workspace/Debug.
- Improve Workspace diff previews: hide zero-diff repeats by default, wrap or horizontally scroll long diff lines, and make latest-vs-history clearer.
- Make Plan completion criteria scannable by hiding raw event/workflow IDs until expanded or copied.
- Improve Roles editor responsiveness; the detail form clips horizontally and important fields disappear at common window widths.
- Improve Settings MCP server rows; long command/auth-instruction text truncates without a way to expand or inspect details.
- Add safer, less prominent presentation of account identifiers in Auth settings, with copy affordances for users who need exact values.
- Make the New Session setup controls read as one coherent form; the current mode/model/workspace strip is cramped and easy to miss.
- Add transcript result counts and an obvious active-filter summary near search, especially when an agent filter and text search are combined.

Big product/design judgment calls:

- Consider a command-palette/global search model for sessions, artifacts, agents, files, and transcript events, similar to Codex’s fast navigation philosophy.
- Consider making the graph an overview/minimap rather than a full inspector default; for many workflows the useful information is status, ownership, next edge, and blockers.
- Consider adding Codex-like workspace affordances that fit this app: branch/dirty-state awareness, test-command quick runs, diff review queue, and PR/publish actions guarded by role policy.
- Consider moving Roles/Workflows editing out of the main session source list into Settings or a dedicated Library window to keep the primary app focused on running work.

### 2026-05-27 Computer Use Deep QA Pass

Audited with Computer Use across transcript expansion, inspector tabs, toolbar menus, sidebar destinations, Settings panes, and macOS menus.

Clear fixes to work down:

- Fix the All Sessions navigation state loss in the mockup fixture; clicking All Sessions/reselecting the current session can clear the loaded transcript into a permanent "Loading session..." empty state while the selected row remains unchanged.
- Reconcile connection status surfaces. The top bar/status strip can say Connected/Local while the session banner says "Daemon is not connected," which leaves users with no trustworthy source of truth.
- Make the Plan inspector consume the same plan/checklist signal as the transcript. The transcript shows an expandable plan row, while the Plan pane still says "No plan yet."
- Populate the Debug inspector for completed fixture workflows or clearly label fixture/debug-data unavailability. "0 runs / 0 logs" looks wrong next to a completed multi-agent transcript.
- Replace the expanded grouped transcript row's raw `Plan ID` detail with useful human-facing content: collapsed event summaries, handoffs/messages, criteria state, or a path to the related Plan inspector section.
- Make Workspace changed-file expansion consistent with its summary. Rows can show changed-line counts but expand to "No diff recorded for this file," with Copy Diff disabled.
- Clean up the dashboard table: important values truncate heavily, empty placeholder rows look like loading skeletons after data is loaded, and tiny action icons need clearer affordances.
- Reset or hide the inspector for New Session drafts. Leaving the prior Debug pane visible beside the draft composer makes the draft look tied to an unrelated session.
- Make the New Session status strip draft-aware; runtime/event/connection metrics read like live session state even while the user is only configuring a new session.
- Clarify the Workflows empty state. "No Workflows" is confusing when built-in workflows/roles exist; distinguish user-defined workflows, built-ins, and unavailable workflow libraries.
- Remove artifact-menu duplication. Session Artifacts repeats copy/export/share transcript actions both at the top level and again inside nested Copy/Export/Share groups.
- Rename or clarify the Embed Code toolbar control. The menu opens workspace targets such as VS Code, Finder, and iTerm, so "Open Workspace" would match the action better.
- Tone down disabled primary buttons in Auth settings. Disabled actions such as Save API Key still look blue/primary and clickable.
- Clarify Settings > Skills empty state. It says "0 installed / No Skills" even though the active Codex environment has plugin and user skills available; distinguish app-discoverable skills from runtime skills.
- Add a visible transcript result count, active-filter summary, and clear-search affordance near the search field. The current filtered state is too implicit, especially when text search and agent filters combine.
- Smooth graph zoom behavior so zooming keeps important nodes in frame. One zoom-in can crop node labels abruptly, although Reset recovers the view.
- Add app-specific View menu commands for the visible UI: toggle inspector/details, reset/zoom graph, focus search, show dashboard, and switch common panels.
- Make the agent filter control's behavior match its chevron. It looks like a menu, but clicking the current agent label can act like a clear/toggle action.

## Not Completed

- Inspector tab/header responsive layout clips at common widths.
- Workspace diff preview still has clipped long diff lines and could make latest-vs-history clearer.
- Roles editor still needs responsive detail work.
- New Session setup needs a clearer form hierarchy.
- Big product/design judgment calls from the 2026-05-26 audit remain intentionally unimplemented.

## Completed Non-Controversial Items

- **2026-05-25: Add archived sessions.** Added durable `session.archived`/`session.restored` events, an Archived Sessions destination, restore actions, read-only archived sessions, and daemon tests proving logs are preserved.
- **2026-05-25: Add multi-session dashboard and actions.** Added sidebar multi-selection, confirmed batch archive, "View Selected Sessions", and a session dashboard/table with status, last activity, mode, workspace path, active/paused agents, failure count, and quick actions.
- **2026-05-25: Add real new-session setup.** Added quick blank-workspace setup, parent-folder workspace selection, live auth preflight, and model/reasoning controls on the composer.
- **2026-05-25: Improve new-session prompt reliability.** Preserved draft prompts across failed creation attempts, restored explicit focus behavior, and used a larger dedicated prompt editor for new sessions.
- **2026-05-25: Move OpenAI setup into session start.** Added inline `Set Up OpenAI...` and refresh actions, credential checking state, and Live creation blocking until credentials are ready.
- **2026-05-25: Add session model and effort controls.** Session creation now records model/reasoning effort and passes them through the daemon to live Agents SDK/WHAM runs.
- **2026-05-25: Add durable scheduler recovery.** Added append-only scheduler job lifecycle events, per-run heartbeat records, startup recovery for interrupted jobs, stale tool-call cleanup on failed/cancelled/completed agents, and daemon tests for restart recovery.
- **2026-05-25: Remove demo planning from production paths.** Live planners must now persist model/user-authored plans through `plan_create`; the canned plan remains available only for deterministic debug mode, with tests covering both paths.
- **2026-05-25: Enforce completion criteria as first-class state.** Added workflow-instance criterion ledger events, owner-scoped stop validation, missing/invalid criterion blockers, prompt-visible criterion IDs, and workflow completion gated by completed required criteria.
- **2026-05-25: Secure the local daemon.** Bound Bun/Node daemons to loopback, added per-install WebSocket token auth, loopback Origin validation, unauthenticated `/health` identity probes, and Swift launcher/client token wiring.
- **2026-05-25: Introduce a capability broker.** Added centralized role-policy decisions for workspace read/write, commands, plan creation, and MCP exposure, with durable `capability.checked` audit events for tool use.
- **2026-05-25: Harden workspace management.** Added pre-write file leases, per-file write serialization, durable lease/touch reconstruction, conflict-blocking before file mutation, command-write diff attribution with rollback on lease conflicts, and review checkpoint events on agent stop.
- **2026-05-25: Harden the event store.** Added checksummed event frames, monotonic sequence IDs compatible with legacy logs, in-process and stale-safe file append locks, rebuilt session/agent/tool indexes, compaction-aware snapshot replay, per-agent transcript repair, and corruption recovery tests.
- **2026-05-25: Isolate OpenAI and WHAM runtimes.** Split live execution into per-run Agents SDK and WHAM compatibility adapters, passed a per-run OpenAI provider to the SDK, added timeout/retry behavior, preserved model/reasoning settings, captured WHAM usage/retry/duration telemetry, and documented the WHAM compatibility boundary.
- **2026-05-25: Harden daemon ownership proof.** Added a token-derived nonce challenge endpoint and changed the macOS launcher to verify daemon ownership with local HMAC proof before sending the WebSocket auth token to any loopback listener.
- **2026-05-25: Surface failures prominently.** Added a session-level status banner with a Debug shortcut and dismissible transient errors.
- **2026-05-25: Clarify agent controls.** Split transcript viewing from the control target, added a `Control` toolbar menu, exposed `Controlling: <agent>` in the graph panel, and renamed pause to "Pause Scheduling."
- **2026-05-25: Add a Workspace inspector.** Added a Workspace inspector tab with root path, copy/open actions, touched files, diff stats, conflict counts, and empty states.
- **2026-05-25: Add transcript search and filters.** Added text search across transcript event text, participants, event type, and payload content.
- **2026-05-25: Route workflow prompts with real context.** Workflow handoffs and messages now include the original goal, role-specific fallback tasks, done criteria, and the sender's latest artifact/message instead of generic edge text.
- **2026-05-25: Add workspace command tool.** Command-enabled roles can run bounded commands inside the session workspace, allowing QA to execute tests and local CLI checks.
- **2026-05-25: Harden WHAM live calls.** Added retry/backoff for transient WHAM 429/502/503/504 responses and raised the live turn budget for longer workflow orchestration.
- **2026-05-25: Normalize runtime tool causality.** Added runtime-side event streaming for WHAM transcript events so tool calls are durably logged before engine side effects and tool results are logged afterward, with tests preventing duplicate returned tool events.
- **2026-05-25: Schedule child workflow execution durably.** Changed `workflow_start` and `plan_instantiate` to enqueue workflow execution as durable scheduler jobs, added recovery that reschedules interrupted workflow jobs, prevented root workflow activation from consuming child graph edges, and covered async completion/recovery in daemon tests.
- **2026-05-25: De-duplicate WHAM workspace tool transcript rows.** Marked workspace write/command tools as engine-logged and suppressed WHAM wrapper `agent.tool_call`/`agent.tool_result` rows for those tools, preserving canonical diff/command transcript events from the engine while keeping normal workflow tools visible.
- **2026-05-25: Harden transcript timeline rendering.** Moved timeline grouping into SwiftUI state, bounded rendered rows to the latest 500 filtered events, throttled auto-scroll, and deferred large transition/plan/tool payload rendering until rows are expanded.
- **2026-05-25: Add a Plan inspector panel.** Added a right-side Plan pane with current goal, workflow status, completion-criteria checklist state, owner-agent links, agent prompts/done criteria, and transcript event filtering by event id.
- **2026-05-25: Add changed-files and diff review surface.** Upgraded the Workspace inspector with changed-file totals, expandable per-file diff events, inline colored diffs, and copy actions for absolute file paths and recorded diffs.
- **2026-05-25: Keep durable recovery handles for open workflows.** Added a `workflow.waiting` event for incomplete workflow executions, recorded pending agents/criteria and plan context, and taught daemon restart recovery to reschedule waiting open workflows.
- **2026-05-25: Count workflow turns from scheduler jobs.** Changed workflow run accounting to use completed/failed `workflow-agent-turn` scheduler jobs instead of transcript artifacts, added workflow metadata to terminal job events, and covered multi-file turn accounting in tests.
- **2026-05-25: Fix completed session dashboard status.** Added explicit daemon session statuses, live Swift summary refresh, dashboard labels/icons for terminal states, and stop gating so orchestrators cannot complete while child workflows are still open.
- **2026-05-25: Avoid noisy completed-agent messaging failures.** Changed orchestrator agent-to-agent messaging to record `message.skipped` no-op events with target status guidance when the target agent is completed, failed, cancelled, or paused, instead of failing otherwise successful turns.
- **2026-05-25: Add command/tool execution details.** Upgraded tool timeline rows with status labels/icons, command duration, exit code, working directory metadata, and preserved expandable input/output/diff details.
- **2026-05-25: Add copy/share/export actions for session artifacts.** Added toolbar artifact actions for readable transcripts, schema-shaped event JSONL, debug JSONL, workspace paths, system sharing, and Save Panel export, alongside existing per-file path and diff copy actions.
- **2026-05-25: Preserve tool pairing across timeline truncation.** Changed timeline rendering to group tool calls/results before limiting visible rows, so completed tool rows keep their paired call and result even near the render boundary.
- **2026-05-25: Improve dashboard status triage.** Added session dashboard status chips with counts and filters for active, paused, failed, completed, cancelled, idle, and archived sessions.
- **2026-05-25: Make artifact actions more discoverable.** Renamed the toolbar control to Session Artifacts and surfaced copy/export/share transcript plus workspace-path actions at the top level while preserving full copy/export/share menus.
- **2026-05-25: Improve Workspace inspector hierarchy.** Made workspace and changed-file names primary, moved full paths into secondary/copyable details, added per-file change summaries, and summarized diff headers before per-event expanded previews.
- **2026-05-25: Preserve transcript reading position.** Added an explicit Follow Live toggle and stopped transcript search/filter changes from forcing the timeline back to the newest row.
- **2026-05-25: Disambiguate repeated session rows.** Added status, last-activity, active/failure hints, and durable user-editable session titles to sidebar rows without changing creation-time ordering.
- **2026-05-25: Reduce expanded transcript hang risk.** Investigated the scrolling hang stackshot and capped inline expanded prompt/diff payload rendering so large planner handoff rows no longer force SwiftUI to lay out unbounded text inside the lazy transcript stack.
- **2026-05-25: Improve workflow graph navigation and layout.** Added graph pan/zoom/reset controls, background deselection, more distinct status styling, workflow-instance lanes, wrapped dense lane layout, stable edge routing to node boundaries, arrowheads, and endpoint dots for live workflow graphs.
- **2026-05-25: Add orchestrator event inspection tools.** Added `agent_events_list` and `agent_event_inspect` so the orchestrator can inspect another agent's transcript events, tool calls, command outputs, diffs, and full event payloads.
- **2026-05-25: Add automated Swift projection coverage.** Added a SwiftPM test target covering transcript filtering, timeline tool pairing, event-log export payloads, and session summary status projection; wired it into `npm test`.
- **2026-05-25: Add retry UI for recovered scheduler jobs.** Added a `retryRecoveredJob` daemon protocol method using durable scheduler job metadata, plus a Debug-panel recovered-jobs surface with retry controls.
- **2026-05-26: Expand workflow observability controls.** Added an explicit Debug-panel scheduler run inspector derived from durable scheduler job events, including run status, prompts, terminal reasons, workflow identifiers, bounded debug log rendering, and Swift projection coverage. This completes the broader observability TODO alongside the existing Plan criteria checklist, Workspace diff/artifact browser, per-agent controls, reconnect/resume actions, and recovered-job retry controls.
- **2026-05-26: Add continuous improvement workflow.** Added TODO Generator, Continuous Implementor, and Continuous Reviewer roles; a built-in continuous-improvement workflow; graph/event/file inspection for generator/reviewer roles; a bounded sleep tool; generator-driven workflow close semantics; command write rollback for non-writing roles; and a concurrency audit in `docs/concurrency-audit.md`.
- **2026-05-26: Add UI-QA role and workflow.** Added a UI-QA role with visible local browser and host-side Computer Use policy bits, a `ui-qa-review` workflow, local-only Playwright UI check tooling, Computer Use bridge guidance, and daemon tests proving the role can exercise and reject those tools appropriately on a UI development task.
- **2026-05-26: Fix audit-critical credential and settings display issues.** Redacted Keychain credential-write failures in the daemon and Swift status surfaces, stopped locale-grouped daemon port rendering, and shortened visible account/client identifiers in Auth settings while preserving status detail.
- **2026-05-27: Work down second UX audit pass.** Added transcript event counts for filtered and unfiltered views, suppressed zero-diff Workspace events in previews and copy output, tucked Plan criterion identifiers behind disclosure, and added expandable MCP server detail rows for long commands/auth guidance.
- **2026-05-27: Implement mockup 1 direction while keeping Graph.** Added a compact session state strip above the transcript, grouped dense low-level transcript events behind expandable rows, and replaced the resizable inspector split with a collapsible fixed-width detail drawer that preserves the current Workflow Graph view.
- **2026-05-27: Tighten mockup 1 visual density.** Reduced the state strip to conditional signal, hid escaped single-row lifecycle noise from the main transcript, stopped mailbox internals from rendering as user messages, capped action summary rows, and simplified recent-session rows toward the mockup's calmer sidebar.
