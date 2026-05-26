# TODO

Backlog items proposed by adversarial architecture/code and UX/product reviews. These are follow-ups only; they are not implementation commitments.

## Architecture And Code Review Follow-Ups

- **P2: Expand UI control and observability for autonomous workflows.** Add a first-class workflow/run inspector, criteria checklist, diff/artifact browser, per-agent control panel, reconnect/resume UI.
## Codex App Comparison Follow-Ups

Computer Use could inspect this app, but direct Computer Use access to `com.openai.codex` was blocked by the environment. These follow-ups are based on Codex-style coding-agent features visible from the current desktop context and prior screenshots in this project thread.

## User follow-ups

Continuous improvement workflow:
- Consists of a todo-generator, reviewer, and implementor
- These run continuously until shut down by the orchestrator, or until the todo-generator judges the project is in an acceptable state and no further improvements can be made in the spirit of the original prompt (and calls the stop tool)
- The roles hand off to each other in a loop:
    - todo-generator looks for potential improvements to the project, not necessarily bounded by the original requirements, and generates a TODO list. Hands this off to the implementor as a prompt.
    - The implementor implements and hands off to the todo-generator again, once the reviwer (which reviews asynchronously) is satisfied
    - Todo-generator can inspect the graph state. It can sleep for x minutes if there haven't been enough changes to the project
- There should be proper concurrency controls here so that the implementor doesn't interfere with ongoing implementation. These should already be in place to some extent, but do an audit of these.

UI-QA role
- Let's add such a role, with access to Playwright and Computer use tools, according to the guidelines here:
https://developers.openai.com/api/docs/guides/tools-computer-use?computer_use_action_handlers=playwright#option-1-run-the-built-in-computer-use-loop
- Let's test this out with a UI development task., making sure the UI-QA agent provides useful feedback

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



## Completion Criteria:

Let's represent completion criteria as a first-class concept in the workflow engine.

Let's add a stop tool that agents can call when they believe they're done.

If all agents in the workflow have stopped, the workflow is considered stopped, and a completion message is sent to the caller (for now, the caller is always the orchestrator, but it can be any role with the "start workflow" toolset).

agents in a workflow have a dependency graph: they cannot stop or handoff until all dependencies have stopped or handed off. For example, in "implementator qa loop": the implementor isn't done until the QAer has stopped, marking acceptance criteria complete.

Another criteria for stop or handoff: all workflows the agent has started have completed.

This is parallel to the handoff tool, which has an artifact as input. Handoff is meant for synchronous workflow, like the planner; stop is meant for async ones.

The caller can also stop the workflow itself, before it's completed. This (stop_workflow) is exposed as another tool in the "start workflow" toolset. stop_agent is another tool the orchestrator has access to, for stopping individual agents.
