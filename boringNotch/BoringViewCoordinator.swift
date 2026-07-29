//
//  BoringViewCoordinator.swift
//  boringNotch
//
//  Created by Alexander on 2024-11-20.
//

import AppKit
import Combine
import Defaults
import Security
import SwiftUI

// MARK: - Agent activity (AgenticNotch)

enum AgentStatus: String {
    case ok
    case error
}

/// Brings the app behind an agent run to the front. Shared by the live
/// notification card and the run-history rows.
enum AgentAppLauncher {
    /// Desktop app that owns this tool, if any.
    static func desktopAppBundleID(for tool: String) -> String? {
        switch tool.lowercased() {
        case "claude": return "com.anthropic.claudefordesktop"
        case "codex":  return "com.openai.codex"          // ChatGPT.app
        default:       return nil
        }
    }

    /// Prefers the tool's desktop app (Claude / ChatGPT); falls back to the
    /// app the agent ran in (terminal, editor) when there is no desktop app
    /// for the tool or it isn't installed.
    ///
    /// Only ever *activates* an already-running app — never re-opens one.
    /// Re-opening a running app makes some terminals (iTerm2) spawn a fresh
    /// empty window. A desktop app that is installed but not running is
    /// launched, since that has no such side effect.
    static func activate(tool: String, sourceApp: String) {
        if let desktop = desktopAppBundleID(for: tool) {
            if activateRunning(desktop) { return }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: desktop) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config)
                return
            }
        }
        activateRunning(sourceApp)
    }

    /// Activate a running app by bundle id. Returns false if it isn't running.
    @discardableResult
    static func activateRunning(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty,
              let running = NSWorkspace.shared.runningApplications
                  .first(where: { $0.bundleIdentifier == bundleID })
        else { return false }
        running.activate(options: [.activateAllWindows])
        return true
    }
}

/// A turn that is currently running, shown as a live activity until the
/// matching `done` arrives (or it ages out).
struct AgentLiveRun: Identifiable, Equatable {
    let id: String            // session id from the agent; unique per run
    var tool: String
    var project: String
    var app: String
    var startedAt: Date
    var detail: String        // optional: current tool/step

    var toolDisplayName: String { AgentActivityInfo.displayName(for: tool) }

    /// Bring the tool's desktop app (or the app the run happens in) forward.
    func activateSourceApp() { AgentAppLauncher.activate(tool: tool, sourceApp: app) }
}

/// The three things an `agenticnotch://` URL can express.
enum AgentURLEvent {
    case start(AgentLiveRun)
    case done(AgentActivityInfo)

    static func from(url: URL) -> AgentURLEvent? {
        guard url.scheme == "agenticnotch" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String { items.first(where: { $0.name == name })?.value ?? "" }
        switch url.host {
        case "start":
            let tool = q("tool")
            guard !tool.isEmpty else { return nil }
            // Without a session id a run can never be cleared by its `done`.
            let session = q("session").isEmpty ? "\(tool)/\(q("project"))" : q("session")
            return .start(AgentLiveRun(id: session, tool: tool, project: q("project"),
                                       app: q("app"), startedAt: Date(), detail: q("detail")))
        case "done":
            return AgentActivityInfo.from(url: url).map { .done($0) }
        default:
            return nil
        }
    }
}

/// Payload decoded from an `agenticnotch://done?...` URL fired when a CLI AI
/// agent (Claude Code, Codex, ...) finishes a turn.
struct AgentActivityInfo: Equatable {
    var tool: String          // "claude", "codex", ...
    var status: AgentStatus
    var project: String       // basename of the agent's cwd; may be ""
    var title: String         // optional extra line; may be ""
    var app: String = ""      // bundle id of the app the agent ran in (terminal, editor); may be ""
    var session: String = ""  // session id, used to clear the matching live run

    /// Parse an `agenticnotch://done?...` URL. Returns nil for anything else.
    static func from(url: URL) -> AgentActivityInfo? {
        guard url.scheme == "agenticnotch", url.host == "done" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String { items.first(where: { $0.name == name })?.value ?? "" }
        let tool = q("tool")
        guard !tool.isEmpty else { return nil }
        let status = AgentStatus(rawValue: q("status")) ?? .ok
        return AgentActivityInfo(tool: tool, status: status, project: q("project"), title: q("title"),
                                 app: q("app"), session: q("session"))
    }

    /// Bring the relevant app to the front when the card is tapped.
    func activateSourceApp() { AgentAppLauncher.activate(tool: tool, sourceApp: app) }

    static func displayName(for tool: String) -> String {
        switch tool.lowercased() {
        case "claude": return "Claude"
        case "codex":  return "Codex"
        default:       return tool.capitalized
        }
    }

    var toolDisplayName: String { AgentActivityInfo.displayName(for: tool) }

    #if DEBUG
    static func runSelfCheck() {
        assert(from(url: URL(string: "agenticnotch://done?tool=claude&status=error&project=gcu-api")!)
               == AgentActivityInfo(tool: "claude", status: .error, project: "gcu-api", title: ""))
        assert(from(url: URL(string: "agenticnotch://done?tool=codex")!)?.status == .ok)
        assert(from(url: URL(string: "agenticnotch://done?status=ok")!) == nil)          // no tool
        assert(from(url: URL(string: "agenticnotch://other?tool=x")!) == nil)            // wrong host
        assert(from(url: URL(string: "agenticnotch://done?tool=claude&app=com.apple.Terminal")!)?.app
               == "com.apple.Terminal")
        assert(from(url: URL(string: "https://example.com")!) == nil)                    // wrong scheme
    }
    #endif
}

enum SneakContentType {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
}

struct SharedSneakPeek: Codable {
    var show: Bool
    var type: String
    var value: String
    var icon: String
}

enum BrowserType {
    case chromium
    case safari
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
    var browser: BrowserType = .chromium
}

@MainActor
class BoringViewCoordinator: ObservableObject {
    static let shared = BoringViewCoordinator()

    @Published var currentView: NotchViews = .home
    @Published var helloAnimationRunning: Bool = false
    private var sneakPeekDispatch: DispatchWorkItem?
    private var expandingViewDispatch: DispatchWorkItem?
    private var hudEnableTask: Task<Void, Never>?

    @AppStorage("firstLaunch") var firstLaunch: Bool = true
    @AppStorage("showWhatsNew") var showWhatsNew: Bool = true
    @AppStorage("musicLiveActivityEnabled") var musicLiveActivityEnabled: Bool = true
    @AppStorage("currentMicStatus") var currentMicStatus: Bool = true

    @AppStorage("alwaysShowTabs") var alwaysShowTabs: Bool = true {
        didSet {
            if !alwaysShowTabs {
                openLastTabByDefault = false
                if ShelfStateViewModel.shared.isEmpty || !Defaults[.openShelfByDefault] {
                    currentView = .home
                }
            }
        }
    }

    @AppStorage("openLastTabByDefault") var openLastTabByDefault: Bool = false {
        didSet {
            if openLastTabByDefault {
                alwaysShowTabs = true
            }
        }
    }
    
    @Default(.hudReplacement) var hudReplacement: Bool
    
    // Legacy storage for migration
    @AppStorage("preferred_screen_name") private var legacyPreferredScreenName: String?
    
    // New UUID-based storage
    @AppStorage("preferred_screen_uuid") var preferredScreenUUID: String? {
        didSet {
            if let uuid = preferredScreenUUID {
                selectedScreenUUID = uuid
            }
            NotificationCenter.default.post(name: Notification.Name.selectedScreenChanged, object: nil)
        }
    }

    @Published var selectedScreenUUID: String = NSScreen.main?.displayUUID ?? ""

    @Published var optionKeyPressed: Bool = true
    private var accessibilityObserver: Any?
    private var hudReplacementCancellable: AnyCancellable?

    private init() {
        // Perform migration from name-based to UUID-based storage
        if preferredScreenUUID == nil, let legacyName = legacyPreferredScreenName {
            // Try to find screen by name and migrate to UUID
            if let screen = NSScreen.screens.first(where: { $0.localizedName == legacyName }),
               let uuid = screen.displayUUID {
                preferredScreenUUID = uuid
                NSLog("✅ Migrated display preference from name '\(legacyName)' to UUID '\(uuid)'")
            } else {
                // Fallback to main screen if legacy screen not found
                preferredScreenUUID = NSScreen.main?.displayUUID
                NSLog("⚠️ Could not find display named '\(legacyName)', falling back to main screen")
            }
            // Clear legacy value after migration
            legacyPreferredScreenName = nil
        } else if preferredScreenUUID == nil {
            // No legacy value, use main screen
            preferredScreenUUID = NSScreen.main?.displayUUID
        }
        
        selectedScreenUUID = preferredScreenUUID ?? NSScreen.main?.displayUUID ?? ""
        // Observe changes to accessibility authorization and react accordingly
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.accessibilityAuthorizationChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if Defaults[.hudReplacement] {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }

        // Observe changes to hudReplacement
        hudReplacementCancellable = Defaults.publisher(.hudReplacement)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self else { return }

                    self.hudEnableTask?.cancel()
                    self.hudEnableTask = nil

                    if change.newValue {
                        self.hudEnableTask = Task { @MainActor in
                            let granted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                            if Task.isCancelled { return }

                            if granted {
                                await MediaKeyInterceptor.shared.start()
                            } else {
                                Defaults[.hudReplacement] = false
                            }
                        }
                    } else {
                        MediaKeyInterceptor.shared.stop()
                    }
                }
            }

        Task { @MainActor in
            helloAnimationRunning = firstLaunch

            if Defaults[.hudReplacement] {
                let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
                if !authorized {
                    Defaults[.hudReplacement] = false
                } else {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }
    }
    
    @objc func sneakPeekEvent(_ notification: Notification) {
        let decoder = JSONDecoder()
        if let decodedData = try? decoder.decode(
            SharedSneakPeek.self, from: notification.userInfo?.first?.value as! Data)
        {
            let contentType =
                decodedData.type == "brightness"
                ? SneakContentType.brightness
                : decodedData.type == "volume"
                    ? SneakContentType.volume
                    : decodedData.type == "backlight"
                        ? SneakContentType.backlight
                        : decodedData.type == "mic"
                            ? SneakContentType.mic : SneakContentType.brightness

            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            let value = CGFloat((formatter.number(from: decodedData.value) ?? 0.0).floatValue)
            let icon = decodedData.icon

            print("Decoded: \(decodedData), Parsed value: \(value)")

            toggleSneakPeek(status: decodedData.show, type: contentType, value: value, icon: icon)

        } else {
            print("Failed to decode JSON data")
        }
    }

    func toggleSneakPeek(
        status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, value: CGFloat = 0,
        icon: String = ""
    ) {
        sneakPeekDuration = duration
        if type != .music {
            // close()
            if !Defaults[.hudReplacement] {
                return
            }
        }
        Task { @MainActor in
            withAnimation(.smooth) {
                self.sneakPeek.show = status
                self.sneakPeek.type = type
                self.sneakPeek.value = value
                self.sneakPeek.icon = icon
            }
        }

        if type == .mic {
            currentMicStatus = value == 1
        }
    }

    private var sneakPeekDuration: TimeInterval = 1.5
    private var sneakPeekTask: Task<Void, Never>?

    // Helper function to manage sneakPeek timer using Swift Concurrency
    private func scheduleSneakPeekHide(after duration: TimeInterval) {
        sneakPeekTask?.cancel()

        sneakPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    self.toggleSneakPeek(status: false, type: .music)
                    self.sneakPeekDuration = 1.5
                }
            }
        }
    }

    @Published var sneakPeek: sneakPeek = .init() {
        didSet {
            if sneakPeek.show {
                scheduleSneakPeekHide(after: sneakPeekDuration)
            } else {
                sneakPeekTask?.cancel()
            }
        }
    }

    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0,
        browser: BrowserType = .chromium
    ) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
                self.expandingView.browser = browser
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?

    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                expandingViewTask?.cancel()
                let duration: TimeInterval = (expandingView.type == .download ? 2 : 3)
                let currentType = expandingView.type
                expandingViewTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    guard let self = self, !Task.isCancelled else { return }
                    self.toggleExpandingView(status: false, type: currentType)
                }
            } else {
                expandingViewTask?.cancel()
            }
        }
    }
    
    func showEmpty() {
        currentView = .home
    }

    // MARK: - Agent activity (AgenticNotch)

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

    // MARK: Live runs

    /// Turns currently in flight, newest first. Drives the live activity.
    @Published var liveRuns: [AgentLiveRun] = []

    private var liveSweepTask: Task<Void, Never>?

    /// Record a turn as started. A repeat start for the same session just
    /// refreshes it, so a re-prompt in one session doesn't stack up entries.
    func startAgentRun(_ run: AgentLiveRun) {
        guard Defaults[.agentLiveActivityEnabled] else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            if let i = liveRuns.firstIndex(where: { $0.id == run.id }) {
                // Keep the original start time so the elapsed timer is honest.
                var updated = run
                updated.startedAt = liveRuns[i].startedAt
                liveRuns[i] = updated
            } else {
                liveRuns.insert(run, at: 0)
            }
        }
        scheduleLiveSweep()
    }

    /// Clear a live run once its turn ends. Falls back to matching on
    /// tool+project when the agent gave us no session id.
    func finishAgentRun(_ info: AgentActivityInfo) {
        withAnimation(.smooth) {
            if !info.session.isEmpty {
                liveRuns.removeAll { $0.id == info.session }
            } else {
                liveRuns.removeAll { $0.tool == info.tool && $0.project == info.project }
            }
        }
    }

    /// Drop runs whose `done` never arrived (crash, killed terminal, hook not
    /// wired). Without this the notch would show a run forever.
    private func scheduleLiveSweep() {
        liveSweepTask?.cancel()
        liveSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                let maxAge = max(60, Defaults[.agentLiveMaxMinutes] * 60)
                await MainActor.run {
                    let cutoff = Date().addingTimeInterval(-maxAge)
                    if self.liveRuns.contains(where: { $0.startedAt < cutoff }) {
                        withAnimation(.smooth) {
                            self.liveRuns.removeAll { $0.startedAt < cutoff }
                        }
                    }
                    if self.liveRuns.isEmpty { self.liveSweepTask?.cancel() }
                }
            }
        }
    }

    private var agentDebounceTask: Task<Void, Never>?
    private var pendingAgentInfo: AgentActivityInfo?

    /// Called on every agent-finished event. Debounced: rapid successive events
    /// (turn-by-turn in one task) reset the timer, so only the last one — once
    /// things go quiet — actually notifies. Avoids a notification per turn.
    func showAgentActivity(_ info: AgentActivityInfo) {
        // Clear the live run immediately — the notification itself is debounced,
        // but "still running" must stop being true the moment the turn ends.
        finishAgentRun(info)
        pendingAgentInfo = info
        agentDebounceTask?.cancel()
        let seconds = max(0, Defaults[.agentDebounceSeconds])
        agentDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { self.fireAgentActivity() }
        }
    }

    private func fireAgentActivity() {
        guard let info = pendingAgentInfo else { return }
        pendingAgentInfo = nil
        recordAgentHistory(info)
        guard Defaults[.agentNotifyEnabled] else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) {
            self.agentActivity.info = info
            self.agentActivity.show = true
        }
        if Defaults[.agentSoundEnabled] {
            NSSound(named: NSSound.Name(Defaults[.agentSoundName]))?.play()
        }
    }

    /// Prepend to the agent history, trimming to the configured limit.
    private func recordAgentHistory(_ info: AgentActivityInfo) {
        var history = Defaults[.agentHistory]
        history.insert(AgentActivityRecord(info: info, date: Date()), at: 0)
        let limit = max(1, Defaults[.agentHistoryLimit])
        if history.count > limit { history = Array(history.prefix(limit)) }
        Defaults[.agentHistory] = history
    }
}

struct AgentActivityState {
    var show: Bool = false
    var info: AgentActivityInfo = AgentActivityInfo(tool: "", status: .ok, project: "", title: "")
}

// MARK: - AI quota / limits (AgenticNotch)

/// Severity reported by the provider, when it reports one. Drives the bar
/// colour so it matches the provider's own judgement instead of our guess.
enum QuotaSeverity: String {
    case normal, warning, critical

    var color: Color {
        switch self {
        case .normal:   return .green
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}

struct QuotaWindow: Identifiable {
    let id = UUID()
    let label: String         // "5h", "7d", ...
    let usedPercent: Double    // 0...100
    let resetAt: Date?
    /// nil when the provider doesn't report one — fall back to a percentage.
    var severity: QuotaSeverity?
    /// Extra note shown next to the label, e.g. remaining credits.
    var note: String?
}

struct ProviderQuota: Identifiable {
    let id = UUID()
    let provider: String       // "Claude", "Codex"
    var windows: [QuotaWindow]
    var error: String?
    /// True when `windows` came from an earlier fetch and we're still showing
    /// them because the latest one failed.
    var stale = false
}

/// Reads local Claude/Codex credentials and queries their usage endpoints.
/// Requires the app to be non-sandboxed (see boringNotch.entitlements).
@MainActor
final class AIQuotaManager: ObservableObject {
    static let shared = AIQuotaManager()

    @Published var providers: [ProviderQuota] = []
    @Published var isLoading = false
    @Published var lastUpdated: Date?

    /// Endpoints we're rate limited on, and when it's worth asking again.
    private var backoffUntil: [String: Date] = [:]
    /// Reopening the tab shouldn't fire a request every time — the numbers
    /// don't move that fast, and the usage endpoints answer 429 if you ask too
    /// often.
    private let minRefreshInterval: TimeInterval = 20

    private init() {}

    /// `force` skips the throttle: use it for the poll timer and the manual
    /// refresh button, not for the on-appear fetch.
    func refresh(force: Bool = false) async {
        if !force, let last = lastUpdated, Date().timeIntervalSince(last) < minRefreshInterval {
            return
        }
        isLoading = true
        let claude = await fetchClaude()
        let codex = await fetchCodex()
        providers = [claude, codex].compactMap { $0 }.map(keepingLastGoodWindows)
        lastUpdated = Date()
        isLoading = false
    }

    /// A rate limit or a dropped connection shouldn't blank out numbers we
    /// already have. Keep the previous windows and let the view mark them as
    /// stale, so a transient failure costs freshness rather than the whole card.
    private func keepingLastGoodWindows(_ fresh: ProviderQuota) -> ProviderQuota {
        guard fresh.error != nil, fresh.windows.isEmpty,
              let previous = providers.first(where: { $0.provider == fresh.provider }),
              !previous.windows.isEmpty
        else { return fresh }

        var merged = fresh
        merged.windows = previous.windows
        merged.stale = true
        return merged
    }

    /// Seconds left on a 429 backoff, or nil when we're free to ask again.
    private func backoffRemaining(_ provider: String) -> Int? {
        guard let until = backoffUntil[provider], until > Date() else { return nil }
        return max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
    }

    /// Honour Retry-After when the server sends one; two minutes is a guess
    /// that's long enough to actually clear a per-minute limit.
    private func startBackoff(_ provider: String, response: URLResponse?) -> Int {
        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
        let seconds = header.flatMap(Double.init) ?? 120
        backoffUntil[provider] = Date().addingTimeInterval(seconds)
        return Int(seconds)
    }

    // MARK: Reset timestamps

    /// Reset timestamps arrive in two shapes: Anthropic sends an ISO 8601
    /// string ("2026-07-29T02:40:00.940475+00:00"), OpenAI sends Unix epoch
    /// seconds. Accept both — casting a string with `as? Double` silently
    /// yields nil, which is why Claude showed no reset time at all.
    static func parseResetDate(_ value: Any?) -> Date? {
        if let epoch = value as? Double { return Date(timeIntervalSince1970: epoch) }
        if let epoch = (value as? NSNumber)?.doubleValue { return Date(timeIntervalSince1970: epoch) }
        guard let text = value as? String, !text.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: text) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    // MARK: Claude

    private func fetchClaude() async -> ProviderQuota? {
        if let secs = backoffRemaining("Claude") {
            return ProviderQuota(provider: "Claude", windows: [], error: "Rate limited — retrying in \(secs)s")
        }
        guard let token = claudeToken() else {
            return ProviderQuota(provider: "Claude", windows: [], error: "No credentials found")
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { return ProviderQuota(provider: "Claude", windows: [], error: "Session expired — log in again") }
            if code == 429 {
                let secs = startBackoff("Claude", response: resp)
                return ProviderQuota(provider: "Claude", windows: [], error: "Rate limited — retrying in \(secs)s")
            }
            guard code == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ProviderQuota(provider: "Claude", windows: [], error: "API error (\(code))")
            }
            return ProviderQuota(provider: "Claude", windows: parseClaudeWindows(json), error: nil)
        } catch {
            return ProviderQuota(provider: "Claude", windows: [], error: "Network error")
        }
    }

    /// Human labels for the usage windows Anthropic returns. Unknown keys fall
    /// back to a de-underscored form rather than being dropped, so newly added
    /// windows still show up.
    private static let claudeWindowLabels = [
        "five_hour": "5h",
        "seven_day": "7d",
        "seven_day_opus": "7d Opus",
        "seven_day_sonnet": "7d Sonnet",
        "seven_day_cowork": "7d Cowork",
        "seven_day_oauth_apps": "7d Apps",
        "seven_day_omelette": "7d Omelette",
    ]

    /// Keys that carry a `utilization` field but are not usage windows.
    private static let claudeNonWindowKeys: Set<String> = ["extra_usage"]

    private func parseClaudeWindows(_ json: [String: Any]) -> [QuotaWindow] {
        // `limits` reports the provider's own severity per group; map it onto
        // the windows by percentage so colours match Anthropic's judgement.
        var severityByPercent: [Int: QuotaSeverity] = [:]
        for entry in (json["limits"] as? [[String: Any]] ?? []) {
            guard let pct = (entry["percent"] as? Double) ?? (entry["percent"] as? NSNumber)?.doubleValue,
                  let raw = entry["severity"] as? String,
                  let sev = QuotaSeverity(rawValue: raw) else { continue }
            severityByPercent[Int(pct)] = sev
        }

        var out: [QuotaWindow] = []
        for (key, value) in json {
            guard !Self.claudeNonWindowKeys.contains(key),
                  let dict = value as? [String: Any],
                  let util = (dict["utilization"] as? Double) ?? (dict["utilization"] as? NSNumber)?.doubleValue
            else { continue }
            out.append(QuotaWindow(
                label: Self.claudeWindowLabels[key] ?? key.replacingOccurrences(of: "_", with: " "),
                usedPercent: util,
                resetAt: AIQuotaManager.parseResetDate(dict["resets_at"] ?? dict["reset_at"]),
                severity: severityByPercent[Int(util)]))
        }

        if let extra = extraUsageWindow(json) { out.append(extra) }

        let order = ["5h", "7d", "7d Sonnet", "7d Opus", "7d Cowork", "7d Apps"]
        return out.sorted { (order.firstIndex(of: $0.label) ?? 98) < (order.firstIndex(of: $1.label) ?? 98) }
    }

    /// Pay-as-you-go credits, shown only when the account has them enabled.
    private func extraUsageWindow(_ json: [String: Any]) -> QuotaWindow? {
        guard let extra = json["extra_usage"] as? [String: Any],
              (extra["is_enabled"] as? Bool) == true,
              let util = (extra["utilization"] as? Double) ?? (extra["utilization"] as? NSNumber)?.doubleValue
        else { return nil }
        var note: String?
        if let limit = (extra["monthly_limit"] as? Double) ?? (extra["monthly_limit"] as? NSNumber)?.doubleValue {
            let used = (extra["used_credits"] as? Double) ?? (extra["used_credits"] as? NSNumber)?.doubleValue ?? 0
            let currency = (extra["currency"] as? String) ?? ""
            note = "\(Int(used))/\(Int(limit)) \(currency)".trimmingCharacters(in: .whitespaces)
        }
        return QuotaWindow(label: "Extra usage", usedPercent: util, resetAt: nil,
                           severity: (extra["spend_limit_reached"] as? Bool) == true ? .critical : nil,
                           note: note)
    }

    private func claudeToken() -> String? {
        if let json = keychainJSON(service: "Claude Code-credentials"), let t = oauthAccessToken(json) { return t }
        let path = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
        if let data = FileManager.default.contents(atPath: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = oauthAccessToken(json) { return t }
        return nil
    }

    private func oauthAccessToken(_ json: [String: Any]) -> String? {
        for key in ["claudeAiOauth", "claude.ai_oauth"] {
            if let o = json[key] as? [String: Any], let t = o["accessToken"] as? String { return t }
        }
        return nil
    }

    // MARK: Codex

    private func fetchCodex() async -> ProviderQuota? {
        if let secs = backoffRemaining("Codex") {
            return ProviderQuota(provider: "Codex", windows: [], error: "Rate limited — retrying in \(secs)s")
        }
        let path = ("~/.codex/auth.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            return ProviderQuota(provider: "Codex", windows: [], error: "No OAuth token")
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let acc = tokens["account_id"] as? String {
            req.setValue(acc, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { return ProviderQuota(provider: "Codex", windows: [], error: "Session expired — run 'codex' to renew") }
            if code == 429 {
                let secs = startBackoff("Codex", response: resp)
                return ProviderQuota(provider: "Codex", windows: [], error: "Rate limited — retrying in \(secs)s")
            }
            guard code == 200,
                  let j = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let rate = j["rate_limit"] as? [String: Any] else {
                return ProviderQuota(provider: "Codex", windows: [], error: "API error (\(code))")
            }
            var windows: [QuotaWindow] = []
            for (key, fallback) in [("primary_window", "5h"), ("secondary_window", "7d")] {
                guard let w = rate[key] as? [String: Any],
                      let used = (w["used_percent"] as? Double) ?? (w["used_percent"] as? NSNumber)?.doubleValue
                else { continue }
                // Prefer the absolute reset_at; fall back to reset_after_seconds
                // (a duration from now) when the API omits it.
                var reset = AIQuotaManager.parseResetDate(w["reset_at"])
                if reset == nil,
                   let after = (w["reset_after_seconds"] as? Double)
                       ?? (w["reset_after_seconds"] as? NSNumber)?.doubleValue {
                    reset = Date().addingTimeInterval(after)
                }
                let secs = (w["limit_window_seconds"] as? Double) ?? (w["limit_window_seconds"] as? NSNumber)?.doubleValue
                windows.append(QuotaWindow(label: codexLabel(secs) ?? fallback,
                                           usedPercent: used,
                                           resetAt: reset))
            }
            return ProviderQuota(provider: "Codex", windows: windows, error: nil)
        } catch {
            return ProviderQuota(provider: "Codex", windows: [], error: "Network error")
        }
    }

    private func codexLabel(_ secs: Double?) -> String? {
        guard let s = secs else { return nil }
        switch Int(s) {
        case 18000:  return "5h"
        case 604800: return "7d"
        default:     return "\(Int(s / 3600))h"
        }
    }

    // MARK: Keychain

    private func keychainJSON(service: String) -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
