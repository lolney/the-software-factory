# WHAM Compatibility Review

The daemon treats ChatGPT WHAM as a compatibility transport for Codex OAuth sessions, not as the primary provider abstraction.

## Boundary

- `OpenAIAgentRuntime` selects a provider adapter per run.
- `AgentsSdkRuntimeAdapter` owns normal `@openai/agents` execution.
- `WhamCompatibilityAdapter` owns WHAM `/responses` requests, SSE parsing, retry/backoff, timeout handling, and usage telemetry.
- Workflow tools are built once by the engine and passed into either adapter; provider-specific request details do not leak back into `SessionManager`.
- The Agents SDK adapter passes a per-run `OpenAIProvider` through `run(..., { modelProvider })`; it does not mutate the process-global OpenAI client.

## Current Compliance Notes

- WHAM is only selected when the authenticated connection base URL includes `/wham`.
- Requests set `store: false`.
- OAuth headers, including `ChatGPT-Account-Id` when available, are supplied by `AuthManager`; the adapter does not synthesize account identity.
- WHAM output is normalized into the same `SessionEvent` transcript shape as the Agents SDK path.
- The adapter records model, reasoning effort, usage, retry attempts, and request duration in the final `agent.message` payload when available.

## Follow-Up Triggers

Review this boundary before adding new WHAM-only request fields, changing OAuth header handling, or exposing provider-specific behavior to workflow tools.
