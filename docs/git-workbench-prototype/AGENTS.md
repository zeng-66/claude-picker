# Prototype Instructions

Run the local server yourself and open the preview in the browser available to this environment. Do not give the user server-start instructions when you can run it.

Before making substantial visual changes, use the Product Design plugin's `get-context` skill when the visual source is unclear or no longer matches the current goal. When the user gives durable prototype-specific design feedback, preferences, or decisions, record them in `AGENTS.md`.

When implementing from a selected generated mock, treat that image as the source of truth for layout, component anatomy, density, spacing, color, typography, visible content, and hierarchy.

Build app UI in `src/`. Keep `.openai/hosting.json`, `worker/index.js`, `scripts/prepare-sites-build.mjs`, and `tests/sites-worker.test.mjs` intact so the same local prototype can be handed to Sites. Before a Sites handoff, run `npm run build` and `npm run test:sites`; the build must leave `dist/client/index.html`, `dist/server/index.js`, and `dist/.openai/hosting.json`.

## Third-pane tools

- The third pane contains a tool switch for Git workspace and file preview.
- File preview covers Markdown rendered/source, images with zoom, code/JSON with line numbers, CSV table/source, and a PDF document layout.
- Keep the first two panes (project sessions and terminal) visible while changing the third-pane tool.
- File preview has two scope tabs. “全部文件” shows the project tree with expand-all/collapse-all controls and Git status colors. “变更文件” shows only changed paths grouped into unstaged and staged.
- Status colors are shared across both views. Unstaged is amber, staged green, deleted red, and untracked blue. A file row includes both color and a status letter for accessibility.
- Selecting a changed file opens Diff by default in the shared preview panel. The same preview panel includes a file-preview toggle so both file scopes behave identically.
- Markdown supports live rendered editing and fenced Mermaid diagrams. Standalone `.mmd` files support Mermaid flowcharts, ER diagrams and sequence diagrams.
- Editable text formats include Markdown, Mermaid, HTML, code, JSON, YAML and CSV. Editing uses a split editor/live-preview workspace; code and JSON preview keeps synchronized line numbers, CSV preview updates as a table, and HTML previews in a script-enabled isolated iframe.
- Image and PDF files remain read-only. Edits in this prototype persist only in browser memory.

## Project context and terminal collapse

- Project selection belongs at the top of the left changed-files column in the Git workspace. It controls the active Git branch, changed-file set, push state, and the file tree used by file preview.
- The shared third-pane switcher only changes between Git workspace and file preview and shows the selected project as context.
- The terminal pane has a title-bar collapse action. Collapsed mode uses a 44px vertical rail with an explicit expand action, and the third pane expands into the freed space.
- Branch management exposes a Create Session entry with two modes. “基于当前分支” uses the project root as the working directory. Worktree mode creates its working directory under the current project at `.worktrees/<slug>` and keeps the new session attached to the current project.
- Session creation must show the project root, working directory, base branch, and target branch before submission. Both modes insert the created session under the selected project in the first pane.
