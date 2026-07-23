# AgenticNotch — Design Spec

**Date:** 2026-07-23
**Author:** Lucas (lucascurtoo@gmail.com)
**Status:** Approved design, pre-plan

## Summary

Fork of [`TheBoredTeam/boring.notch`](https://github.com/TheBoredTeam/boring.notch)
rebranded to **AgenticNotch**. Adds one feature: the MacBook notch reacts when an
AI coding CLI agent (Claude Code, Codex) finishes a turn — it expands with a live
activity showing the tool, status, and project, and plays a chime. Everything else
in boring.notch stays as-is.

This is the concrete implementation of the previously-scoped "AgenticBar" idea
(notch app that monitors AI agents, local-only) on top of a mature notch codebase.

## Context: upstream state (verified 2026-07-23)

- Not archived. 10.1k stars, 865 forks, GPL-3.0.
- **Last release: `v2.7.3`, 2025-11-24** (~8 months ago).
- `main` receives mostly bot commits (dependabot, copilot CI) + template tweaks.
- 30+ feature PRs open and unmerged (Pomodoro x2, timers, screen time, etc.).
- Conclusion: semi-stalled maintenance. A PR upstream would likely rot.
  → We maintain an independent fork, pulling upstream when useful.

## Goals

- Notify in the notch when a CLI agent finishes: **Claude Code** and **Codex**.
- Distinguish which run finished (project label) for users running multiple agents.
- Success vs error signalling (color).
- Optional chime.
- User-configurable (enable, sound, auto-collapse duration).

## Non-goals (YAGNI — add later if needed)

- IDE agents (Cursor, etc.) — no reliable "done" signal.
- Run history / log of past completions.
- Click-to-focus-terminal.
- Multi-machine / networked sync.
- Per-tool / per-project notification filtering (settings hook left for later).

## Architecture

Three decoupled pieces. Each understandable and testable on its own.

### 1. Detection glue (lives outside the app)

The CLI agents already emit a "turn complete" signal. We attach a shell command
to it. No code runs inside the agents.

**Claude Code** — `Stop` hook in `~/.claude/settings.json` calls a shared script.

**Codex** — `notify` program in `~/.codex/config.toml` calls the same script.
Codex passes a JSON payload as argv; the script reads `tool=codex`, extracts what
it needs, ignores the rest.

**Shared script** — `scripts/agenticnotch-notify` (shipped in the repo):
- Inputs: `--tool`, `--status`, optional `--project` (defaults to `basename "$PWD"`),
  optional `--title`.
- Action: `open -g "agenticnotch://done?tool=…&status=…&project=…&title=…"`
  (URL-encoded).
- `open -g` launches/wakes the app **without stealing focus**.

Interface contract: the script's only output that matters is the `open` invocation
of a well-formed `agenticnotch://done` URL.

### 2. Transport — custom URL scheme

- `Info.plist`: register `CFBundleURLTypes` with scheme **`agenticnotch`**.
- `AppDelegate` implements `application(_:open urls:)`:
  parse each URL, validate host == `done`, read query items
  `tool`, `status`, `project`, `title`, then call the coordinator on the main actor.
- Bad/unknown URLs are ignored (no crash, logged via existing `Logger`).

Why URL scheme over HTTP/file-watch: zero embedded server, no port management, no
network stack, native macOS routing. The whole transport is parse + dispatch.

### 3. UI — Agent live activity (reuses existing notch machinery)

boring.notch already has a sneak-peek / live-activity system in
`BoringViewCoordinator` (`SneakContentType` enum, `sneakPeek`/`ExpandedItem` structs,
`DispatchWorkItem`-based auto-hide) and a `components/Live activities/` folder of
view modifiers. We extend that pattern rather than invent a new one.

- Add `SneakContentType.agentDone` (with an associated payload struct
  `AgentActivityInfo { tool, status, project, title }`).
- Add `BoringViewCoordinator.showAgentActivity(_:)`:
  sets the published state, shows the notch, schedules auto-collapse via
  `DispatchWorkItem` after `Defaults[.agentAutoCollapseSeconds]` (default 4),
  and — if enabled — plays the chime via `helpers/AudioPlayer.swift`.
- New view `AgentActivityView` in `components/Live activities/`:
  tool icon + `"<Tool> terminó · <project>"` + accent color
  **green = ok / red = error**. Rendered by the same expanded/notch container that
  renders the other live activities.

Multiple concurrent agents: each completion carries its own `project`, so the label
tells the user which run finished. Rapid successive completions replace the current
activity (latest wins) — same behavior as existing sneak peeks.

### 4. Settings

New "Agents" tab in `components/Settings/SettingsView.swift`:
- Master enable toggle → `Defaults[.agentNotifyEnabled]` (default true).
- Sound enable toggle + sound picker → `Defaults[.agentSoundEnabled]`, `Defaults[.agentSoundName]`.
- Auto-collapse seconds stepper → `Defaults[.agentAutoCollapseSeconds]` (default 4).

Follows the existing `sindresorhus/Defaults` + `@AppStorage` conventions already in
`BoringViewCoordinator`.

## Rebranding checklist (fork setup)

- Rename product/target display name to **AgenticNotch**.
- New bundle identifier (e.g. `com.lucas.agenticnotch`) so it can coexist with an
  installed boring.notch.
- New URL scheme `agenticnotch` (also update anywhere `boringnotch://` may exist).
- App icon (later — not blocking).
- **Keep** `LICENSE` (GPL-3.0) and source-file attribution headers. Add a NOTICE
  crediting TheBoringNotch as the upstream. Rebranding the product name/icon is fine
  under GPL; removing authorship/license is not.
- `git remote add upstream https://github.com/TheBoredTeam/boring.notch.git` for pulls.

## Data flow (end to end)

```
Claude Code / Codex finishes turn
  → Stop hook / notify program
  → scripts/agenticnotch-notify --tool … --status … --project …
  → open -g "agenticnotch://done?tool=…&status=…&project=…"
  → macOS routes to AgenticNotch
  → AppDelegate.application(_:open:) parses URL
  → BoringViewCoordinator.showAgentActivity(info)
  → notch expands (AgentActivityView) + optional chime
  → auto-collapse after N seconds
```

## Error handling

- Malformed / unknown URLs → ignored + logged, never crash.
- Missing `project` → fall back to empty label (activity still shows tool+status).
- Missing `status` → treat as `ok`.
- Notifications disabled in settings → URL parsed but no activity shown.
- Chime failure (missing sound) → silent, activity still shows.

## Testing / verification

- **Transport unit test:** URL parser maps
  `agenticnotch://done?tool=claude&status=error&project=gcu-api` →
  `AgentActivityInfo(tool: "claude", status: .error, project: "gcu-api")`;
  malformed URLs return nil. (Pure function, no UI.)
- **Glue self-check:** `scripts/agenticnotch-notify --tool claude --status ok`
  run manually pops the notch — smallest end-to-end manual check.
- **Coordinator behavior:** `showAgentActivity` sets state and schedules collapse;
  verify auto-collapse timer fires and clears state.

## Open questions / deferred

- App icon design — deferred, non-blocking.
- Codex `notify` exact JSON shape — confirm against installed Codex version during
  implementation; the script tolerates extra fields.
