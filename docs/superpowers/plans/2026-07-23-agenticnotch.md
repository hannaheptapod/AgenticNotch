# AgenticNotch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fork `TheBoredTeam/boring.notch` as **AgenticNotch** and make the notch expand with a live activity + chime when a CLI AI agent (Claude Code, Codex) finishes a turn.

**Architecture:** A shared shell script attaches to each agent's completion hook and fires an `agenticnotch://done?...` URL. The app registers that URL scheme, parses it in `AppDelegate`, and calls `BoringViewCoordinator.showAgentActivity(_:)`, which reuses the existing sneak-peek/expanding-view pattern (published state + `didSet` auto-hide) to show `AgentActivityView` and optionally play an `NSSound`.

**Tech Stack:** Swift 5 / SwiftUI, AppKit, `sindresorhus/Defaults`, Xcode project (`boringNotch.xcodeproj`), macOS 14+.

## Global Constraints

- macOS **14 Sonoma+**, Apple Silicon or Intel. (verbatim from upstream README)
- License stays **GPL-3.0**; keep `LICENSE` and per-file attribution headers; add a NOTICE crediting TheBoringNotch.
- No new SPM dependencies. Chime uses system `NSSound(named:)` — no bundled audio asset.
- URL scheme is exactly **`agenticnotch`**; completion URLs are `agenticnotch://done?tool=&status=&project=&title=`.
- New bundle identifier **`com.lucas.agenticnotch`** (coexists with an installed boring.notch).
- Follow existing conventions: Defaults keys in `boringNotch/models/Constants.swift` (`extension Defaults.Keys`), `@MainActor` on coordinator mutations, `withAnimation(.smooth)` for notch state changes.
- `open -g` (background, no focus steal) is the only way the glue invokes the app.
- No XCTest target exists in the repo. Do **not** hand-edit `project.pbxproj` to add one. The pure parser ships a `#if DEBUG` assert self-check run at launch.

---

### Task 1: Fork, clone, rebrand, baseline build

**Files:**
- Create/replace: whole repo at `/Users/globalcontact/Proyectos/AgenticNotch`
- Modify (via Xcode GUI): target display name, `PRODUCT_BUNDLE_IDENTIFIER`, URL Types
- Create: `NOTICE`

**Interfaces:**
- Produces: a buildable Xcode project whose app registers the `agenticnotch` URL scheme; the spec/plan docs preserved under `docs/superpowers/`.

- [ ] **Step 1: Fork on GitHub**

```bash
gh repo fork TheBoredTeam/boring.notch --fork-name AgenticNotch --clone=false
```
Expected: prints the new fork `<your-user>/AgenticNotch`.

- [ ] **Step 2: Preserve the planning docs, then clone the fork into place**

```bash
cd /Users/globalcontact/Proyectos
mv AgenticNotch AgenticNotch.planning        # local spec/plan repo, keep aside
gh repo clone <your-user>/AgenticNotch AgenticNotch
cp -R AgenticNotch.planning/docs AgenticNotch/docs
rm -rf AgenticNotch.planning
cd AgenticNotch
git remote add upstream https://github.com/TheBoredTeam/boring.notch.git
```
Expected: `AgenticNotch/` is the forked repo with `docs/superpowers/{specs,plans}/...` present and an `upstream` remote.

- [ ] **Step 3: Find the scheme and confirm a clean baseline build**

```bash
xcodebuild -list -project boringNotch.xcodeproj
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. (Note the exact scheme name printed; use it for every later build step.)

- [ ] **Step 4: Rebrand in Xcode (GUI)**

Open `boringNotch.xcodeproj`, select the app target → **General**: set Display Name to `AgenticNotch`. → **Signing & Capabilities**/**Build Settings**: set `PRODUCT_BUNDLE_IDENTIFIER` to `com.lucas.agenticnotch`. → **Info** → **URL Types**: add one with **Identifier** `com.lucas.agenticnotch`, **URL Schemes** `agenticnotch`, Role `Viewer`.

- [ ] **Step 5: Add attribution NOTICE**

Create `NOTICE`:
```
AgenticNotch is a fork of TheBoringNotch (boring.notch)
https://github.com/TheBoredTeam/boring.notch
Licensed under GPL-3.0. Original copyright retained in source headers.
```

- [ ] **Step 6: Rebuild and verify the scheme is registered**

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
# Launch the built .app once (Finder or `open`), then:
open -g "agenticnotch://done?tool=claude&status=ok&project=test"
```
Expected: `BUILD SUCCEEDED`; the second command does **not** error with "no application knows how to open URL" (nothing visible yet — handler comes in Task 5).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore: rebrand fork to AgenticNotch, register agenticnotch URL scheme

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: AgentActivityInfo model + URL parser (pure, self-checked)

**Files:**
- Create: `boringNotch/models/AgentActivityInfo.swift`
- Modify: `boringNotch/boringNotchApp.swift` (call self-check at launch, DEBUG only)

**Interfaces:**
- Produces:
  - `enum AgentStatus: String { case ok, error }`
  - `struct AgentActivityInfo: Equatable { var tool: String; var status: AgentStatus; var project: String; var title: String; var toolDisplayName: String; static func from(url: URL) -> AgentActivityInfo? }`

- [ ] **Step 1: Create the model + parser + self-check**

`boringNotch/models/AgentActivityInfo.swift`:
```swift
//
//  AgentActivityInfo.swift
//  AgenticNotch (fork of boring.notch, GPL-3.0)
//

import Foundation

enum AgentStatus: String {
    case ok
    case error
}

struct AgentActivityInfo: Equatable {
    var tool: String          // "claude", "codex", ...
    var status: AgentStatus
    var project: String       // basename of the agent's cwd; may be ""
    var title: String         // optional extra line; may be ""

    /// Parse an `agenticnotch://done?...` URL. Returns nil for anything else.
    static func from(url: URL) -> AgentActivityInfo? {
        guard url.scheme == "agenticnotch", url.host == "done" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String { items.first(where: { $0.name == name })?.value ?? "" }
        let tool = q("tool")
        guard !tool.isEmpty else { return nil }
        let status = AgentStatus(rawValue: q("status")) ?? .ok
        return AgentActivityInfo(tool: tool, status: status, project: q("project"), title: q("title"))
    }

    var toolDisplayName: String {
        switch tool.lowercased() {
        case "claude": return "Claude"
        case "codex":  return "Codex"
        default:       return tool.capitalized
        }
    }

    #if DEBUG
    static func runSelfCheck() {
        assert(from(url: URL(string: "agenticnotch://done?tool=claude&status=error&project=gcu-api")!)
               == AgentActivityInfo(tool: "claude", status: .error, project: "gcu-api", title: ""))
        assert(from(url: URL(string: "agenticnotch://done?tool=codex")!)?.status == .ok)
        assert(from(url: URL(string: "agenticnotch://done?status=ok")!) == nil)          // no tool
        assert(from(url: URL(string: "agenticnotch://other?tool=x")!) == nil)            // wrong host
        assert(from(url: URL(string: "https://example.com")!) == nil)                    // wrong scheme
    }
    #endif
}
```

- [ ] **Step 2: Add the new file to the app target**

In Xcode, drag `AgentActivityInfo.swift` into the `models` group and confirm the app target checkbox is ticked (or it won't compile in).

- [ ] **Step 3: Run the self-check at launch (DEBUG)**

In `boringNotch/boringNotchApp.swift`, inside `AppDelegate` add an `applicationDidFinishLaunching` hook (create it if absent) with:
```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    #if DEBUG
    AgentActivityInfo.runSelfCheck()
    #endif
}
```
If `applicationDidFinishLaunching` already exists, add the `#if DEBUG ... #endif` block at its top instead.

- [ ] **Step 4: Build (Debug) — self-check must not trap**

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`. Launch the Debug app once; it must not crash on an `assert` (that would mean the parser is wrong).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add AgentActivityInfo URL parser with DEBUG self-check

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Defaults keys for the Agents feature

**Files:**
- Modify: `boringNotch/models/Constants.swift` (inside `extension Defaults.Keys`)

**Interfaces:**
- Produces Defaults keys: `.agentNotifyEnabled: Bool`, `.agentSoundEnabled: Bool`, `.agentSoundName: String`, `.agentAutoCollapseSeconds: Double`.

- [ ] **Step 1: Add the keys**

In `boringNotch/models/Constants.swift`, find `extension Defaults.Keys {` and add before its closing `}`:
```swift
    // MARK: Agents
    static let agentNotifyEnabled = Key<Bool>("agentNotifyEnabled", default: true)
    static let agentSoundEnabled = Key<Bool>("agentSoundEnabled", default: true)
    static let agentSoundName = Key<String>("agentSoundName", default: "Glass")
    static let agentAutoCollapseSeconds = Key<Double>("agentAutoCollapseSeconds", default: 4)
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: add Defaults keys for agent notifications

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Coordinator — agent activity state, show method, auto-collapse, chime

**Files:**
- Modify: `boringNotch/BoringViewCoordinator.swift`

**Interfaces:**
- Consumes: `AgentActivityInfo` (Task 2); Defaults keys (Task 3).
- Produces:
  - `struct AgentActivityState { var show: Bool; var info: AgentActivityInfo }`
  - `BoringViewCoordinator.agentActivity: AgentActivityState` (`@Published`)
  - `BoringViewCoordinator.showAgentActivity(_ info: AgentActivityInfo)`

- [ ] **Step 1: Add the state struct**

In `boringNotch/BoringViewCoordinator.swift`, after the `struct ExpandedItem { ... }` definition add:
```swift
struct AgentActivityState {
    var show: Bool = false
    var info: AgentActivityInfo = AgentActivityInfo(tool: "", status: .ok, project: "", title: "")
}
```

- [ ] **Step 2: Add published state with auto-collapse + the show method**

Inside `class BoringViewCoordinator`, after the `expandingView` published property's closing (just before `func showEmpty()`), add:
```swift
    private var agentActivityTask: Task<Void, Never>?

    @Published var agentActivity = AgentActivityState() {
        didSet {
            if agentActivity.show {
                agentActivityTask?.cancel()
                let seconds = Defaults[.agentAutoCollapseSeconds]
                agentActivityTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    guard let self, !Task.isCancelled else { return }
                    await MainActor.run {
                        withAnimation(.smooth) { self.agentActivity.show = false }
                    }
                }
            } else {
                agentActivityTask?.cancel()
            }
        }
    }

    func showAgentActivity(_ info: AgentActivityInfo) {
        guard Defaults[.agentNotifyEnabled] else { return }
        Task { @MainActor in
            withAnimation(.smooth) {
                self.agentActivity.info = info
                self.agentActivity.show = true
            }
        }
        if Defaults[.agentSoundEnabled] {
            NSSound(named: NSSound.Name(Defaults[.agentSoundName]))?.play()
        }
    }
```
(`NSSound` comes from `AppKit`, already imported at the top of this file.)

- [ ] **Step 3: Build**

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: coordinator agent activity state with auto-collapse and chime

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: URL handling in AppDelegate

**Files:**
- Modify: `boringNotch/boringNotchApp.swift` (`AppDelegate`)

**Interfaces:**
- Consumes: `AgentActivityInfo.from(url:)` (Task 2), `BoringViewCoordinator.showAgentActivity` (Task 4).

- [ ] **Step 1: Handle incoming URLs**

In `AppDelegate` add:
```swift
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let info = AgentActivityInfo.from(url: url) else {
                NSLog("AgenticNotch: ignored URL \(url.absoluteString)")
                continue
            }
            Task { @MainActor in
                BoringViewCoordinator.shared.showAgentActivity(info)
            }
        }
    }
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Manual behavior check (state, not yet UI)**

Launch the app. Run:
```bash
open -g "agenticnotch://done?tool=claude&status=ok&project=gcu-api"
```
Expected: Console.app shows no "ignored URL" line for this URL, and (if `agentSoundEnabled`) the Glass chime plays. The visual activity arrives in Task 6.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: route agenticnotch:// URLs to the coordinator

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: AgentActivityView + render wiring in the closed notch

**Files:**
- Create: `boringNotch/components/Live activities/AgentActivityView.swift`
- Modify: `boringNotch/ContentView.swift` (closed-notch content builder, ~lines 285–305)

**Interfaces:**
- Consumes: `BoringViewCoordinator.agentActivity` (Task 4).

- [ ] **Step 1: Create the view**

`boringNotch/components/Live activities/AgentActivityView.swift`:
```swift
//
//  AgentActivityView.swift
//  AgenticNotch (fork of boring.notch, GPL-3.0)
//

import SwiftUI

struct AgentActivityView: View {
    let info: AgentActivityInfo

    private var accent: Color { info.status == .ok ? .green : .red }
    private var icon: String { info.status == .ok ? "checkmark.circle.fill" : "xmark.octagon.fill" }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(accent)
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(info.toolDisplayName) terminó")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                if !info.project.isEmpty {
                    Text(info.project)
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }
}
```
Add it to the app target in Xcode.

- [ ] **Step 2: Read ContentView to locate the closed-notch content builder**

Open `boringNotch/ContentView.swift`. Find the `if/else if` chain that decides closed-notch content — the branch at (about) line 287 begins:
`} else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && ...`
and the block just above it renders the notch's closed content. Note the exact indentation.

- [ ] **Step 3: Add the agent branch as the highest-priority closed-notch content**

Immediately BEFORE that `else if coordinator.sneakPeek.show && Defaults[.inlineHUD] ...` branch, insert a new leading branch (convert the following `if` to `else if` if needed so the chain stays valid — the agent branch becomes the first `if`):
```swift
                      if coordinator.agentActivity.show && vm.notchState == .closed {
                          AgentActivityView(info: coordinator.agentActivity.info)
                              .transition(.opacity)
                      } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
```
(The second line above is the pre-existing branch; keep its body unchanged. Only the two new lines + turning the original `if`→`else if`? No: the original chain already starts higher up. If the pre-existing line already starts with `} else if`, insert your `if coordinator.agentActivity.show ...` block as a sibling branch by matching the surrounding builder structure. The goal: when `agentActivity.show` is true and the notch is closed, `AgentActivityView` renders instead of music/HUD.)

- [ ] **Step 4: Build**

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Manual end-to-end (visual)**

Launch the app. Run each and watch the notch:
```bash
open -g "agenticnotch://done?tool=claude&status=ok&project=gcu-api"
open -g "agenticnotch://done?tool=codex&status=error&project=gcu-web"
```
Expected: notch shows "Claude terminó / gcu-api" with a green check, then "Codex terminó / gcu-web" with a red mark; each auto-collapses after ~4s; chime plays.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: render AgentActivityView in the closed notch

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Settings — "Agents" tab

**Files:**
- Modify: `boringNotch/components/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: Defaults keys (Task 3).

- [ ] **Step 1: Add the sidebar link**

In `SettingsView.body`, in the `List(selection: $selectedTab)`, add after the `HUD` link:
```swift
                NavigationLink(value: "Agents") {
                    Label("Agents", systemImage: "sparkles")
                }
```

- [ ] **Step 2: Add the switch case**

In the `switch selectedTab` block, add before `default:`:
```swift
                case "Agents":
                    AgentsSettings()
```

- [ ] **Step 3: Add the settings view + AppKit import**

Ensure `import AppKit` is present at the top of the file (needed for `NSSound`). Then add this struct at file scope (bottom of the file):
```swift
struct AgentsSettings: View {
    @Default(.agentSoundEnabled) var soundEnabled
    @Default(.agentSoundName) var soundName
    @Default(.agentAutoCollapseSeconds) var autoCollapse

    private let systemSounds = ["Glass", "Ping", "Pop", "Blow", "Bottle", "Frog",
                                "Funk", "Hero", "Morse", "Purr", "Sosumi", "Submarine", "Tink"]

    var body: some View {
        Form {
            Section {
                Defaults.Toggle("Notify when an AI agent finishes", key: .agentNotifyEnabled)
            } footer: {
                Text("Wire your agents with scripts/agenticnotch-notify (see README).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Sound") {
                Defaults.Toggle("Play a sound", key: .agentSoundEnabled)
                Picker("Sound", selection: $soundName) {
                    ForEach(systemSounds, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!soundEnabled)
                Button("Preview") { NSSound(named: NSSound.Name(soundName))?.play() }
                    .disabled(!soundEnabled)
            }
            Section("Timing") {
                Stepper("Auto-collapse after \(Int(autoCollapse))s",
                        value: $autoCollapse, in: 1...15)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Agents")
    }
}
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Manual check**

Open Settings → "Agents". Toggle notifications off, fire `open -g "agenticnotch://done?tool=claude&status=ok"` → no activity. Toggle on → activity shows. Change sound + Preview plays it. Change auto-collapse to 1s → next activity collapses faster.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add Agents settings tab (enable, sound, auto-collapse)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Glue script + agent config docs + full e2e

**Files:**
- Create: `scripts/agenticnotch-notify`
- Modify: `README.md` (add an "AgenticNotch: agent notifications" section)

**Interfaces:**
- Consumes: the `agenticnotch://done` scheme (whole app).

- [ ] **Step 1: Create the notify script**

`scripts/agenticnotch-notify`:
```bash
#!/usr/bin/env bash
# agenticnotch-notify — poke AgenticNotch when an AI CLI agent finishes.
# Usage: agenticnotch-notify --tool claude --status ok [--project NAME] [--title TEXT]
# Unknown trailing args (e.g. Codex's JSON payload) are ignored.
set -euo pipefail
tool=""; status="ok"; project="$(basename "$PWD")"; title=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tool)    tool="${2:-}"; shift 2 ;;
    --status)  status="${2:-}"; shift 2 ;;
    --project) project="${2:-}"; shift 2 ;;
    --title)   title="${2:-}"; shift 2 ;;
    *)         shift ;;
  esac
done
enc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "${1:-}"; }
url="agenticnotch://done?tool=$(enc "$tool")&status=$(enc "$status")&project=$(enc "$project")&title=$(enc "$title")"
open -g "$url"
```
Then:
```bash
chmod +x scripts/agenticnotch-notify
```

- [ ] **Step 2: Script self-check (smallest e2e)**

Launch the app, then:
```bash
./scripts/agenticnotch-notify --tool claude --status ok --project manual-test
```
Expected: notch shows "Claude terminó / manual-test".

- [ ] **Step 3: Document agent wiring in README**

Add to `README.md`:
````markdown
## AgenticNotch — agent notifications

The notch reacts when a CLI AI agent finishes a turn.

**Claude Code** — add to `~/.claude/settings.json` (use the absolute path to the script):
```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
        "command": "/Users/globalcontact/Proyectos/AgenticNotch/scripts/agenticnotch-notify --tool claude --status ok" } ] }
    ]
  }
}
```
`project` defaults to the basename of the hook's working directory.

**Codex** — add to `~/.codex/config.toml`:
```toml
notify = ["/Users/globalcontact/Proyectos/AgenticNotch/scripts/agenticnotch-notify", "--tool", "codex", "--status", "ok"]
```
Codex appends a JSON event payload as a trailing argument; the script ignores it.
````

- [ ] **Step 4: Full end-to-end with a real Claude Code Stop hook**

Add the Stop hook above to `~/.claude/settings.json`, run any short `claude` task in a project dir, and confirm the notch shows "Claude terminó / <that project>" when the turn ends.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add agenticnotch-notify glue script and agent wiring docs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Fork + rebrand + GPL/attribution → Task 1 (+ NOTICE).
- Detection glue (Claude Stop hook, Codex notify) → Task 8.
- URL-scheme transport + parse → Tasks 1 (register), 2 (parse), 5 (route).
- Notch expand + status color + project label → Tasks 4, 6.
- Chime → Task 4 (play) + Task 7 (config).
- Settings (enable/sound/auto-collapse) → Tasks 3 (keys) + 7 (UI).
- Multi-agent disambiguation via `project` → covered by `AgentActivityInfo.project` end to end.
- Error handling (bad URL ignored, missing fields defaulted) → Task 2 parser + Task 5 guard.

**Deviations from spec (intentional):**
- No `SneakContentType.agentDone` case: the render keys off a dedicated `agentActivity` state, so the enum case would be dead. Simpler; noted here.
- Chime uses `NSSound(named:)` (system sounds) instead of `helpers/AudioPlayer.swift` (which force-unwraps a bundled file we'd have to ship). No new asset, configurable.
- No XCTest target (none exists upstream); the pure parser is covered by a DEBUG launch-time assert self-check.

**Deferred (per spec non-goals):** IDE agents, run history, click-to-focus, networked sync, per-tool/project filtering. Claude Stop hook always sends `status=ok` for now (the error path is wired and reachable, e.g. Codex or a future hook that inspects results).

**Placeholder scan:** none — every code step contains full code.
**Type consistency:** `AgentActivityInfo`/`AgentStatus`/`AgentActivityState`/`showAgentActivity`/`agentActivity` used identically across Tasks 2, 4, 5, 6, 7.
