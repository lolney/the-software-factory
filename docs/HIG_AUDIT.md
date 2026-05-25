# macOS HIG Audit

Reference: https://developer.apple.com/design/human-interface-guidelines

Date: 2026-05-25

## Summary

The app is already close to native macOS structure: it uses a `WindowGroup`, `NavigationSplitView`, a sidebar, settings as a separate scene, native forms, toolbar controls, confirmation dialogs, and semantic SwiftUI styling. The audit found small convention gaps rather than a need for a broad redesign.

## Getting Started

- Alignment: The app has a clear productivity-oriented structure: sessions in the sidebar, work in the center, inspectors on the right, and settings separated from the main workflow.
- Correction: Changed the primary window title from the app name to the current content area, `Sessions`, which better matches macOS window-title conventions.

## Foundations

- Layout and hierarchy: The app uses persistent sidebars and split views for dense workflow state, which fits a Mac productivity app.
- Color and materials: Role colors are used as semantic accents for agents and messages; most surfaces use system materials or semantic colors.
- Typography and SF Symbols: The app relies on native text styles and symbols. No correction needed.

## Patterns

- Navigation: Sidebar sections for menu destinations and sessions match macOS source-list patterns. The session ordering remains creation-time stable from prior fixes.
- Settings: Settings are presented in a dedicated settings scene with separate panes for daemon, auth, MCP servers, and skills. No correction needed.
- Feedback: Agent stopping is destructive state change, so its UI now says `Stop Agent` instead of `Cancel Agent` and presents an explicit destructive confirmation.
- Opening follow-up UI: Actions that lead to additional input or external setup now use ellipses, including `New Session...`, OpenAI OAuth `Set Up...`, and MCP `Authenticate...`.

## Components

- Toolbars: The toolbar uses system buttons, labels, menus, and status placement. Correction: added help text to key toolbar controls so icon-heavy actions remain discoverable.
- Buttons and menus: Destructive buttons use destructive roles. Setup/authentication buttons now use ellipses where they launch another flow.
- Sidebars and lists: Sidebar rows remain compact and source-list-like. No correction needed.
- Forms: Settings use grouped forms and native field controls. No correction needed.
- Empty states: Existing `ContentUnavailableView` usage matches macOS expectations. No correction needed.

## Inputs

- Pointer and keyboard: Core commands are button/menu accessible, with Command-N for session creation. No correction needed in this pass.
- Accessibility: Correction: graph node hit targets now expose status, unread counts, error counts, and control-agent state through accessibility labels rather than only saying "Select <agent>".

## Technologies

- Privacy and file access: The app stores durable data under Application Support and avoids Documents/Downloads migration prompts from prior fixes. No correction needed in this pass.
- Authentication and integrations: OAuth, API key, account id, and MCP controls are in Settings with reconnect/refresh actions. Correction: added clearer help text for auth and integration controls.

## Platforms

- macOS: The app follows Mac conventions by keeping the sidebar visible, supporting a separate settings window, using menu commands, and providing inspector-style right-side panels.
- Other Apple platforms are not targets for this app.
