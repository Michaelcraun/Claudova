# Claudova — WIP

macOS app: chat with Claude (via headless Claude Code) about a 3D design → Claude writes Cadova Swift code → app builds it → in-app 3D preview → iterate.

## Decisions
- LLM backend: Claude Code headless (`claude -p --output-format stream-json`, `--resume` per project)
- Project: Xcode app project generated with xcodegen (sandbox off; needs Swift toolchain + `claude` CLI on the machine)
- Cadova runs in a separate per-project SwiftPM "model workspace", not linked into the app
- Viewer: SceneKit, load 3MF via the `ThreeMF` package (Cadova dependency); STL via Model I/O as a fallback

## Milestones
- [x] M1: Project skeleton — xcodegen `project.yml`, SwiftUI app target, split view (chat | viewer), move current SwiftPM package into a workspace template
- [x] M2: Model workspace — create a per-project workspace from the template (Package.swift + Cadova, `Sources/Model/main.swift`, workspace CLAUDE.md with Cadova guidance); warm the first build (Cadova 1.2 ships a prebuilt xcframework, so a cold `swift run` is only ~15–40 s incl. fetch)
- [x] M3: Viewer — load the .3mf output into SceneKit (orbit camera, grid, mm units), reload when the file changes
- [x] M4: Claude session — headless `claude -p` per turn (stream-json, `--resume`), streaming chat with tool activity, session ID persisted in `.claudova/project.json`; runs in `--safe-mode` with the app supplying CLAUDE.md + Cadova skill via `--append-system-prompt`, and permissions via `--allowedTools` + `dontAsk`
- [x] M5: Build loop — after each Claude turn the app checks whether `Models/model.3mf` is newer than every source; if not it runs `swift run`, and on failure automatically asks Claude to fix it (max 2 attempts per user message, never after a Claude error or Stop). Builds are serialized; chat shows "Checking the build…" and the outcome
- [x] M6: Projects — three-column layout (designs | chat | preview); create (⌘N / +), rename, show in Finder, move to Trash; chat transcript saved to `.claudova/chat.json` and restored per design; switching is blocked while Claude is working

## Later / ideas
- [ ] Designs: auto-name a new design from its first message (e.g. ask Claude for a 2–3 word title) instead of "Untitled Design N"
- [ ] Designs: thumbnail per design in the sidebar (render the viewer to an image after each build)
- [ ] Designs: new designs take ~15–30 s for their first build; try APFS-cloning (`cp -c`) another design's `.build` (shares disk blocks too) — needs checking that SwiftPM tolerates the moved absolute paths
- [ ] Sidebar: relative "opened … ago" dates don't tick while the window is open
- [ ] Build loop: stream `swift run` output into a collapsible log in the chat/toolbar while the app builds (currently only shown on failure)
- [ ] Chat: render block-level Markdown (bullet lists, headings); currently inline-only, so "- " bullets show as plain text
- [ ] Settings: choose the Claude model (`ClaudeClient.model`), show per-turn duration/cost
- [ ] Consider a long-lived `claude` process (`--input-format stream-json`) instead of one process per turn, to cut startup latency
- [ ] Disk usage: each built design has a ~580 MB `.build`; share a build cache across designs or offer "clean" for inactive designs
- [ ] Install Cadova Viewer 1.3.2+ so Claude can use the headless `cadova-viewer` CLI to render/measure its own output (the Cadova skill's verify loop)
- [ ] Viewer: frame the camera using the real view aspect ratio (currently fits to horizontal FOV only)
- [ ] Viewer: part visibility toggles (hide context/visual parts), edge/wireframe overlay, section view
- [ ] Viewer: large meshes are unindexed (3 vertices/triangle) for flat shading; fine so far, revisit if huge models get slow
- [ ] Use CadovaLiveLinkHost to receive meshes directly over a Unix socket (skip the file-reload delay)
- [ ] Export/reveal .3mf/.stl for slicing; open in Cadova Viewer
- [ ] Code panel showing the generated Swift source (read-only or editable)
- [ ] Snapshot/version history per change (git in each workspace) with undo
- [ ] Dimension/measurement overlays in the viewer
