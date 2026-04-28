import Foundation

public actor ComputerUseSession {
    public nonisolated var tools: [ComputerUseTool] { ToolCatalog.tools }

    private let config: ComputerUseConfig
    private let backend: any ComputerUseBackend

    private var currentTarget: CurrentTarget?
    private var currentCapture: CurrentCapture?
    private var currentStateTarget: StateTargetSnapshot?
    private var currentImageMode: ImageMode = .auto
    private var currentAxTargets: [AxTarget]?
    private var windowRefs: [String: WindowRefRecord] = [:]
    private var windowRefByIdentity: [String: String] = [:]
    private var nextWindowRefIndex = 1
    private var allowNextTypeTextAxReplacement = false
    private var pendingBrowserAddress: PendingBrowserAddress?
    private var lastPermissionStatus: ComputerUsePermissionStatus?
    private var lastPermissionCheckAt: Date?

    private let actionSettleMs = 280
    private let batchActionGapMs = 80
    private let batchMaxActions = 20
    private let defaultWaitMs = 1_000

    public init(config: ComputerUseConfig = ComputerUseConfig()) {
        self.config = config
        self.backend = DefaultBackendFactory.makeBackend()
    }

    init(config: ComputerUseConfig = ComputerUseConfig(), backend: any ComputerUseBackend) {
        self.config = config
        self.backend = backend
    }

    public func checkPermissions() async -> ComputerUsePermissionStatus {
        await backend.checkPermissions()
    }

    public func openPermissionPane(_ kind: ComputerUsePermissionKind) async throws {
        try await backend.openPermissionPane(kind)
    }

    public func execute(tool: String, arguments: [String: JSONValue] = [:]) async throws -> ComputerUseToolResult {
        guard ToolCatalog.names.contains(tool) else {
            throw ComputerUseError("Unknown computer-use tool '\(tool)'.", code: "unknown_tool")
        }
        try await ensureReady()

        switch tool {
        case "list_apps":
            return try await performListApps()
        case "list_windows":
            return try await performListWindows(arguments)
        case "screenshot":
            return try await performScreenshot(arguments)
        case "click":
            return try await performClick(arguments)
        case "double_click":
            return try await performDoubleClick(arguments)
        case "move_mouse":
            return try await performMoveMouse(arguments)
        case "drag":
            return try await performDrag(arguments)
        case "scroll":
            return try await performScroll(arguments)
        case "keypress":
            return try await performKeypress(arguments)
        case "type_text":
            return try await performTypeText(arguments)
        case "set_text":
            return try await performSetText(arguments)
        case "wait":
            return try await performWait(arguments)
        case "arrange_window":
            return try await performArrangeWindow(arguments)
        case "navigate_browser":
            return try await performNavigateBrowser(arguments)
        case "computer_actions":
            return try await performComputerActions(arguments)
        default:
            throw ComputerUseError("Unknown computer-use tool '\(tool)'.", code: "unknown_tool")
        }
    }

    public func execute(tool: String, argumentsData: Data) async throws -> ComputerUseToolResult {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: argumentsData)
        guard let object = decoded.objectValue else {
            throw ComputerUseError("Tool arguments must decode to a JSON object.", code: "invalid_args")
        }
        return try await execute(tool: tool, arguments: object)
    }
}

private extension ComputerUseSession {
    func ensureReady() async throws {
        #if os(macOS)
        let now = Date()
        if let lastPermissionStatus,
           lastPermissionStatus.accessibility,
           lastPermissionStatus.screenRecording,
           let lastPermissionCheckAt,
           now.timeIntervalSince(lastPermissionCheckAt) < 2 {
            return
        }

        let status = await backend.checkPermissions()
        lastPermissionStatus = status
        lastPermissionCheckAt = now
        guard status.accessibility && status.screenRecording else {
            let missing = [
                status.accessibility ? nil : "Accessibility",
                status.screenRecording ? nil : "Screen Recording"
            ].compactMap { $0 }.joined(separator: " and ")
            let host = Bundle.main.executablePath ?? ProcessInfo.processInfo.processName
            throw ComputerUseError(
                "ComputerUse needs \(missing) permission for the host executable: \(host). Grant permissions to the app or executable importing this Swift package, then retry.",
                code: "missing_permissions"
            )
        }
        #else
        throw ComputerUseError("ComputerUse currently supports macOS only.", code: "unsupported_platform")
        #endif
    }

    func normalizeText(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func trimmedString(_ value: JSONValue?) -> String? {
        guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    func finiteNumber(_ value: JSONValue?, fallback: Double = 0) -> Double {
        guard let number = value?.doubleValue, number.isFinite else { return fallback }
        return number
    }

    func finiteInt(_ value: JSONValue?, fallback: Int = 0) -> Int {
        let number = finiteNumber(value, fallback: Double(fallback))
        return Int(number.rounded(.towardZero))
    }

    func normalizeWindowSelector(_ value: JSONValue?) -> String? {
        if let string = trimmedString(value) {
            return string
        }
        if let number = value?.doubleValue, number.isFinite {
            return String(Int(number.rounded(.towardZero)))
        }
        return nil
    }

    func imageMode(_ value: JSONValue?) -> ImageMode {
        if value?.stringValue == "always" { return .always }
        if value?.stringValue == "never" { return .never }
        return .auto
    }

    func normalizeMouseButton(_ value: JSONValue?) -> MouseButtonName {
        if value?.stringValue == "right" { return .right }
        if value?.stringValue == "middle" { return .middle }
        return .left
    }

    func normalizeClickCount(_ value: JSONValue?, fallback: Int = 1) -> Int {
        max(1, min(3, finiteInt(value, fallback: fallback)))
    }

    func normalizeScrollDelta(_ value: JSONValue?) -> Int {
        max(-10_000, min(10_000, Int(finiteNumber(value).rounded())))
    }

    func normalizeKeyList(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap { item in
            let key = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return key?.isEmpty == false ? key : nil
        } ?? []
    }

    func sleep(ms: Int) async throws {
        guard ms > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    func randomStateId() -> String {
        UUID().uuidString
    }

    func isStrictAxMode() -> Bool {
        config.stealthMode
    }

    func executionTrace(
        _ strategy: String,
        variant: String,
        axAttempted: Bool? = nil,
        axSucceeded: Bool? = nil,
        fallbackUsed: Bool? = nil,
        nonStealthReason: String? = nil,
        actionCount: Int? = nil,
        completedActionCount: Int? = nil,
        actions: [BatchActionTrace]? = nil
    ) -> ExecutionTrace {
        ExecutionTrace(
            strategy: strategy,
            axAttempted: axAttempted,
            axSucceeded: axSucceeded,
            fallbackUsed: fallbackUsed,
            runtimeMode: isStrictAxMode() ? "stealth" : "default",
            variant: variant,
            stealthCompatible: variant == "stealth",
            nonStealthReason: nonStealthReason,
            actionCount: actionCount,
            completedActionCount: completedActionCount,
            actions: actions
        )
    }

    func strictModeBlock(_ message: String) throws -> Never {
        throw ComputerUseError("\(message) Stealth/strict AX mode is enabled, so non-AX, foreground-focus, and cursor fallbacks are blocked.", code: "strict_ax_blocked")
    }

    func settleMs(for execution: ExecutionTrace) -> Int {
        if execution.strategy == "batch" {
            let actions = execution.actions ?? []
            return !actions.isEmpty && actions.allSatisfy { $0.variant == "stealth" } ? 120 : actionSettleMs
        }
        if execution.variant == "stealth" {
            switch execution.strategy {
            case "ax_focus", "ax_set_value":
                return 80
            case "ax_action", "browser_open_location", "ax_scroll":
                return 120
            case "ax_press":
                return 160
            default:
                return 120
            }
        }
        return actionSettleMs
    }
}

private extension ComputerUseSession {
    func isBrowserApp(appName: String, bundleId: String?) -> Bool {
        let browserBundleIds: Set<String> = [
            "com.apple.Safari",
            "com.google.Chrome",
            "org.chromium.Chromium",
            "company.thebrowser.Browser",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi",
            "net.imput.helium",
            "org.mozilla.firefox"
        ]
        let browserAppNames: Set<String> = [
            "safari",
            "google chrome",
            "chrome",
            "chromium",
            "arc",
            "brave browser",
            "brave",
            "microsoft edge",
            "edge",
            "vivaldi",
            "helium",
            "firefox"
        ]
        return browserBundleIds.contains(bundleId ?? "") || browserAppNames.contains(normalizeText(appName))
    }

    func assertBrowserUseAllowed(_ appName: String, _ bundleId: String?) throws {
        if !config.browserUse && isBrowserApp(appName: appName, bundleId: bundleId) {
            throw ComputerUseError(
                "Browser use is disabled by ComputerUse config, so '\(appName)' cannot be controlled.",
                code: "browser_use_disabled"
            )
        }
    }

    func appMatchesWindowQuery(_ app: BackendApp, _ query: [String: JSONValue]) -> Bool {
        if let pid = query["pid"]?.intValue, app.pid != Int32(pid) { return false }
        if let bundle = trimmedString(query["bundleId"]), normalizeText(app.bundleId) != normalizeText(bundle) { return false }
        if let appQuery = trimmedString(query["app"]), !normalizeText(app.appName).contains(normalizeText(appQuery)) { return false }
        return true
    }

    func scoreWindow(_ window: BackendWindow) -> Int {
        var score = 0
        if window.isFocused { score += 100 }
        if window.isMain { score += 80 }
        if !window.isMinimized { score += 40 }
        if window.isOnscreen { score += 20 }
        if let id = window.windowId, id > 0 { score += 10 }
        if !window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 2 }
        return score
    }

    func choosePreferredWindow(_ windows: [BackendWindow], appName: String) throws -> BackendWindow {
        guard let window = windows.sorted(by: { scoreWindow($0) > scoreWindow($1) }).first else {
            throw ComputerUseError("No controllable window was found in app '\(appName)'.", code: "window_not_found")
        }
        return window
    }

    func summarizeWindowCandidate(_ window: BackendWindow) -> String {
        let flags = [
            window.isFocused ? "focused" : nil,
            window.isMain ? "main" : nil,
            window.isOnscreen ? "onscreen" : nil,
            window.isMinimized ? "minimized" : nil
        ].compactMap { $0 }.joined(separator: ",")
        return "\(window.title.isEmpty ? "(untitled)" : window.title) [score=\(scoreWindow(window))\(flags.isEmpty ? "" : ", \(flags)")]"
    }

    func summarizeWindowCandidates(_ windows: [BackendWindow], limit: Int = 6) -> String {
        windows.sorted(by: { scoreWindow($0) > scoreWindow($1) }).prefix(limit).map(summarizeWindowCandidate).joined(separator: "; ")
    }

    func chooseRankedWindowOrUndefined(_ windows: [BackendWindow]) -> BackendWindow? {
        let ranked = windows.sorted(by: { scoreWindow($0) > scoreWindow($1) })
        guard let first = ranked.first else { return nil }
        guard ranked.count > 1 else { return first }
        return scoreWindow(first) >= scoreWindow(ranked[1]) + 25 ? first : nil
    }

    func chooseAppByQuery(_ apps: [BackendApp], appQuery: String) throws -> BackendApp {
        let query = normalizeText(appQuery)
        let exact = apps.filter { normalizeText($0.appName) == query }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return exact.first(where: \.isFrontmost) ?? exact[0] }

        let partial = apps.filter { normalizeText($0.appName).contains(query) }
        if partial.isEmpty {
            let running = apps.prefix(12).map(\.appName).joined(separator: ", ")
            throw ComputerUseError("App '\(appQuery)' is not running. Running apps: \(running.isEmpty ? "none" : running).", code: "app_not_found")
        }
        if partial.count == 1 { return partial[0] }
        throw ComputerUseError("App name '\(appQuery)' is ambiguous (\(partial.map(\.appName).joined(separator: ", "))). Use a more specific app name.", code: "ambiguous_app")
    }

    func chooseWindowByTitle(_ windows: [BackendWindow], windowTitle: String, appName: String) throws -> BackendWindow {
        let query = normalizeText(windowTitle)
        let exact = windows.filter { normalizeText($0.title) == query }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 {
            if let clear = chooseRankedWindowOrUndefined(exact) { return clear }
            throw ComputerUseError("Window title '\(windowTitle)' is ambiguous in app '\(appName)'. Candidates: \(summarizeWindowCandidates(exact)).", code: "ambiguous_window")
        }

        let partial = windows.filter { normalizeText($0.title).contains(query) }
        if partial.isEmpty {
            throw ComputerUseError("Window '\(windowTitle)' was not found in app '\(appName)'. Available windows: \(summarizeWindowCandidates(windows)).", code: "window_not_found")
        }
        if partial.count == 1 { return partial[0] }
        if let clear = chooseRankedWindowOrUndefined(partial) { return clear }
        throw ComputerUseError("Window title '\(windowTitle)' is ambiguous in app '\(appName)'. Candidates: \(summarizeWindowCandidates(partial)).", code: "ambiguous_window")
    }

    func windowRecordIdentity(_ record: WindowRefRecord) -> String {
        if let windowId = record.windowId, windowId > 0 {
            return "pid:\(record.pid)|id:\(windowId)"
        }
        if let nativeWindowRef = record.nativeWindowRef {
            return "pid:\(record.pid)|ref:\(nativeWindowRef)"
        }
        let frame = record.framePoints
        return "pid:\(record.pid)|title:\(normalizeText(record.windowTitle))|frame:\(Int(frame.x.rounded())),\(Int(frame.y.rounded())),\(Int(frame.w.rounded())),\(Int(frame.h.rounded()))"
    }

    func storeWindowRef(_ recordWithoutRef: WindowRefRecord) -> WindowRefRecord {
        let identity = windowRecordIdentity(recordWithoutRef)
        if let existingRef = windowRefByIdentity[identity], let existing = windowRefs[existingRef] {
            var updated = recordWithoutRef
            updated.ref = existing.ref
            windowRefs[existing.ref] = updated
            return updated
        }

        var stored = recordWithoutRef
        stored.ref = "@w\(nextWindowRefIndex)"
        nextWindowRefIndex += 1
        windowRefByIdentity[identity] = stored.ref
        windowRefs[stored.ref] = stored
        return stored
    }

    func storeWindowRefForAppWindow(app: BackendApp, window: BackendWindow) -> WindowRefRecord {
        storeWindowRef(WindowRefRecord(
            ref: "",
            appName: app.appName,
            bundleId: app.bundleId,
            pid: app.pid,
            windowTitle: window.title.isEmpty ? "(untitled)" : window.title,
            windowId: window.windowId,
            nativeWindowRef: window.nativeWindowRef,
            framePoints: window.framePoints,
            scaleFactor: window.scaleFactor,
            isMinimized: window.isMinimized,
            isOnscreen: window.isOnscreen,
            isMain: window.isMain,
            isFocused: window.isFocused
        ))
    }

    func toResolvedTarget(app: BackendApp, window: BackendWindow) throws -> ResolvedTarget {
        let record = storeWindowRefForAppWindow(app: app, window: window)
        return ResolvedTarget(
            appName: app.appName,
            bundleId: app.bundleId,
            pid: app.pid,
            windowTitle: window.title.isEmpty ? "(untitled)" : window.title,
            windowId: window.windowId ?? 0,
            windowRef: record.ref,
            nativeWindowRef: window.nativeWindowRef,
            framePoints: window.framePoints,
            scaleFactor: window.scaleFactor,
            isMinimized: window.isMinimized,
            isOnscreen: window.isOnscreen,
            isMain: window.isMain,
            isFocused: window.isFocused
        )
    }

    func setCurrentTarget(_ target: ResolvedTarget) throws {
        try assertBrowserUseAllowed(target.appName, target.bundleId)
        currentTarget = CurrentTarget(
            appName: target.appName,
            bundleId: target.bundleId,
            pid: target.pid,
            windowTitle: target.windowTitle,
            windowId: target.windowId,
            windowRef: target.windowRef,
            nativeWindowRef: target.nativeWindowRef
        )
    }
}

private extension ComputerUseSession {
    func resolveTargetByWindowSelector(_ selector: JSONValue?) async throws -> ResolvedTarget {
        guard let normalized = normalizeWindowSelector(selector) else {
            throw ComputerUseError("window target must be a non-empty @w ref or numeric windowId.", code: "invalid_args")
        }

        if currentTarget?.windowRef == normalized {
            return try await resolveCurrentTarget()
        }

        if let record = windowRefs[normalized] {
            let app = BackendApp(appName: record.appName, bundleId: record.bundleId, pid: record.pid, isFrontmost: false)
            let windows = try await backend.listWindows(pid: record.pid)
            let match =
                (record.windowId.flatMap { id in windows.first { $0.windowId == id } }) ??
                (record.nativeWindowRef.flatMap { ref in windows.first { $0.nativeWindowRef == ref } }) ??
                windows.first { normalizeText($0.title.isEmpty ? "(untitled)" : $0.title) == normalizeText(record.windowTitle) }
            guard let match else {
                throw ComputerUseError("Window ref '\(normalized)' is stale. Call list_windows again and choose a current window.", code: "stale_window_ref")
            }
            let resolved = try toResolvedTarget(app: app, window: match)
            try setCurrentTarget(resolved)
            return resolved
        }

        if let numeric = Int(normalized), numeric > 0 {
            let apps = try await backend.listApps()
            for app in apps {
                let windows = try await backend.listWindows(pid: app.pid)
                if let match = windows.first(where: { $0.windowId == UInt32(numeric) }) {
                    try assertBrowserUseAllowed(app.appName, app.bundleId)
                    let resolved = try toResolvedTarget(app: app, window: match)
                    try setCurrentTarget(resolved)
                    return resolved
                }
            }
            throw ComputerUseError("Window id '\(numeric)' was not found. Call list_windows again and choose a current window.", code: "window_not_found")
        }

        if normalized.hasPrefix("@w") {
            throw ComputerUseError("Window ref '\(normalized)' is not available in this session. Call list_windows first.", code: "unknown_window_ref")
        }
        throw ComputerUseError("Unsupported window target '\(normalized)'. Use a @w ref from list_windows or a numeric windowId.", code: "invalid_args")
    }

    func selectWindowIfProvided(_ selector: JSONValue?) async throws {
        guard normalizeWindowSelector(selector) != nil else { return }
        let previous = currentTarget
        let selected = try await resolveTargetByWindowSelector(selector)
        let changed = previous == nil ||
            previous?.pid != selected.pid ||
            ((previous?.windowId ?? 0) > 0 && selected.windowId > 0 ? previous?.windowId != selected.windowId : previous?.windowRef != selected.windowRef)
        if changed {
            currentCapture = nil
            currentStateTarget = nil
            currentAxTargets = nil
        }
    }

    func resolveCurrentTarget() async throws -> ResolvedTarget {
        guard let currentTarget else {
            throw ComputerUseError("No current controlled window. Call screenshot first to choose a target window.", code: "missing_target")
        }
        let windows = try await backend.listWindows(pid: currentTarget.pid)
        guard !windows.isEmpty else {
            throw ComputerUseError("The current controlled window is no longer available. Call screenshot to choose a new target window.", code: "current_target_gone")
        }

        let hadStableWindowId = currentTarget.windowId > 0
        let titleQuery = normalizeText(currentTarget.windowTitle)
        var match: BackendWindow?
        if hadStableWindowId {
            match = windows.first { $0.windowId == currentTarget.windowId }
        }
        if match == nil, !titleQuery.isEmpty, titleQuery != "(untitled)" {
            let exact = windows.filter { normalizeText($0.title) == titleQuery }
            if exact.count == 1 {
                match = exact[0]
            } else if exact.count > 1 {
                match = chooseRankedWindowOrUndefined(exact)
                if match == nil {
                    throw ComputerUseError("The current controlled window is no longer available. Multiple windows now match '\(currentTarget.windowTitle)': \(summarizeWindowCandidates(exact)).", code: "current_target_gone")
                }
            }
        }
        if match == nil, !hadStableWindowId {
            match = chooseRankedWindowOrUndefined(windows)
        }
        guard let match else {
            throw ComputerUseError("The current controlled window is no longer available. Call screenshot to choose a new target window.", code: "current_target_gone")
        }

        let app = BackendApp(appName: currentTarget.appName, bundleId: currentTarget.bundleId, pid: currentTarget.pid, isFrontmost: false)
        let resolved = try toResolvedTarget(app: app, window: match)
        try setCurrentTarget(resolved)
        return resolved
    }

    func resolveFrontmostTarget() async throws -> ResolvedTarget {
        let frontmost = try await backend.getFrontmost()
        let apps = try await backend.listApps()
        let app = apps.first { $0.pid == frontmost.pid } ?? BackendApp(
            appName: frontmost.appName,
            bundleId: frontmost.bundleId,
            pid: frontmost.pid,
            isFrontmost: true
        )
        try assertBrowserUseAllowed(app.appName, app.bundleId)

        let windows = try await backend.listWindows(pid: frontmost.pid)
        guard !windows.isEmpty else {
            throw ComputerUseError("No frontmost controllable window was found. Open an app window and call screenshot again.", code: "window_not_found")
        }
        var selected = frontmost.windowId.flatMap { id in windows.first { $0.windowId == id } }
        if selected == nil, let title = frontmost.windowTitle {
            selected = windows.first { normalizeText($0.title) == normalizeText(title) }
        }
        if selected == nil {
            selected = try choosePreferredWindow(windows, appName: app.appName)
        }
        let resolved = try toResolvedTarget(app: app, window: selected!)
        try setCurrentTarget(resolved)
        return resolved
    }

    func resolveTargetForScreenshot(_ args: [String: JSONValue]) async throws -> ResolvedTarget {
        let appQuery = trimmedString(args["app"])
        let titleQuery = trimmedString(args["windowTitle"])

        if let windowSelector = normalizeWindowSelector(args["window"]), !windowSelector.isEmpty {
            return try await resolveTargetByWindowSelector(args["window"])
        }

        if appQuery == nil && titleQuery == nil {
            if currentTarget != nil {
                return try await resolveCurrentTarget()
            }
            return try await resolveFrontmostTarget()
        }

        let apps = try await backend.listApps()
        if let appQuery {
            let app = try chooseAppByQuery(apps, appQuery: appQuery)
            try assertBrowserUseAllowed(app.appName, app.bundleId)
            let windows = try await backend.listWindows(pid: app.pid)
            guard !windows.isEmpty else {
                throw ComputerUseError("No controllable window was found in app '\(app.appName)'.", code: "window_not_found")
            }
            let window: BackendWindow
            if let titleQuery {
                window = try chooseWindowByTitle(windows, windowTitle: titleQuery, appName: app.appName)
            } else if isBrowserApp(appName: app.appName, bundleId: app.bundleId),
                      let currentTarget,
                      currentTarget.pid == app.pid,
                      let current = windows.first(where: { $0.windowId == currentTarget.windowId }) {
                window = current
            } else {
                window = try choosePreferredWindow(windows, appName: app.appName)
            }
            let resolved = try toResolvedTarget(app: app, window: window)
            try setCurrentTarget(resolved)
            return resolved
        }

        let query = titleQuery!
        var exact: [(BackendApp, BackendWindow)] = []
        var partial: [(BackendApp, BackendWindow)] = []
        for app in apps {
            let windows = try await backend.listWindows(pid: app.pid)
            for window in windows {
                let title = normalizeText(window.title)
                if title.isEmpty { continue }
                if title == normalizeText(query) {
                    exact.append((app, window))
                } else if title.contains(normalizeText(query)) {
                    partial.append((app, window))
                }
            }
        }
        let matches = exact.isEmpty ? partial : exact
        guard !matches.isEmpty else {
            throw ComputerUseError("Window '\(query)' was not found in any running app.", code: "window_not_found")
        }
        if matches.count > 1 {
            let ranked = matches.sorted { scoreWindow($0.1) > scoreWindow($1.1) }
            if ranked.count > 1, scoreWindow(ranked[0].1) >= scoreWindow(ranked[1].1) + 25 {
                let resolved = try toResolvedTarget(app: ranked[0].0, window: ranked[0].1)
                try setCurrentTarget(resolved)
                return resolved
            }
            let options = ranked.prefix(6).map { "\($0.0.appName) - \(summarizeWindowCandidate($0.1))" }.joined(separator: ", ")
            throw ComputerUseError("Window title '\(query)' is ambiguous (\(options)). Specify app as well.", code: "ambiguous_window")
        }

        let resolved = try toResolvedTarget(app: matches[0].0, window: matches[0].1)
        try setCurrentTarget(resolved)
        return resolved
    }

    func ensureTargetWindowId(_ target: ResolvedTarget) async throws -> ResolvedTarget {
        if target.windowId > 0 { return target }
        let refreshed = try await resolveCurrentTarget()
        guard refreshed.windowId > 0 else {
            throw ComputerUseError("The current controlled window is no longer available. Call screenshot to choose a new target window.", code: "current_target_gone")
        }
        return refreshed
    }

    func captureForTarget(_ target: ResolvedTarget) -> CurrentCapture {
        CurrentCapture(
            stateId: randomStateId(),
            width: max(1, Int((target.framePoints.w * target.scaleFactor).rounded())),
            height: max(1, Int((target.framePoints.h * target.scaleFactor).rounded())),
            scaleFactor: max(1, target.scaleFactor),
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    func parseAxTargets(_ result: AxListResult) -> [AxTarget] {
        result.targets.enumerated().map { index, target in
            AxTarget(
                ref: "@e\(index + 1)",
                elementRef: target.elementRef,
                role: target.role,
                subrole: target.subrole,
                title: target.title,
                description: target.description,
                value: target.value,
                actions: target.actions,
                isTextInput: target.isTextInput,
                canSetValue: target.canSetValue,
                canFocus: target.canFocus,
                canPress: target.canPress,
                canScroll: target.canScroll,
                canIncrement: target.canIncrement,
                canDecrement: target.canDecrement,
                x: target.x,
                y: target.y,
                score: target.score
            )
        }
    }

    func axDiagnostics(from result: AxListResult, target: ResolvedTarget) -> AxDiagnostics? {
        guard let reason = result.reason else { return nil }
        if reason == "window_not_found" {
            let hint = target.windowRef.map { " Use list_windows and choose an existing content window such as \($0), then call screenshot({ window: \"\($0)\" })." } ?? " Use list_windows and choose an existing content window."
            return AxDiagnostics(reason: reason, message: "Accessibility could not resolve the target browser window. Duplicate/empty browser windows can cause this.\(hint)")
        }
        return AxDiagnostics(reason: reason, message: "Accessibility target listing returned '\(reason)'.")
    }

    func captureCurrentTarget(priorActivation: ActivationFlags = ActivationFlags()) async throws -> CaptureResult {
        var target = try await resolveCurrentTarget()
        target = try await ensureTargetWindowId(target)
        let capture = captureForTarget(target)
        let axResult = (try? await backend.listAxTargets(
            pid: target.pid,
            windowId: target.windowId,
            nativeWindowRef: target.nativeWindowRef,
            limit: 12
        )) ?? AxListResult(targets: [], reason: "ax_list_failed")
        let axTargets = parseAxTargets(axResult)
        let diagnostics = axDiagnostics(from: axResult, target: target)

        try setCurrentTarget(target)
        currentCapture = capture
        currentStateTarget = StateTargetSnapshot(pid: target.pid, windowId: target.windowId, windowRef: target.windowRef)
        currentAxTargets = axTargets

        return CaptureResult(target: target, capture: capture, image: nil, axTargets: axTargets, axDiagnostics: diagnostics, activation: priorActivation)
    }

    func ensureCaptureImage(_ result: inout CaptureResult) async throws {
        if result.image != nil { return }
        let image = try await backend.screenshot(windowId: result.target.windowId)
        result.image = image
        result.capture.width = image.width
        result.capture.height = image.height
        result.capture.scaleFactor = image.scaleFactor
        try setCurrentTarget(result.target)
        currentCapture = result.capture
        currentStateTarget = StateTargetSnapshot(pid: result.target.pid, windowId: result.target.windowId, windowRef: result.target.windowRef)
        currentAxTargets = result.axTargets
    }
}

private extension ComputerUseSession {
    func validateStateId(_ stateId: String?) throws -> CurrentCapture {
        guard let currentTarget, let currentCapture else {
            throw ComputerUseError("No current controlled window. Call screenshot first to choose a target window.", code: "missing_target")
        }
        if let stateId, !stateId.isEmpty, currentCapture.stateId != stateId {
            let hint = currentTarget.windowRef.map { "({ window: \"\($0)\" })" } ?? ""
            throw ComputerUseError("Stale state '\(stateId)'. The latest state is '\(currentCapture.stateId)' for \(currentTarget.windowRef ?? "the current window"). Call screenshot\(hint) again and retry.", code: "stale_state")
        }
        if let snapshot = currentStateTarget,
           snapshot.pid != currentTarget.pid || snapshot.windowId != currentTarget.windowId {
            throw ComputerUseError("The latest state belongs to a different window. Call screenshot for the target window and retry.", code: "target_mismatch")
        }
        return currentCapture
    }

    func ensurePointIsInCapture(_ x: Double, _ y: Double, capture: CurrentCapture, prefix: String = "Coordinates") throws {
        guard x.isFinite, y.isFinite else {
            throw ComputerUseError("\(prefix) must be finite numbers.", code: "invalid_args")
        }
        guard x >= 0, y >= 0, x < Double(capture.width), y < Double(capture.height) else {
            throw ComputerUseError("\(prefix) (\(Int(x.rounded())),\(Int(y.rounded()))) are outside the latest screenshot bounds (\(capture.width)x\(capture.height)). Call screenshot again and retry.", code: "coordinates_out_of_bounds")
        }
    }

    func normalizeDragPath(_ value: JSONValue?, capture: CurrentCapture) throws -> [CGPointValue] {
        guard let array = value?.arrayValue, array.count >= 2 else {
            throw ComputerUseError("drag.path must contain at least two points.", code: "invalid_args")
        }
        return try array.enumerated().map { index, item in
            let object = item.objectValue
            let x: Double
            let y: Double
            if let object {
                x = finiteNumber(object["x"], fallback: .nan)
                y = finiteNumber(object["y"], fallback: .nan)
            } else if let tuple = item.arrayValue, tuple.count >= 2 {
                x = finiteNumber(tuple[0], fallback: .nan)
                y = finiteNumber(tuple[1], fallback: .nan)
            } else {
                x = .nan
                y = .nan
            }
            try ensurePointIsInCapture(x, y, capture: capture, prefix: "Drag point \(index + 1)")
            return CGPointValue(x: x, y: y)
        }
    }

    func axTargetByRef(_ ref: String) throws -> AxTarget {
        guard let target = currentAxTargets?.first(where: { $0.ref == ref }) else {
            let hint = currentTarget?.windowRef.map { "({ window: \"\($0)\" })" } ?? ""
            throw ComputerUseError("AX target '\(ref)' is stale or not available for the latest state. Call screenshot\(hint) again and choose a current @e ref.", code: "stale_ax_ref")
        }
        return target
    }

    func axTargetLabelKey(_ target: AxTarget) -> String {
        normalizeText(target.title.isEmpty ? (target.description.isEmpty ? target.value : target.description) : target.title)
    }

    func reacquireAxTarget(_ stale: AxTarget, target: ResolvedTarget) async -> AxTarget? {
        guard let result = try? await backend.listAxTargets(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef, limit: 50) else {
            return nil
        }
        let refreshed = parseAxTargets(result)
        guard !refreshed.isEmpty else { return nil }
        currentAxTargets = refreshed

        let staleLabel = axTargetLabelKey(stale)
        let candidates = refreshed.filter { candidate in
            if candidate.role != stale.role { return false }
            if !staleLabel.isEmpty && axTargetLabelKey(candidate) != staleLabel { return false }
            if stale.canSetValue && !candidate.canSetValue { return false }
            if stale.canPress && !candidate.canPress { return false }
            if stale.canScroll && !candidate.canScroll { return false }
            if stale.canIncrement && !candidate.canIncrement { return false }
            if stale.canDecrement && !candidate.canDecrement { return false }
            return true
        }
        let pool = candidates.isEmpty ? refreshed.filter { !staleLabel.isEmpty && axTargetLabelKey($0) == staleLabel } : candidates
        guard var best = pool.sorted(by: { hypot($0.x - stale.x, $0.y - stale.y) < hypot($1.x - stale.x, $1.y - stale.y) }).first else {
            return nil
        }
        best.ref = stale.ref
        return best
    }

    func formatAxTargetLabel(_ target: AxTarget) -> String {
        let label = target.title.isEmpty ? (target.description.isEmpty ? (target.value.isEmpty ? "(unlabeled)" : target.value) : target.description) : target.title
        let capabilities = [
            target.canSetValue ? "setValue" : nil,
            target.canPress ? "press" : nil,
            target.canFocus ? "focus" : nil,
            target.canScroll ? "scroll" : nil,
            (target.canIncrement || target.canDecrement) ? "adjust" : nil
        ].compactMap { $0 }.joined(separator: ",")
        return "\(target.ref) \(target.role)\(target.subrole.isEmpty ? "" : "/\(target.subrole)") \(String(reflecting: label))\(capabilities.isEmpty ? "" : " [\(capabilities)]")"
    }
}

private extension ComputerUseSession {
    func imageFallbackReason(tool: String, result: CaptureResult, execution: ExecutionTrace, mode: ImageMode) -> (reason: String, message: String)? {
        if mode == .never { return nil }
        if mode == .always { return ("fallback_recovery", "An image was requested explicitly for visual verification.") }
        if execution.fallbackUsed == true {
            return ("fallback_recovery", "The action used a fallback path, so an image is attached for recovery.")
        }
        if result.axTargets.isEmpty {
            if isBrowserApp(appName: result.target.appName, bundleId: result.target.bundleId),
               result.axDiagnostics?.reason == "window_not_found" {
                return ("browser_ax_window_unavailable", result.axDiagnostics?.message ?? "The browser window could not be resolved through Accessibility, so an image is attached for recovery.")
            }
            return ("no_ax_targets", "No useful AX targets were found, so an image is attached for vision fallback.")
        }
        if result.axTargets.count < 3 {
            return ("sparse_ax_targets", "Only a few AX targets were found, so an image is attached for extra context.")
        }

        let labels = result.axTargets.map { normalizeText($0.title.isEmpty ? ($0.description.isEmpty ? $0.value : $0.description) : $0.title) }.filter { !$0.isEmpty }
        let unlabeledCount = result.axTargets.filter { normalizeText($0.title.isEmpty ? ($0.description.isEmpty ? $0.value : $0.description) : $0.title).isEmpty }.count
        let strongTextRoles: Set<String> = ["AXTextField", "AXSearchField", "AXTextArea", "AXTextView", "AXEditableText"]
        let strongTargets = result.axTargets.filter { target in
            let label = normalizeText(target.title.isEmpty ? (target.description.isEmpty ? target.value : target.description) : target.title)
            return strongTextRoles.contains(target.role) || (!label.isEmpty && (target.actions.contains("AXPress") || target.role == "AXLink" || target.role == "AXButton"))
        }
        if strongTargets.isEmpty {
            return ("weak_ax_targets", "No strong AX targets were found, so an image is attached for vision fallback.")
        }
        if result.axTargets.count >= 3, unlabeledCount * 2 > result.axTargets.count {
            return ("unlabeled_ax_targets", "Most AX targets are unlabeled, so an image is attached for vision fallback.")
        }
        if labels.count > 3, Set(labels).count * 2 <= labels.count {
            return ("duplicated_ax_labels", "AX target labels are highly duplicated, so an image is attached for extra context.")
        }
        if tool == "wait", isBrowserApp(appName: result.target.appName, bundleId: result.target.bundleId) {
            return ("browser_wait_verification", "Browser content may have changed visually during wait, so an image is attached for fallback.")
        }
        return nil
    }

    func buildToolResult(tool: String, summary: String, result: CaptureResult, execution: ExecutionTrace, mode: ImageMode? = nil) async throws -> ComputerUseToolResult {
        var mutableResult = result
        let effectiveMode = mode ?? currentImageMode
        let fallbackReason = imageFallbackReason(tool: tool, result: mutableResult, execution: execution, mode: effectiveMode)
        if fallbackReason != nil {
            try await ensureCaptureImage(&mutableResult)
        }

        var detailsObject: [String: JSONValue] = [
            "tool": .string(tool),
            "target": .object([
                "app": .string(mutableResult.target.appName),
                "bundleId": JSONValue.stringOrNull(mutableResult.target.bundleId),
                "pid": .number(Double(mutableResult.target.pid)),
                "windowTitle": .string(mutableResult.target.windowTitle),
                "windowId": .number(Double(mutableResult.target.windowId)),
                "windowRef": JSONValue.stringOrNull(mutableResult.target.windowRef ?? currentTarget?.windowRef),
                "nativeWindowRef": JSONValue.stringOrNull(mutableResult.target.nativeWindowRef ?? currentTarget?.nativeWindowRef)
            ]),
            "capture": .object([
                "stateId": .string(mutableResult.capture.stateId),
                "width": .number(Double(mutableResult.capture.width)),
                "height": .number(Double(mutableResult.capture.height)),
                "scaleFactor": .number(mutableResult.capture.scaleFactor),
                "timestamp": .number(Double(mutableResult.capture.timestamp)),
                "coordinateSpace": .string("window-relative-screenshot-pixels")
            ]),
            "axTargets": .array(mutableResult.axTargets.map(\.json)),
            "activation": mutableResult.activation.json,
            "execution": execution.json,
            "status": "ok",
            "config": .object([
                "browser_use": .bool(config.browserUse),
                "stealth_mode": .bool(config.stealthMode)
            ])
        ]
        if let diagnostics = mutableResult.axDiagnostics {
            detailsObject["axDiagnostics"] = diagnostics.json
        }
        if let fallbackReason {
            detailsObject["imageReason"] = .string(fallbackReason.reason)
        }

        let axText = mutableResult.axTargets.isEmpty
            ? ""
            : "\n\nPrefer these AX targets over coordinate clicks or focus-based text replacement when one matches your intent:\n\(mutableResult.axTargets.map(formatAxTargetLabel).joined(separator: "\n"))"
        let fallbackText = fallbackReason.map { "\n\n\($0.message)" } ?? ""
        var content: [ComputerUseContent] = [.text(summary + axText + fallbackText)]
        if fallbackReason != nil, let image = mutableResult.image {
            content.append(.image(data: image.pngData, mimeType: "image/png"))
        }
        return ComputerUseToolResult(content: content, details: .object(detailsObject))
    }
}

private extension ComputerUseSession {
    func performListApps() async throws -> ComputerUseToolResult {
        let apps = try await backend.listApps()
        let appDetails: [JSONValue] = apps.map { app in
            .object([
                "app": .string(app.appName),
                "bundleId": JSONValue.stringOrNull(app.bundleId),
                "pid": .number(Double(app.pid)),
                "isFrontmost": .bool(app.isFrontmost),
                "browserUseAllowed": .bool(config.browserUse || !isBrowserApp(appName: app.appName, bundleId: app.bundleId))
            ])
        }
        let lines = apps.map { app -> String in
            let flags = [
                app.isFrontmost ? "frontmost" : nil,
                (config.browserUse || !isBrowserApp(appName: app.appName, bundleId: app.bundleId)) ? nil : "browser_use_disabled"
            ].compactMap { $0 }.joined(separator: ", ")
            return "- \(app.appName)\(app.bundleId.map { " (\($0))" } ?? ""), pid \(app.pid)\(flags.isEmpty ? "" : " [\(flags)]")"
        }
        let text = lines.isEmpty
            ? "No running apps were available to ComputerUse."
            : "Found \(lines.count) running app\(lines.count == 1 ? "" : "s"). Use list_windows with app, bundleId, or pid to inspect target windows.\n\(lines.joined(separator: "\n"))"
        return ComputerUseToolResult(content: [.text(text)], details: .object([
            "tool": "list_apps",
            "apps": .array(appDetails),
            "config": .object([
                "browser_use": .bool(config.browserUse),
                "stealth_mode": .bool(config.stealthMode)
            ])
        ]))
    }

    func performListWindows(_ args: [String: JSONValue]) async throws -> ComputerUseToolResult {
        let allApps = try await backend.listApps()
        let apps = allApps.filter { appMatchesWindowQuery($0, args) }
        guard !apps.isEmpty else {
            throw ComputerUseError("No running app matched list_windows query. Call list_apps to inspect running apps.", code: "app_not_found")
        }

        var windows: [(JSONValue, String, Int)] = []
        for app in apps {
            for window in try await backend.listWindows(pid: app.pid) {
                let stored = storeWindowRefForAppWindow(app: app, window: window)
                let score = scoreWindow(window)
                let browserAllowed = config.browserUse || !isBrowserApp(appName: app.appName, bundleId: app.bundleId)
                let details: JSONValue = .object([
                    "app": .string(app.appName),
                    "bundleId": JSONValue.stringOrNull(app.bundleId),
                    "pid": .number(Double(app.pid)),
                    "windowTitle": .string(window.title.isEmpty ? "(untitled)" : window.title),
                    "windowId": window.windowId.map { .number(Double($0)) } ?? .null,
                    "windowRef": .string(stored.ref),
                    "nativeWindowRef": JSONValue.stringOrNull(window.nativeWindowRef),
                    "framePoints": window.framePoints.json,
                    "scaleFactor": .number(window.scaleFactor),
                    "isMinimized": .bool(window.isMinimized),
                    "isOnscreen": .bool(window.isOnscreen),
                    "isMain": .bool(window.isMain),
                    "isFocused": .bool(window.isFocused),
                    "browserUseAllowed": .bool(browserAllowed),
                    "score": .number(Double(score))
                ])
                let flags = [
                    window.isFocused ? "focused" : nil,
                    window.isMain ? "main" : nil,
                    window.isOnscreen ? "onscreen" : nil,
                    window.isMinimized ? "minimized" : nil,
                    browserAllowed ? nil : "browser_use_disabled"
                ].compactMap { $0 }.joined(separator: ", ")
                let frame = "\(Int(window.framePoints.x.rounded())),\(Int(window.framePoints.y.rounded())) \(Int(window.framePoints.w.rounded()))x\(Int(window.framePoints.h.rounded()))"
                let idText = window.windowId.map { "windowId \($0)" } ?? (window.nativeWindowRef.map { "nativeWindowRef \($0)" } ?? "unstable window id")
                let line = "- \(stored.ref) \(app.appName) - \(window.title.isEmpty ? "(untitled)" : window.title) (\(idText), pid \(app.pid), frame \(frame), score \(score)\(flags.isEmpty ? "" : ", \(flags)"))"
                windows.append((details, line, score))
            }
        }
        windows.sort { $0.2 > $1.2 }
        let text = windows.isEmpty
            ? "No controllable windows matched the query. Try opening a window, or call list_apps to confirm the app is running."
            : "Found \(windows.count) controllable window\(windows.count == 1 ? "" : "s"). Use the @w refs with screenshot({ window: \"@wN\" }) or action tools' optional window field.\n\(windows.map(\.1).joined(separator: "\n"))"
        return ComputerUseToolResult(content: [.text(text)], details: .object([
            "tool": "list_windows",
            "query": .object(args),
            "windows": .array(windows.map(\.0)),
            "config": .object([
                "browser_use": .bool(config.browserUse),
                "stealth_mode": .bool(config.stealthMode)
            ])
        ]))
    }

    func performScreenshot(_ args: [String: JSONValue]) async throws -> ComputerUseToolResult {
        currentImageMode = imageMode(args["image"])
        _ = try await resolveTargetForScreenshot(args)
        let capture = try await captureCurrentTarget()
        let summary = "Captured \(capture.target.windowRef.map { "\($0) " } ?? "")\(capture.target.appName) - \(capture.target.windowTitle). Returned the latest semantic window state."
        return try await buildToolResult(tool: "screenshot", summary: summary, result: capture, execution: executionTrace("screenshot", variant: "stealth", fallbackUsed: false), mode: currentImageMode)
    }
}

private extension ComputerUseSession {
    func dispatchClick(_ args: [String: JSONValue], capture: CurrentCapture, target: ResolvedTarget, forcedClickCount: Int? = nil) async throws -> ExecutionTrace {
        let ref = trimmedString(args["ref"])
        let x = finiteNumber(args["x"], fallback: .nan)
        let y = finiteNumber(args["y"], fallback: .nan)
        let button = normalizeMouseButton(args["button"])
        let clickCount = forcedClickCount ?? normalizeClickCount(args["clickCount"])

        if let ref {
            if button != .left {
                throw ComputerUseError("AX target refs only support left-button clicks. Use coordinates for \(button.rawValue)-click.", code: "invalid_args")
            }
            var axTarget = try axTargetByRef(ref)
            func attempt(_ candidate: AxTarget) async -> (pressed: Bool, focused: Bool) {
                var pressed = false
                for index in 0..<clickCount {
                    if (try? await backend.pressElement(elementRef: candidate.elementRef, pid: target.pid).performed) == true {
                        pressed = true
                    } else {
                        pressed = false
                        break
                    }
                    if index + 1 < clickCount {
                        try? await sleep(ms: 60)
                    }
                }
                var focused = false
                if !pressed, clickCount == 1 {
                    focused = (try? await backend.focusElement(elementRef: candidate.elementRef, pid: target.pid).focused) == true
                }
                return (pressed, focused)
            }
            var attemptResult = await attempt(axTarget)
            if !attemptResult.pressed, !attemptResult.focused, let reacquired = await reacquireAxTarget(axTarget, target: target) {
                axTarget = reacquired
                attemptResult = await attempt(axTarget)
            }
            guard attemptResult.pressed || attemptResult.focused else {
                throw ComputerUseError("AX click/focus could not be completed for \(ref).", code: "ax_action_failed")
            }
            return executionTrace(attemptResult.pressed ? "ax_press" : "ax_focus", variant: "stealth", axAttempted: true, axSucceeded: true, fallbackUsed: false)
        }

        guard x.isFinite, y.isFinite else {
            throw ComputerUseError("click requires either ref or both x and y.", code: "invalid_args")
        }
        try ensurePointIsInCapture(x, y, capture: capture)

        var pressedViaAX = false
        var focusedViaAX = false
        let canTryAX = button == .left && clickCount == 1
        if canTryAX {
            pressedViaAX = (try? await backend.pressAtPoint(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef, x: x, y: y, captureWidth: capture.width, captureHeight: capture.height).performed) == true
            if !pressedViaAX {
                focusedViaAX = (try? await backend.focusAtPoint(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef, x: x, y: y, captureWidth: capture.width, captureHeight: capture.height).focused) == true
            }
        }
        if !pressedViaAX, !focusedViaAX {
            if isStrictAxMode() {
                try strictModeBlock("AX click/focus could not be completed at (\(Int(x.rounded())),\(Int(y.rounded()))).")
            }
            try await backend.mouseClick(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef, x: x, y: y, captureWidth: capture.width, captureHeight: capture.height, button: button, clickCount: clickCount)
        }
        let usedAx = pressedViaAX || focusedViaAX
        return executionTrace(
            pressedViaAX ? "ax_press" : focusedViaAX ? "ax_focus" : clickCount > 1 ? "coordinate_event_double_click" : "coordinate_event_click",
            variant: usedAx ? "stealth" : "default",
            axAttempted: canTryAX,
            axSucceeded: usedAx,
            fallbackUsed: canTryAX && !usedAx,
            nonStealthReason: usedAx ? nil : "coordinate_mouse_click_requires_pointer_event"
        )
    }

    func runCoordinateAction(tool: String, capture: CurrentCapture, dispatch: (ResolvedTarget) async throws -> ExecutionTrace, summary: (ResolvedTarget) -> String) async throws -> ComputerUseToolResult {
        let current = try await resolveCurrentTarget()
        let target = try await ensureTargetWindowId(current)
        let execution = try await dispatch(target)
        try await sleep(ms: settleMs(for: execution))
        let captureResult = try await captureCurrentTarget()
        return try await buildToolResult(tool: tool, summary: summary(captureResult.target), result: captureResult, execution: execution)
    }

    func performClick(_ args: [String: JSONValue]) async throws -> ComputerUseToolResult {
        currentImageMode = imageMode(args["image"])
        try await selectWindowIfProvided(args["window"])
        let capture = try validateStateId(trimmedString(args["stateId"]))
        let ref = trimmedString(args["ref"])
        let x = finiteNumber(args["x"], fallback: .nan)
        let y = finiteNumber(args["y"], fallback: .nan)
        let button = normalizeMouseButton(args["button"])
        let clickCount = normalizeClickCount(args["clickCount"])
        return try await runCoordinateAction(tool: "click", capture: capture) { target in
            try await dispatchClick(args, capture: capture, target: target)
        } summary: { target in
            if let ref {
                let label = currentAxTargets?.first(where: { $0.ref == ref }).map(formatAxTargetLabel) ?? ref
                return "Clicked \(label) in \(target.appName) - \(target.windowTitle). Returned the latest semantic window state."
            }
            return "\(clickCount > 1 ? "Double-clicked" : button == .left ? "Clicked" : "\(button.rawValue)-clicked") at (\(Int(x.rounded())),\(Int(y.rounded()))) in \(target.appName) - \(target.windowTitle). Returned the latest semantic window state."
        }
    }

    func performDoubleClick(_ args: [String: JSONValue]) async throws -> ComputerUseToolResult {
        currentImageMode = imageMode(args["image"])
        try await selectWindowIfProvided(args["window"])
        let capture = try validateStateId(trimmedString(args["stateId"]))
        let ref = trimmedString(args["ref"])
        let x = finiteNumber(args["x"], fallback: .nan)
        let y = finiteNumber(args["y"], fallback: .nan)
        return try await runCoordinateAction(tool: "double_click", capture: capture) { target in
            try await dispatchClick(args, capture: capture, target: target, forcedClickCount: 2)
        } summary: { target in
            if let ref {
                let label = currentAxTargets?.first(where: { $0.ref == ref }).map(formatAxTargetLabel) ?? ref
                return "Double-clicked \(label) in \(target.appName) - \(target.windowTitle). Returned the latest semantic window state."
            }
            return "Double-clicked at (\(Int(x.rounded())),\(Int(y.rounded()))) in \(target.appName) - \(target.windowTitle). Returned the latest semantic window state."
        }
    }
}

private extension ComputerUseSession {
    func focusedTextElementRef(_ target: ResolvedTarget) async -> String? {
        guard let focused = try? await backend.focusedElement(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef),
              focused.exists,
              focused.isTextInput,
              focused.canSetValue,
              let elementRef = focused.elementRef else {
            return nil
        }
        return elementRef
    }

    func setAxValue(_ elementRef: String, text: String) async throws {
        try await backend.setValue(elementRef: elementRef, value: text)
    }

    func focusAxElement(_ elementRef: String, target: ResolvedTarget) async -> Bool {
        (try? await backend.focusElement(elementRef: elementRef, pid: target.pid).focused) == true
    }

    func focusControlledWindow(_ target: ResolvedTarget) async throws {
        let result = try await backend.focusWindow(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef)
        guard result.focused else {
            throw ComputerUseError("Unable to focus controlled window '\(target.windowTitle)' before input\(result.reason.map { ": \($0)" } ?? ".")", code: "focus_failed")
        }
    }

    func dispatchTypeText(_ text: String, target: ResolvedTarget) async throws -> ExecutionTrace {
        if allowNextTypeTextAxReplacement {
            allowNextTypeTextAxReplacement = false
            if let focused = await focusedTextElementRef(target) {
                try await setAxValue(focused, text: text)
                if isBrowserApp(appName: target.appName, bundleId: target.bundleId) {
                    pendingBrowserAddress = PendingBrowserAddress(text: text, pid: target.pid, windowId: target.windowId)
                }
                return executionTrace("ax_set_value", variant: "stealth", axAttempted: true, axSucceeded: true, fallbackUsed: false)
            }
        }
        if isStrictAxMode() {
            try strictModeBlock("Raw text insertion is not AX-only. Use set_text for AX value replacement.")
        }
        try await focusControlledWindow(target)
        try await backend.typeText(pid: target.pid, text: text)
        return executionTrace("raw_key_text", variant: "default", axAttempted: false, axSucceeded: false, fallbackUsed: false, nonStealthReason: "raw_text_insertion_requires_keyboard_focus")
    }

    func dispatchSetText(_ args: [String: JSONValue], target: ResolvedTarget) async throws -> ExecutionTrace {
        let text = args["text"]?.stringValue ?? ""
        if let ref = trimmedString(args["ref"]) {
            var axTarget = try axTargetByRef(ref)
            if axTarget.canSetValue {
                do {
                    try await setAxValue(axTarget.elementRef, text: text)
                    return executionTrace("ax_set_value", variant: "stealth", axAttempted: true, axSucceeded: true, fallbackUsed: false)
                } catch {
                    if let reacquired = await reacquireAxTarget(axTarget, target: target), reacquired.canSetValue {
                        axTarget = reacquired
                        try await setAxValue(axTarget.elementRef, text: text)
                        return executionTrace("ax_set_value", variant: "stealth", axAttempted: true, axSucceeded: true, fallbackUsed: false)
                    }
                    if isStrictAxMode() { throw error }
                }
            }
            if isStrictAxMode() {
                try strictModeBlock("AX target '\(ref)' does not expose a directly settable AX value.")
            }
            var focusedViaRef = await focusAxElement(axTarget.elementRef, target: target)
            if !focusedViaRef, let reacquired = await reacquireAxTarget(axTarget, target: target) {
                axTarget = reacquired
                focusedViaRef = await focusAxElement(axTarget.elementRef, target: target)
            }
            if focusedViaRef, let focused = await focusedTextElementRef(target) {
                try await setAxValue(focused, text: text)
                return executionTrace("ax_set_value", variant: "stealth", axAttempted: true, axSucceeded: true, fallbackUsed: false)
            }
        }

        if let focused = await focusedTextElementRef(target) {
            try await setAxValue(focused, text: text)
            return executionTrace("ax_set_value", variant: "stealth", axAttempted: true, axSucceeded: true, fallbackUsed: false)
        }
        if isStrictAxMode() {
            try strictModeBlock("set_text in stealth mode requires a text AX ref from the latest screenshot or an already-focused text control.")
        }
        try await focusControlledWindow(target)
        guard let focused = await focusedTextElementRef(target) else {
            throw ComputerUseError("AX value replacement requires a text AX ref or focused text control. Use set_text with ref from the latest screenshot when available.", code: "no_text_target")
        }
        try await setAxValue(focused, text: text)
        return executionTrace("ax_set_value", variant: "default", axAttempted: true, axSucceeded: true, fallbackUsed: true, nonStealthReason: "set_text_without_ref_requires_window_focus_fallback")
    }

    func performTypeText(_ args: [String: JSONValue]) async throws -> ComputerUseToolResult {
        currentImageMode = imageMode(args["image"])
        try await selectWindowIfProvided(args["window"])
        let text = args["text"]?.stringValue ?? ""
        let current = try await resolveCurrentTarget()
        let target = try await ensureTargetWindowId(current)
        let execution = try await dispatchTypeText(text, target: target)
        try await sleep(ms: settleMs(for: execution))
        let capture = try await captureCurrentTarget()
        return try await buildToolResult(tool: "type_text", summary: "Inserted text in \(capture.target.appName) - \(capture.target.windowTitle). Returned the latest semantic window state.", result: capture, execution: execution)
    }

    func performSetText(_ args: [String: JSONValue]) async throws -> ComputerUseToolResult {
        currentImageMode = imageMode(args["image"])
        try await selectWindowIfProvided(args["window"])
        let current = try await resolveCurrentTarget()
        let target = try await ensureTargetWindowId(current)
        let execution = try await dispatchSetText(args, target: target)
        try await sleep(ms: settleMs(for: execution))
        let capture = try await captureCurrentTarget()
        return try await buildToolResult(tool: "set_text", summary: "Set text value in \(capture.target.appName) - \(capture.target.windowTitle). Returned the latest semantic window state.", result: capture, execution: execution)
    }
}

private extension ComputerUseSession {
    func isCommandL(_ keys: [String]) -> Bool {
        keys.count == 1 && keys[0].replacingOccurrences(of: "\\s+", with: "", options: .regularExpression).range(of: #"^(cmd|command|meta)\+l$"#, options: .regularExpression) != nil
    }

    func focusBrowserAddressField(keys: [String], target: ResolvedTarget) async -> Bool {
        guard isCommandL(keys), isBrowserApp(appName: target.appName, bundleId: target.bundleId) else { return false }
        if (try? await backend.focusTextInput(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef).focused) == true {
            allowNextTypeTextAxReplacement = true
            return true
        }
        guard let result = try? await backend.listAxTargets(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef, limit: 50) else {
            return false
        }
        let refreshed = parseAxTargets(result)
        currentAxTargets = refreshed
        guard let field = refreshed
            .filter({ $0.canFocus && $0.isTextInput && ($0.role == "AXTextField" || $0.role == "AXSearchField") })
            .sorted(by: { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y })
            .first else {
            return false
        }
        let focused = await focusAxElement(field.elementRef, target: target)
        if focused { allowNextTypeTextAxReplacement = true }
        return focused
    }

    func semanticActionsForKeys(_ keys: [String]) -> [String] {
        guard keys.count == 1 else { return [] }
        let key = keys[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key == "enter" || key == "return" { return ["confirm", "press"] }
        if key == "escape" || key == "esc" { return ["cancel"] }
        if key == "space" || key == "spacebar" || key == " " { return ["press"] }
        return []
    }

    func windowButtonForSemanticKey(_ keys: [String], targets: [AxTarget]) -> AxTarget? {
        guard keys.count == 1 else { return nil }
        let key = keys[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let buttons = targets.filter { $0.canPress && $0.role == "AXButton" }
        if key == "escape" || key == "esc" {
            return buttons.first { ["cancel", "don't save", "dont save"].contains(axTargetLabelKey($0)) }
        }
        if key == "enter" || key == "return" {
            return buttons.first { normalizeText($0.subrole).contains("default") } ??
                buttons.first { ["ok", "done", "save", "add", "continue", "open", "choose"].contains(axTargetLabelKey($0)) }
        }
        return nil
    }

    func tryWindowAxKeyAction(keys: [String], target: ResolvedTarget) async -> Bool {
        guard let result = try? await backend.listAxTargets(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef, limit: 50) else {
            return false
        }
        let refreshed = parseAxTargets(result)
        currentAxTargets = refreshed
        guard let button = windowButtonForSemanticKey(keys, targets: refreshed) else { return false }
        return (try? await backend.performAction(elementRef: button.elementRef, pid: target.pid, action: "press").performed) == true
    }

    func tryFocusedAxKeyAction(keys: [String], target: ResolvedTarget) async -> Bool {
        let actions = semanticActionsForKeys(keys)
        guard !actions.isEmpty else { return false }
        if let focused = await focusedTextElementRef(target) {
            for action in actions {
                if (try? await backend.performAction(elementRef: focused, pid: target.pid, action: action).performed) == true {
                    return true
                }
            }
            return await tryWindowAxKeyAction(keys: keys, target: target)
        }
        if let rawFocused = try? await backend.focusedElement(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef),
           rawFocused.exists,
           let elementRef = rawFocused.elementRef {
            for action in actions {
                if (try? await backend.performAction(elementRef: elementRef, pid: target.pid, action: action).performed) == true {
                    return true
                }
            }
        }
        return await tryWindowAxKeyAction(keys: keys, target: target)
    }

    func openBrowserLocationFromPendingAddress(keys: [String], target: ResolvedTarget) async throws -> Bool {
        let isEnter = keys.count == 1 && ["enter", "return"].contains(keys[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        guard let pendingBrowserAddress else { return false }
        if !isEnter {
            self.pendingBrowserAddress = nil
            return false
        }
        guard pendingBrowserAddress.pid == target.pid, pendingBrowserAddress.windowId == target.windowId else {
            self.pendingBrowserAddress = nil
            return false
        }
        let opened = try await backend.openBrowserLocation(appName: target.appName, bundleId: target.bundleId, url: pendingBrowserAddress.text)
        self.pendingBrowserAddress = nil
        return opened
    }

    func dispatchKeypress(_ args: [String: JSONValue], target: ResolvedTarget) async throws -> ExecutionTrace {
        let keys = normalizeKeyList(args["keys"])
        guard !keys.isEmpty else {
            throw ComputerUseError("keypress.keys must contain at least one key.", code: "invalid_args")
        }
        if try await openBrowserLocationFromPendingAddress(keys: keys, target: target) {
            return executionTrace("browser_open_location", variant: "stealth", axAttempted: true, axSucceeded: true, fallbackUsed: false)
        }
        if await focusBrowserAddressField(keys: keys, target: target) {
            return executionTrace("ax_focus", variant: "stealth", axAttempted: true, axSucceeded: true, fallbackUsed: false)
        }
        if await tryFocusedAxKeyAction(keys: keys, target: target) {
            return executionTrace("ax_action", variant: "stealth", axAttempted: true, axSucceeded: true, fallbackUsed: false)
        }
        if isStrictAxMode() {
            try strictModeBlock("Keypress is not AX-only and no semantic AX equivalent was available.")
        }
        try await focusControlledWindow(target)
        try await backend.keyPress(pid: target.pid, keys: keys)
        let attempted = !semanticActionsForKeys(keys).isEmpty
        return executionTrace("raw_keypress", variant: "default", axAttempted: attempted, axSucceeded: false, fallbackUsed: attempted, nonStealthReason: "keypress_requires_keyboard_focus")
    }

    func performKeypress(_ args: [String: JSONValue]) async throws -> ComputerUseToolResult {
        currentImageMode = imageMode(args["image"])
        try await selectWindowIfProvided(args["window"])
        let keys = normalizeKeyList(args["keys"])
        let current = try await resolveCurrentTarget()
        let target = try await ensureTargetWindowId(current)
        let execution = try await dispatchKeypress(args, target: target)
        try await sleep(ms: settleMs(for: execution))
        let capture = try await captureCurrentTarget()
        return try await buildToolResult(tool: "keypress", summary: "Pressed \(keys.count) key\(keys.count == 1 ? "" : "s") in \(capture.target.appName) - \(capture.target.windowTitle). Returned the latest semantic window state.", result: capture, execution: execution)
    }
}

private extension ComputerUseSession {
    func scrollStepCount(_ delta: Int) -> Int {
        max(1, min(8, Int(ceil(Double(abs(delta)) / 500.0))))
    }

    func dispatchScroll(_ args: [String: JSONValue], capture: CurrentCapture, target: ResolvedTarget) async throws -> ExecutionTrace {
        let ref = trimmedString(args["ref"])
        let x = finiteNumber(args["x"], fallback: .nan)
        let y = finiteNumber(args["y"], fallback: .nan)
        let scrollX = normalizeScrollDelta(args["scrollX"])
        let scrollY = normalizeScrollDelta(args["scrollY"])
        guard scrollX != 0 || scrollY != 0 else {
            throw ComputerUseError("scroll requires a non-zero scrollX or scrollY.", code: "invalid_args")
        }
        let steps = max(scrollStepCount(scrollX), scrollStepCount(scrollY))
        var axScrolled = false
        var reason: String?
        if let ref {
            let axTarget = try axTargetByRef(ref)
            let result = try? await backend.scrollElement(elementRef: axTarget.elementRef, pid: target.pid, scrollX: scrollX, scrollY: scrollY, steps: steps)
            axScrolled = result?.scrolled == true
            reason = result?.reason
            if !axScrolled, let reacquired = await reacquireAxTarget(axTarget, target: target) {
                let retry = try? await backend.scrollElement(elementRef: reacquired.elementRef, pid: target.pid, scrollX: scrollX, scrollY: scrollY, steps: steps)
                axScrolled = retry?.scrolled == true
                reason = retry?.reason ?? reason
            }
        } else if x.isFinite, y.isFinite {
            try ensurePointIsInCapture(x, y, capture: capture)
            let result = try? await backend.scrollAtPoint(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef, x: x, y: y, captureWidth: capture.width, captureHeight: capture.height, scrollX: scrollX, scrollY: scrollY, steps: steps)
            axScrolled = result?.scrolled == true
            reason = result?.reason
        } else {
            throw ComputerUseError("scroll requires either ref or both x and y. If the target came from an old state, call screenshot again and retry with a current @e scroll ref or coordinates.", code: "invalid_args")
        }
        if axScrolled {
            return executionTrace("ax_scroll", variant: "stealth", axAttempted: true, axSucceeded: true, fallbackUsed: false)
        }
        let reasonText = reason.map { " Reason: \($0)." } ?? ""
        if isStrictAxMode() {
            try strictModeBlock(ref.map { "AX scroll could not be completed for \($0).\(reasonText)" } ?? "AX scroll could not be completed at (\(Int(x.rounded())),\(Int(y.rounded()))).\(reasonText)")
        }
        guard x.isFinite, y.isFinite else {
            throw ComputerUseError("Coordinate scroll fallback requires x and y.\(reasonText) Provide coordinates from the latest screenshot or use a current AX scroll target.", code: "invalid_args")
        }
        try ensurePointIsInCapture(x, y, capture: capture)
        try await backend.scrollWheel(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef, x: x, y: y, captureWidth: capture.width, captureHeight: capture.height, scrollX: scrollX, scrollY: scrollY)
        return executionTrace("coordinate_event_scroll", variant: "default", axAttempted: true, axSucceeded: false, fallbackUsed: true, nonStealthReason: "coordinate_scroll_requires_pointer_event")
    }

    func dispatchMoveMouse(_ args: [String: JSONValue], capture: CurrentCapture, target: ResolvedTarget) async throws -> ExecutionTrace {
        if isStrictAxMode() {
            try strictModeBlock("Mouse movement is not AX-only.")
        }
        let x = finiteNumber(args["x"], fallback: .nan)
        let y = finiteNumber(args["y"], fallback: .nan)
        try ensurePointIsInCapture(x, y, capture: capture)
        try await backend.mouseMove(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef, x: x, y: y, captureWidth: capture.width, captureHeight: capture.height)
        return executionTrace("coordinate_event_move", variant: "default", axAttempted: false, axSucceeded: false, fallbackUsed: false, nonStealthReason: "mouse_move_requires_cursor_control")
    }

    func dragAdjustment(path: [CGPointValue]?) -> (action: String, steps: Int)? {
        guard let path, path.count >= 2, let first = path.first, let last = path.last else { return nil }
        let dx = last.x - first.x
        let dy = last.y - first.y
        let primary = abs(dx) >= abs(dy) ? dx : -dy
        if abs(primary) < 4 { return nil }
        return (primary > 0 ? "increment" : "decrement", max(1, min(20, Int((abs(primary) / 20).rounded()))))
    }

    func dispatchDrag(_ args: [String: JSONValue], capture: CurrentCapture, target: ResolvedTarget) async throws -> ExecutionTrace {
        let path = args["path"] == nil ? nil : try normalizeDragPath(args["path"], capture: capture)
        let ref = trimmedString(args["ref"])
        var adjustedViaAX = false
        if let ref, let path {
            let axTarget = try axTargetByRef(ref)
            if let adjustment = dragAdjustment(path: path),
               (adjustment.action == "increment" ? axTarget.canIncrement : axTarget.canDecrement) {
                var performed = false
                for _ in 0..<adjustment.steps {
                    guard (try? await backend.performAction(elementRef: axTarget.elementRef, pid: target.pid, action: adjustment.action).performed) == true else {
                        break
                    }
                    performed = true
                }
                adjustedViaAX = performed
            }
        }
        if adjustedViaAX {
            return executionTrace("ax_action", variant: "stealth", axAttempted: true, axSucceeded: true, fallbackUsed: false)
        }
        if isStrictAxMode() {
            try strictModeBlock(ref.map { "AX adjustment could not be completed for \($0)." } ?? "Drag is not AX-only.")
        }
        guard let path else {
            throw ComputerUseError("drag requires path points for pointer fallback or a ref plus path for AX adjustment.", code: "invalid_args")
        }
        try await backend.mouseDrag(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef, path: path, captureWidth: capture.width, captureHeight: capture.height)
        return executionTrace("coordinate_event_drag", variant: "default", axAttempted: ref != nil, axSucceeded: false, fallbackUsed: ref != nil, nonStealthReason: "drag_requires_pointer_event")
    }

    func performScroll(_ args: [String: JSONValue]) async throws -> ComputerUseToolResult {
        currentImageMode = imageMode(args["image"])
        try await selectWindowIfProvided(args["window"])
        let capture = try validateStateId(trimmedString(args["stateId"]))
        let ref = trimmedString(args["ref"])
        let x = finiteNumber(args["x"], fallback: .nan)
        let y = finiteNumber(args["y"], fallback: .nan)
        return try await runCoordinateAction(tool: "scroll", capture: capture) { target in
            try await dispatchScroll(args, capture: capture, target: target)
        } summary: { target in
            ref.map { "Scrolled \($0) in \(target.appName) - \(target.windowTitle). Returned the latest semantic window state." } ??
                "Scrolled at (\(Int(x.rounded())),\(Int(y.rounded()))) in \(target.appName) - \(target.windowTitle). Returned the latest semantic window state."
        }
    }

    func performMoveMouse(_ args: [String: JSONValue]) async throws -> ComputerUseToolResult {
        currentImageMode = imageMode(args["image"])
        try await selectWindowIfProvided(args["window"])
        let capture = try validateStateId(trimmedString(args["stateId"]))
        return try await runCoordinateAction(tool: "move_mouse", capture: capture) { target in
            try await dispatchMoveMouse(args, capture: capture, target: target)
        } summary: { target in
            "Moved mouse to (\(Int(finiteNumber(args["x"], fallback: .nan).rounded())),\(Int(finiteNumber(args["y"], fallback: .nan).rounded()))) in \(target.appName) - \(target.windowTitle). Returned the latest semantic window state."
        }
    }

    func performDrag(_ args: [String: JSONValue]) async throws -> ComputerUseToolResult {
        currentImageMode = imageMode(args["image"])
        try await selectWindowIfProvided(args["window"])
        let capture = try validateStateId(trimmedString(args["stateId"]))
        return try await runCoordinateAction(tool: "drag", capture: capture) { target in
            try await dispatchDrag(args, capture: capture, target: target)
        } summary: { target in
            "Dragged in \(target.appName) - \(target.windowTitle). Returned the latest semantic window state."
        }
    }
}

private extension ComputerUseSession {
    func frameForArrangePreset(_ args: [String: JSONValue], target: ResolvedTarget) -> (x: Double, y: Double, width: Double, height: Double) {
        switch args["preset"]?.stringValue {
        case "left_half":
            return (0, 25, 720, 875)
        case "right_half":
            return (720, 25, 720, 875)
        case "top_half":
            return (80, 25, 1200, 440)
        case "bottom_half":
            return (80, 465, 1200, 435)
        case "center_large":
            return (80, 80, 1200, 800)
        default:
            return (
                finiteNumber(args["x"], fallback: target.framePoints.x),
                finiteNumber(args["y"], fallback: target.framePoints.y),
                finiteNumber(args["width"], fallback: target.framePoints.w),
                finiteNumber(args["height"], fallback: target.framePoints.h)
            )
        }
    }

    func performArrangeWindow(_ args: [String: JSONValue]) async throws -> ComputerUseToolResult {
        currentImageMode = imageMode(args["image"])
        try await selectWindowIfProvided(args["window"])
        let current = try await resolveCurrentTarget()
        let target = try await ensureTargetWindowId(current)
        let frame = frameForArrangePreset(args, target: target)
        guard [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite), frame.width >= 100, frame.height >= 80 else {
            throw ComputerUseError("arrange_window requires finite x, y, width, and height values, or a supported preset.", code: "invalid_args")
        }
        let result = try await backend.setWindowFrame(pid: target.pid, windowId: target.windowId, nativeWindowRef: target.nativeWindowRef, x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        guard result.ok else {
            throw ComputerUseError("Unable to arrange window\(result.reason.map { ": \($0)" } ?? ".")", code: "arrange_failed")
        }
        try await sleep(ms: actionSettleMs)
        let capture = try await captureCurrentTarget()
        return try await buildToolResult(
            tool: "arrange_window",
            summary: "Arranged \(capture.target.windowRef.map { "\($0) " } ?? "")\(capture.target.appName) - \(capture.target.windowTitle). Returned the latest semantic window state.",
            result: capture,
            execution: executionTrace("window_frame", variant: "stealth", fallbackUsed: false)
        )
    }

    func performNavigateBrowser(_ args: [String: JSONValue]) async throws -> ComputerUseToolResult {
        currentImageMode = imageMode(args["image"])
        try await selectWindowIfProvided(args["window"])
        let current = try await resolveCurrentTarget()
        let target = try await ensureTargetWindowId(current)
        try assertBrowserUseAllowed(target.appName, target.bundleId)
        guard isBrowserApp(appName: target.appName, bundleId: target.bundleId) else {
            throw ComputerUseError("navigate_browser requires a browser window, but the target is '\(target.appName)'.", code: "not_browser")
        }
        guard let url = trimmedString(args["url"]) else {
            throw ComputerUseError("navigate_browser.url must be a non-empty URL or browser-search string.", code: "invalid_args")
        }
        let opened = try await backend.openBrowserLocation(appName: target.appName, bundleId: target.bundleId, url: url)
        guard opened else {
            throw ComputerUseError("navigate_browser does not yet support direct URL navigation for '\(target.appName)'. Use keypress Command+L, type_text, Enter instead.", code: "unsupported_browser")
        }
        try await sleep(ms: actionSettleMs)
        let capture = try await captureCurrentTarget()
        return try await buildToolResult(
            tool: "navigate_browser",
            summary: "Navigated \(capture.target.windowRef.map { "\($0) " } ?? "")\(capture.target.appName) - \(capture.target.windowTitle). Returned the latest semantic window state.",
            result: capture,
            execution: executionTrace("browser_open_location", variant: "stealth", axAttempted: false, axSucceeded: false, fallbackUsed: false)
        )
    }

    func performWait(_ args: [String: JSONValue]) async throws -> ComputerUseToolResult {
        currentImageMode = imageMode(args["image"])
        try await selectWindowIfProvided(args["window"])
        guard currentTarget != nil else {
            throw ComputerUseError("No current controlled window. Call screenshot first to choose a target window.", code: "missing_target")
        }
        let msRaw = finiteNumber(args["ms"], fallback: Double(defaultWaitMs))
        guard msRaw.isFinite, msRaw >= 0 else {
            throw ComputerUseError("wait.ms must be a non-negative number.", code: "invalid_args")
        }
        let ms = min(60_000, Int(msRaw.rounded()))
        try await sleep(ms: ms)
        let capture = try await captureCurrentTarget()
        return try await buildToolResult(tool: "wait", summary: "Waited \(ms)ms in \(capture.target.appName) - \(capture.target.windowTitle). Returned the latest semantic window state.", result: capture, execution: executionTrace("wait", variant: "stealth", fallbackUsed: false))
    }
}

private extension ComputerUseSession {
    func dispatchComputerAction(_ action: [String: JSONValue], capture: CurrentCapture, target: ResolvedTarget) async throws -> ExecutionTrace {
        guard let type = action["type"]?.stringValue else {
            throw ComputerUseError("computer_actions action is missing a valid type.", code: "invalid_args")
        }
        switch type {
        case "click":
            return try await dispatchClick(action, capture: capture, target: target)
        case "double_click":
            return try await dispatchClick(action, capture: capture, target: target, forcedClickCount: 2)
        case "move_mouse":
            return try await dispatchMoveMouse(action, capture: capture, target: target)
        case "drag":
            return try await dispatchDrag(action, capture: capture, target: target)
        case "scroll":
            return try await dispatchScroll(action, capture: capture, target: target)
        case "keypress":
            return try await dispatchKeypress(action, target: target)
        case "type_text":
            return try await dispatchTypeText(action["text"]?.stringValue ?? "", target: target)
        case "set_text":
            return try await dispatchSetText(action, target: target)
        case "wait":
            let msRaw = finiteNumber(action["ms"], fallback: Double(defaultWaitMs))
            guard msRaw.isFinite, msRaw >= 0 else {
                throw ComputerUseError("wait.ms must be a non-negative number.", code: "invalid_args")
            }
            try await sleep(ms: min(60_000, Int(msRaw.rounded())))
            return executionTrace("wait", variant: "stealth", fallbackUsed: false)
        default:
            throw ComputerUseError("Unsupported computer action '\(type)'.", code: "invalid_args")
        }
    }

    func actionWindowMatchesTarget(_ selector: JSONValue?, target: ResolvedTarget) -> Bool {
        guard let normalized = normalizeWindowSelector(selector) else { return true }
        if target.windowRef == normalized { return true }
        if let numeric = Int(normalized), numeric > 0, target.windowId == UInt32(numeric) { return true }
        return false
    }

    func performComputerActions(_ args: [String: JSONValue]) async throws -> ComputerUseToolResult {
        currentImageMode = imageMode(args["image"])
        try await selectWindowIfProvided(args["window"])
        let capture = try validateStateId(trimmedString(args["stateId"]))
        let actionValues = args["actions"]?.arrayValue ?? []
        guard !actionValues.isEmpty else {
            throw ComputerUseError("computer_actions.actions must contain at least one action.", code: "invalid_args")
        }
        guard actionValues.count <= batchMaxActions else {
            throw ComputerUseError("computer_actions supports at most \(batchMaxActions) actions per call.", code: "too_many_actions")
        }
        let actions = try actionValues.enumerated().map { index, value -> [String: JSONValue] in
            guard let object = value.objectValue, object["type"]?.stringValue != nil else {
                throw ComputerUseError("computer_actions action \(index + 1) is missing a valid type.", code: "invalid_args")
            }
            return object
        }

        let current = try await resolveCurrentTarget()
        let target = try await ensureTargetWindowId(current)
        var axAttempted = false
        var axSucceeded = false
        var fallbackUsed = false
        var stealthCompatible = true
        var reasons = Set<String>()
        var traces: [BatchActionTrace] = []

        for (offset, action) in actions.enumerated() {
            guard actionWindowMatchesTarget(action["window"], target: target) else {
                throw ComputerUseError("computer_actions action \(offset + 1) targets a different window. Use one computer_actions call per window, or set the top-level window field to the intended target.", code: "target_mismatch")
            }
            if let actionStateId = trimmedString(action["stateId"]), actionStateId != capture.stateId {
                throw ComputerUseError("computer_actions action \(offset + 1) uses stale state '\(actionStateId)'. Refresh with screenshot and retry.", code: "stale_state")
            }
            let started = Date()
            let trace: ExecutionTrace
            do {
                trace = try await dispatchComputerAction(action, capture: capture, target: target)
            } catch {
                let type = action["type"]?.stringValue ?? "unknown"
                throw ComputerUseError("computer_actions action \(offset + 1) (\(type)) failed: \(error.localizedDescription)", code: "batch_action_failed")
            }
            traces.append(BatchActionTrace(
                index: offset + 1,
                type: action["type"]?.stringValue ?? "unknown",
                strategy: trace.strategy,
                durationMs: max(0, Int(Date().timeIntervalSince(started) * 1000)),
                axAttempted: trace.axAttempted,
                axSucceeded: trace.axSucceeded,
                fallbackUsed: trace.fallbackUsed,
                runtimeMode: trace.runtimeMode,
                variant: trace.variant,
                stealthCompatible: trace.stealthCompatible,
                nonStealthReason: trace.nonStealthReason
            ))
            axAttempted = axAttempted || trace.axAttempted == true
            axSucceeded = axSucceeded || trace.axSucceeded == true
            fallbackUsed = fallbackUsed || trace.fallbackUsed == true
            stealthCompatible = stealthCompatible && trace.stealthCompatible
            if let reason = trace.nonStealthReason {
                reasons.insert(reason)
            }
            if offset + 1 < actions.count, action["type"]?.stringValue != "wait" {
                try await sleep(ms: batchActionGapMs)
            }
        }

        let execution = executionTrace(
            "batch",
            variant: stealthCompatible ? "stealth" : "default",
            axAttempted: axAttempted,
            axSucceeded: axSucceeded,
            fallbackUsed: fallbackUsed,
            nonStealthReason: reasons.isEmpty ? nil : reasons.sorted().joined(separator: ","),
            actionCount: actions.count,
            completedActionCount: traces.count,
            actions: traces
        )
        try await sleep(ms: settleMs(for: execution))
        let captureResult = try await captureCurrentTarget()
        return try await buildToolResult(tool: "computer_actions", summary: "Executed \(actions.count) computer action\(actions.count == 1 ? "" : "s") in \(captureResult.target.appName) - \(captureResult.target.windowTitle). Returned the latest semantic window state.", result: captureResult, execution: execution)
    }
}

private enum DefaultBackendFactory {
    static func makeBackend() -> any ComputerUseBackend {
        #if os(macOS)
        return MacOSComputerUseBackend()
        #else
        return UnsupportedComputerUseBackend()
        #endif
    }
}

private struct UnsupportedComputerUseBackend: ComputerUseBackend {
    func checkPermissions() async -> ComputerUsePermissionStatus { ComputerUsePermissionStatus(accessibility: false, screenRecording: false) }
    func openPermissionPane(_ kind: ComputerUsePermissionKind) async throws { throw unsupported() }
    func listApps() async throws -> [BackendApp] { throw unsupported() }
    func listWindows(pid: Int32) async throws -> [BackendWindow] { throw unsupported() }
    func getFrontmost() async throws -> BackendFrontmost { throw unsupported() }
    func focusWindow(pid: Int32, windowId: UInt32?, nativeWindowRef: String?) async throws -> FocusWindowResult { throw unsupported() }
    func setWindowFrame(pid: Int32, windowId: UInt32?, nativeWindowRef: String?, x: Double, y: Double, width: Double, height: Double) async throws -> (ok: Bool, reason: String?, frame: FramePoints?) { throw unsupported() }
    func screenshot(windowId: UInt32) async throws -> ScreenshotPayload { throw unsupported() }
    func listAxTargets(pid: Int32, windowId: UInt32?, nativeWindowRef: String?, limit: Int) async throws -> AxListResult { throw unsupported() }
    func pressElement(elementRef: String, pid: Int32) async throws -> AxActionResult { throw unsupported() }
    func performAction(elementRef: String, pid: Int32, action: String) async throws -> AxActionResult { throw unsupported() }
    func focusElement(elementRef: String, pid: Int32) async throws -> AxFocusResult { throw unsupported() }
    func pressAtPoint(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int) async throws -> AxActionResult { throw unsupported() }
    func focusAtPoint(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int) async throws -> AxFocusResult { throw unsupported() }
    func scrollElement(elementRef: String, pid: Int32, scrollX: Int, scrollY: Int, steps: Int) async throws -> AxScrollResult { throw unsupported() }
    func scrollAtPoint(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int, scrollX: Int, scrollY: Int, steps: Int) async throws -> AxScrollResult { throw unsupported() }
    func focusedElement(pid: Int32, windowId: UInt32?, nativeWindowRef: String?) async throws -> FocusedElementResult { throw unsupported() }
    func setValue(elementRef: String, value: String) async throws { throw unsupported() }
    func focusTextInput(pid: Int32, windowId: UInt32?, nativeWindowRef: String?) async throws -> AxFocusResult { throw unsupported() }
    func mouseClick(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int, button: MouseButtonName, clickCount: Int) async throws { throw unsupported() }
    func mouseMove(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int) async throws { throw unsupported() }
    func mouseDrag(pid: Int32, windowId: UInt32, nativeWindowRef: String?, path: [CGPointValue], captureWidth: Int, captureHeight: Int) async throws { throw unsupported() }
    func scrollWheel(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int, scrollX: Int, scrollY: Int) async throws { throw unsupported() }
    func keyPress(pid: Int32, keys: [String]) async throws { throw unsupported() }
    func typeText(pid: Int32, text: String) async throws { throw unsupported() }
    func openBrowserLocation(appName: String, bundleId: String?, url: String) async throws -> Bool { throw unsupported() }
    private func unsupported() -> ComputerUseError { ComputerUseError("ComputerUse currently supports macOS only.", code: "unsupported_platform") }
}
