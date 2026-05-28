# The Software Factory

The Software Factory is a multiagent coding workflow engine, inspired by this post: https://x.com/simonlast/status/2057978156183957995

Principles:
- LLMs are lazy: they take shortcuts, leave stuff unimplemented, don't properly QA 
- If agents are specifically tasks with finding those issues, they are pretty good at it
- Humans have become factory designers, with their time best spent observing agent systems run and making improvements at the meta level as necessary   

Prior art is either overly complex (Gas Town) or not structured enough (existing coding agents), making multi-agent sessions beyond "spawn a subagent to do x" unnatural or difficult to manage. Here, these concepts are made first class, and natural for the orchestrator agent to fall into:

- Create long-lived agents with **roles**
- They **hand off** output to other **agents**, or nudge those agents with messages 
- All of this is observable, represented as **workflows**
- All you have to do is give a prompt (just like a normal coding agent prompt) to the **orchestrator**, and it will handle the rest
- Workflows are hard-coded into the app, but planner agents decide how and when to instantiate them
- Everything runs autonomously, but you retain control: with the ability to nudge or stop agents at any point

<img width="1586" alt="The Software Factory macOS app showing a concurrent multi-agent timeline and workflow graph" src="docs/image.png" />

## Project Structure

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
npm run dev:node -w @software-factory/daemon # fallback when Bun is unavailable
./script/build_and_run.sh
```

The daemon is Bun-targeted. This checkout also keeps service code testable under Node for local validation when Bun is not installed.
