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
