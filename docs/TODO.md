# TODO

Backlog items proposed by adversarial architecture/code and UX/product reviews. These are follow-ups only; they are not implementation commitments.

## Architecture And Code Review Follow-Ups

- **P1: Fix transcript/event causality ordering.** Tool-side effects such as `agent.stopped`, `workflow.completed`, and workspace file events can appear before the `agent.tool_call`/`agent.tool_result` transcript items that caused them; normalize event buffering so the timeline reads in causal order.
- **P1: Make child workflow execution resumable outside a single model turn.** The orchestrator currently executes long child workflows inside one WHAM tool-call loop, which can still exhaust the model turn budget. Move child workflows to durable scheduler jobs and notify the caller asynchronously.
- **P1: De-duplicate tool transcript events.** Engine tools such as `workspace_write_file` currently emit both runtime-level tool call/result events and internal engine tool events, creating duplicate rows and inconsistent tool names.
- **P2: Expand UI control and observability for autonomous workflows.** Add a first-class workflow/run inspector, criteria checklist, diff/artifact browser, per-agent control panel, reconnect/resume UI.
- **P2: Add retry/resume UI for recovered scheduler jobs.** Recovery currently marks interrupted jobs failed; persist enough job input and expose a retry action so users can resume work after daemon restarts.

## UX And Product Review Follow-Ups

- **P1: Fix transcript timeline hangs.** Move timeline projection out of SwiftUI body evaluation, bound or virtualize rendered transcript rows, defer large payload/diff rendering until expansion, and throttle `ScrollViewReader.scrollTo` during transcript/snapshot updates.
- **P2: Improve dense workflow graph layout.** Reduce edge overlap and node crowding for multi-agent workflows, add pan/zoom or fit controls, and consider grouped workflow lanes for instantiated subgraphs.


## Codex App Comparison Follow-Ups

Computer Use could inspect this app, but direct Computer Use access to `com.openai.codex` was blocked by the environment. These follow-ups are based on Codex-style coding-agent features visible from the current desktop context and prior screenshots in this project thread.

- **P1: Add an explicit plan/checklist panel.** Show the orchestrator's current plan as editable/checkable steps with status, owner agent, and links to related transcript events.
- **P1: Add a changed-files and diff review surface.** Summarize touched files in a dedicated panel, open inline diffs from `workspace.file_touched` events, show additions/deletions, and allow copying file paths or diff hunks.
- **P1: Add command/tool execution details.** For tool calls, show duration, status, working directory, exit code when applicable, raw input/result, and a compact/expanded Codex-style rendering.
- **P2: Add copy/share/export actions for session artifacts.** Export transcript, event log, debug log, workspace path, and selected diffs from the session UI.

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



## Completion Criteria:

Let's represent completion criteria as a first-class concept in the workflow engine.

Let's add a stop tool that agents can call when they believe they're done.

If all agents in the workflow have stopped, the workflow is considered stopped, and a completion message is sent to the caller (for now, the caller is always the orchestrator, but it can be any role with the "start workflow" toolset).

agents in a workflow have a dependency graph: they cannot stop or handoff until all dependencies have stopped or handed off. For example, in "implementator qa loop": the implementor isn't done until the QAer has stopped, marking acceptance criteria complete.

Another criteria for stop or handoff: all workflows the agent has started have completed.

This is parallel to the handoff tool, which has an artifact as input. Handoff is meant for synchronous workflow, like the planner; stop is meant for async ones.

The caller can also stop the workflow itself, before it's completed. This (stop_workflow) is exposed as another tool in the "start workflow" toolset. stop_agent is another tool the orchestrator has access to, for stopping individual agents.
