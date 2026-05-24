# Multiagent Coding Workflow Engine

Greenfield local alpha for a multiagent coding workflow engine:

- SwiftUI macOS desktop app in `apps/mac`
- Bun/TypeScript daemon in `apps/daemon`
- Shared Zod schemas and protocol types in `packages/shared`
- Append-only session logs under `sessions/<sessionId>/`

## Development

```sh
npm install
npm run typecheck
npm test
npm run daemon
npm run dev:node -w @multiagent/daemon # fallback when Bun is unavailable
./script/build_and_run.sh
```

The daemon is Bun-targeted. This checkout also keeps service code testable under Node for local validation when Bun is not installed.
