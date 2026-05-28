# TODO

Backlog items proposed by adversarial architecture/code and UX/product reviews. These are follow-ups only; they are not implementation commitments.

## Architecture And Code Review Follow-Ups

## Codex App Comparison Follow-Ups

Computer Use could inspect this app, but direct Computer Use access to `com.openai.codex` was blocked by the environment. These follow-ups are based on Codex-style coding-agent features visible from the current desktop context and prior screenshots in this project thread.

## User follow-ups

### 2026-05-26 Deep UX And Design Audit

Clear fixes to work down:


Big product/design judgment calls:

- Consider a command-palette/global search model for sessions, artifacts, agents, files, and transcript events, similar to Codex’s fast navigation philosophy.
- Consider making the graph an overview/minimap rather than a full inspector default; for many workflows the useful information is status, ownership, next edge, and blockers.
- Consider adding Codex-like workspace affordances that fit this app: branch/dirty-state awareness, test-command quick runs, diff review queue, and PR/publish actions guarded by role policy.
- Consider moving Roles/Workflows editing out of the main session source list into Settings or a dedicated Library window to keep the primary app focused on running work.

### 2026-05-27 Computer Use Deep QA Pass

Audited with Computer Use across transcript expansion, inspector tabs, toolbar menus, sidebar destinations, Settings panes, and macOS menus.

Clear fixes to work down:

- Make the New Session status strip draft-aware; runtime/event/connection metrics read like live session state even while the user is only configuring a new session.
- Clarify the Workflows empty state. "No Workflows" is confusing when built-in workflows/roles exist; distinguish user-defined workflows, built-ins, and unavailable workflow libraries.
- Remove artifact-menu duplication. Session Artifacts repeats copy/export/share transcript actions both at the top level and again inside nested Copy/Export/Share groups.
- Rename or clarify the Embed Code toolbar control. The menu opens workspace targets such as VS Code, Finder, and iTerm, so "Open Workspace" would match the action better.
- Tone down disabled primary buttons in Auth settings. Disabled actions such as Save API Key still look blue/primary and clickable.
- Clarify Settings > Skills empty state. It says "0 installed / No Skills" even though the active Codex environment has plugin and user skills available; distinguish app-discoverable skills from runtime skills.
- Smooth graph zoom behavior so zooming keeps important nodes in frame. One zoom-in can crop node labels abruptly, although Reset recovers the view.
- Add app-specific View menu commands for the visible UI: toggle inspector/details, reset/zoom graph, focus search, show dashboard, and switch common panels.

### 2026-05-27 Adversarial Code Review

Judgement-heavy follow-ups:

- Make workspace authorization symlink-safe. Current path checks are lexical; reads, writes, and command change tracking need a no-follow/realpath policy that prevents allowed-root symlinks from escaping the workspace.
- Serialize workflow graph mutation under a per-session lock. Concurrent workflow instantiation can read the same snapshot, choose overlapping node IDs, and publish graph snapshots that drop each other's changes.
- Add a hard per-run deadline and bounded orchestrator turn limit across Agents SDK and WHAM runtimes so tool loops cannot keep scheduler jobs alive indefinitely.
- Emit durable `agent.tool_call` and `agent.tool_result` rows for every local tool used through the Agents SDK adapter, not only engine-owned workspace tools.
- Add WebSocket subscriber cleanup on close in the daemon; the Swift client now resubscribes after reconnect, but stale daemon-side callbacks should also be removed.
- Clarify completed-agent scheduling semantics. Some paths treat completed agents as terminal message targets, while continuous/controller workflows intentionally re-enter completed roles; this needs an explicit lifecycle model before changing scheduler gates.
- Replace regex/prose-based auto-completion gates with explicit tool/state transitions for criteria satisfaction.
- Split `SessionManager` into protocol routing, scheduler/recovery, workspace tools, workflow tools, and runtime integration modules; its current size hides race boundaries.
- Split Swift `SessionStore` transport state, projection state, fixture data, and user actions into smaller stores or coordinators.
- Surface malformed personal role/workflow catalog diagnostics in `listRoles`/`listWorkflows` instead of silently skipping broken user-authored files.
- Replace ad hoc Codex MCP TOML parsing with a real TOML parser and fixtures that cover quoted commas, multiline arrays, inline comments, and richer config shapes.
- Declare `esbuild` directly and add a non-GUI packaging smoke test so the macOS bundle script does not depend on a transitive dependency.
- Generate Swift protocol models from shared schemas or add golden JSON contract tests to catch daemon/mac drift.
- Move built-in roles/workflows out of `workflowEngine.ts` into versioned JSON/YAML fixtures loaded through the same validation path as personal workflows.
- Add explicit continuous-workflow budgets for cycle count, elapsed time, and total turns; `maxActiveAgents` is not enough for self-improving loops.

## Not Completed

- Big product/design judgment calls from the 2026-05-26 audit remain intentionally unimplemented.

## Completed Non-Controversial Items

- **2026-05-27: Make inspector chrome responsive.** Added a narrow-width inspector panel menu and adaptive Plan, Workspace, and Debug headers so tabs and actions remain available without clipping.
- **2026-05-27: Improve Workspace diff previews.** Hid metadata-only workspace touches by default, sorted recorded diffs newest-first, made latest/history labels explicit, aligned Copy Diff with the visible diff set, and added horizontal scrolling for long diff lines.
- **2026-05-27: Improve Roles editor responsiveness.** Switched Roles to a stacked list/detail layout at narrow widths, collapsed role actions to icon-only buttons, and reduced the editor minimum width so fields remain reachable at common desktop sizes.
- **2026-05-27: Clarify New Session setup.** Replaced the cramped setup strip with a grouped form for runtime, workspace, and credential state, including responsive fallbacks and compact action buttons.
- **2026-05-27: Reconcile connection status surfaces.** Centralized display connection health, suppressed stale daemon-disconnected errors after reconnect, and aligned the toolbar pill and composer banner with the same source of truth.
- **2026-05-27: Sync Plan inspector with transcript plan signal.** Let the Plan pane consume all `plan.created` transcript events, preserve structured plan/checklist rendering when available, and show a deliberate fallback summary for unstructured fixture plan events.
- **2026-05-27: Clarify Debug fixture telemetry.** Replaced misleading fixture `0 runs / 0 logs` debug states with explicit copy that scheduler runs and daemon logs are unavailable in the static mock session.
- **2026-05-27: Improve expanded plan transcript rows.** Replaced raw plan ID output with a compact human-facing summary and a working jump to the Plan inspector while preserving structured plan payload rendering.
- **2026-05-27: Clarify no-diff Workspace expansions.** Made changed-file rows explicit when line counts exist without recorded diff bodies, kept Copy Diff disabled only when no copyable diff exists, and renamed hidden entries as no-diff workspace events.
- **2026-05-27: Clean up the dashboard table.** Improved truncation for dense values, clarified empty dashboard states, abbreviated workspace paths with full-path help, and made row actions compact but discoverable.
- **2026-05-27: Hide inspector for New Session drafts.** Kept prior session details from appearing beside the draft composer while preserving the user’s existing inspector tab and drawer state for real sessions.
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
- **2026-05-25: Clarify agent controls.** Split transcript viewing from run control state and renamed pause to "Pause Scheduling."
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
- **2026-05-27: Implement workflow-grouped graph sidebar.** Removed the control-agent chooser from the graph/sidebar surface, kept Graph/Plan/Workspace/Debug tabs available, added explicit workflow grouping behind agent nodes, made message edges dotted and handoff edges solid, routed fan-out edges around intermediate nodes, and kept event detail dismissal in sync with inspector tab changes.
