# TODO

Backlog items proposed by adversarial architecture/code and UX/product reviews. These are follow-ups only; they are not implementation commitments.

## Architecture And Code Review Follow-Ups

- **P0: Add durable scheduling and restart recovery.** Add a persistent run queue/state machine with resumable workflow instance records, idempotent transition execution, heartbeat/lease expiry, and startup reconciliation.
- **P0: Remove demo-hardcoded planning from production paths.** Require planner output through `plan_create`, validate it, and execute only model/user-authored workflow specs.
- **P0: Enforce completion criteria as first-class state.** Build a criterion ledger keyed by workflow instance, validate `completedCriteria` against spec/owner, block completion until required criteria pass, and expose pending blockers.
- **P0: Secure the local daemon.** Bind explicitly to loopback, require a per-install auth token on WebSocket and OAuth callback, validate `Origin`, and gate sensitive methods separately.
- **P1: Introduce a capability broker.** Centralize file read/write, command execution, MCP tool allowlists, approvals, auditing, and per-role sandbox constraints.
- **P1: Harden workspace management for multi-agent coding.** Add session workspace provisioning, optional repo clone/worktree support, pre-write file leases, conflict blocking, merge/review checkpoints, and durable lease reconstruction.
- **P1: Make the event store operationally robust.** Add monotonic sequence IDs, append serialization per session, checksummed frames, snapshot compaction, indexes for sessions/agents/tool calls, and corruption recovery tests.
- **P1: Isolate OpenAI/WHAM runtime integration.** Move to per-run clients, honor role model/settings, add retries/backoff/timeouts/usage telemetry, and isolate WHAM behind a compatibility adapter with explicit compliance review.
- **P1: Govern MCP and skill execution.** Use a real TOML parser, model MCP/tool permissions in workflow specs, require explicit enablement per role/session, and redact sensitive command/env details from UI/logs.
- **P2: Expand UI control and observability for autonomous workflows.** Add a first-class workflow/run inspector, criteria checklist, diff/artifact browser, per-agent control panel, workflow selection, reconnect/resume UI, and explicit approval prompts for risky tools.

## UX And Product Review Follow-Ups

- **P0: Add real new-session setup.** Include a repo/worktree picker, workflow picker, branch/workspace strategy, auth preflight, and visible confirmation of where agents will write.
- **P0: Surface failures prominently.** Add a persistent session-level status/error banner with request context, recovery action, daemon log link, and last failed operation.
- **P0: Clarify agent controls.** Separate view/filter agent from control target, show `Controlling: <agent>`, and either implement real pause semantics or rename pause to "pause future scheduling."
- **P1: Add a session health inspector.** Show active agents, current prompt/tool, workflow-instance tree, completion criteria progress, blockers, causation chain, and active tool calls.
- **P1: Productize workflow authoring.** Build a structured workflow editor with node/edge/lifecycle/concurrency controls, schema validation, duplicate-from-built-in, dry-run, and readable validation errors.
- **P1: Add per-role readiness.** Show model, credential source, writable roots, MCP servers, skills, command/write permissions, and a "test this role" action.
- **P1: Improve session information architecture.** Add a session dashboard/table with status, last activity, live/debug mode, workspace path, active agents, failure count, and quick actions.
- **P2: Add a Workspace inspector.** Show root path, touched files, diffs, claims/conflicts, git status, open-file buttons, and copy/open workspace actions.
- **P2: Move auth setup into the moment it is needed.** Add inline "Set up OpenAI" from new-session preflight, show OAuth progress, confirm account/source, and block Live creation with an actionable fix.

## Codex App Comparison Follow-Ups

Computer Use could inspect this app, but direct Computer Use access to `com.openai.codex` was blocked by the environment. These follow-ups are based on Codex-style coding-agent features visible from the current desktop context and prior screenshots in this project thread.

- **P1: Add an explicit plan/checklist panel.** Show the orchestrator's current plan as editable/checkable steps with status, owner agent, and links to related transcript events.
- **P1: Add a changed-files and diff review surface.** Summarize touched files in a dedicated panel, open inline diffs from `workspace.file_touched` events, show additions/deletions, and allow copying file paths or diff hunks.
- **P1: Add transcript search and filters.** Search by text, file path, tool name, agent, workflow instance, error, and unread status; provide jump-to-next result and clear active filters.
- **P1: Add command/tool execution details.** For tool calls, show duration, status, working directory, exit code when applicable, raw input/result, and a compact/expanded Codex-style rendering.
- **P1: Add model and effort controls at session start.** Let the user choose a default model/reasoning effort for the session and show inherited role model settings before launch.
- **P2: Add slash-command style composer actions.** Support quick actions such as `/plan`, `/workflow`, `/role`, `/debug`, `/open`, and `/status` that map to existing app panels or daemon requests.
- **P2: Add lightweight approval prompts for risky actions.** Before command execution, MCP calls, or broad file writes, show an inline allow/deny prompt with the requesting agent, reason, and policy scope.
- **P2: Add copy/share/export actions for session artifacts.** Export transcript, event log, debug log, workspace path, and selected diffs from the session UI.
