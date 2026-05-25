# Code Graphs

This directory contains Graphviz architecture diagrams for the two main code areas:

- `daemon-architecture.dot`: Bun/TypeScript daemon services, persistence, auth, workflow execution, and Agents SDK integration.
- `app-architecture.dot`: SwiftUI macOS app scenes, views, state store, daemon websocket client, and local daemon launcher.

Render them with Graphviz:

```sh
dot -Tsvg docs/daemon-architecture.dot -o docs/daemon-architecture.svg
dot -Tsvg docs/app-architecture.dot -o docs/app-architecture.svg
```
