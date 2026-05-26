# Continuous Improvement Concurrency Audit

The continuous-improvement workflow uses the same durable actor model as other workflows:

- Scheduler jobs are append-only `scheduler.job.*` events and are resumable from the session log.
- Actor state is derived from the graph, agent status events, scheduler jobs, and mailbox events.
- `ActorRegistry.startRun` prevents two simultaneous turns for the same mapped agent.
- Mailbox enqueue/dequeue events make pending work reconstructable after restart.
- Workspace writes pass through `WorkspaceCoordinator`, file leases, per-file locks, and conflict rollback.

The built-in `continuous-improvement` workflow deliberately uses separate role IDs for the loop implementor and reviewer:

- `continuous_implementor` owns file writes and command execution.
- `continuous_reviewer` can inspect events, files, and commands but cannot write.
- `todo_generator` can inspect graph/events, read workspace files, and use a bounded sleep tool, but cannot write files, run commands, or create plans.
- Command-capable roles without write permission have command-produced file changes rolled back by the engine.

The loop continues until the TODO generator stops with its required completion criterion, or until the caller stops the workflow with `workflow_stop`. When the TODO generator stops, the engine closes the workflow and cancels any remaining optional loop agents.

Known follow-up for a later milestone: make continuous workflow budgets configurable in `WorkflowSpec` for deployments that want an explicit maximum cycle count.
