#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

final class MacOSComputerUseBackend: ComputerUseBackend, @unchecked Sendable {
    private final class AXRefStore: @unchecked Sendable {
        private let lock = NSLock()
        private var nextId: UInt64 = 0
        private var windows: [String: AXUIElement] = [:]
        private var elements: [String: AXUIElement] = [:]

        func storeWindow(_ window: AXUIElement) -> String {
            lock.lock()
            defer { lock.unlock() }
            nextId += 1
            let ref = "w\(nextId)"
            windows[ref] = window
            return ref
        }

        func storeElement(_ element: AXUIElement) -> String {
            lock.lock()
            defer { lock.unlock() }
            nextId += 1
            let ref = "e\(nextId)"
            elements[ref] = element
            return ref
        }

        func window(for ref: String) -> AXUIElement? {
            lock.lock()
            defer { lock.unlock() }
            return windows[ref]
        }

        func element(for ref: String) -> AXUIElement? {
            lock.lock()
            defer { lock.unlock() }
            return elements[ref]
        }
    }

    struct CGWindowCandidate {
        var windowId: UInt32
        var title: String
        var bounds: CGRect
        var isOnscreen: Bool
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) {
            self.value = value
        }
    }

    private let refStore = AXRefStore()

    func checkPermissions() async -> ComputerUsePermissionStatus {
        let accessibility = AXIsProcessTrusted()
        let screenRecording: Bool
        if #available(macOS 10.15, *) {
            screenRecording = CGPreflightScreenCaptureAccess()
        } else {
            screenRecording = true
        }
        return ComputerUsePermissionStatus(accessibility: accessibility, screenRecording: screenRecording)
    }

    func openPermissionPane(_ kind: ComputerUsePermissionKind) async throws {
        let urlString: String
        switch kind {
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
        guard let url = URL(string: urlString), NSWorkspace.shared.open(url) else {
            throw ComputerUseError("Failed to open \(kind.rawValue) permission pane.", code: "open_permission_pane_failed")
        }
    }

    func listApps() async throws -> [BackendApp] {
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app in
                BackendApp(
                    appName: app.localizedName ?? "Unknown App",
                    bundleId: app.bundleIdentifier,
                    pid: app.processIdentifier,
                    isFrontmost: app.processIdentifier == frontmostPid
                )
            }
    }

    func getFrontmost() async throws -> BackendFrontmost {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw ComputerUseError("No frontmost app available.", code: "frontmost_unavailable")
        }
        let windows = try await listWindows(pid: app.processIdentifier)
        let chosen = windows.sorted { scoreWindow($0) > scoreWindow($1) }.first
        return BackendFrontmost(
            appName: app.localizedName ?? "Unknown App",
            bundleId: app.bundleIdentifier,
            pid: app.processIdentifier,
            windowTitle: chosen?.title,
            windowId: chosen?.windowId,
            nativeWindowRef: chosen?.nativeWindowRef
        )
    }

    func listWindows(pid: Int32) async throws -> [BackendWindow] {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        let windows = axElementArray(appElement, attribute: kAXWindowsAttribute as CFString)
        let candidates = cgWindowCandidates(pid: pid)
        var usedIds = Set<UInt32>()

        var output: [BackendWindow] = []
        for window in windows {
            let axTitle = stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? ""
            let axFrame = frameForWindow(window)
            let candidate = bestCandidate(frame: axFrame, title: axTitle, candidates: candidates, usedIds: usedIds)
            if let candidate {
                usedIds.insert(candidate.windowId)
            }

            let effectiveFrame = axFrame.width > 1 && axFrame.height > 1 ? axFrame : (candidate?.bounds ?? axFrame)
            if effectiveFrame.width < 100 || effectiveFrame.height < 80 { continue }
            let hasUsableAXFrame = axFrame.width > 1 && axFrame.height > 1
            let title = hasUsableAXFrame && !axTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? axTitle
                : ((candidate?.title.isEmpty == false) ? candidate!.title : axTitle)
            let windowRef = refStore.storeWindow(window)
            output.append(BackendWindow(
                windowId: candidate?.windowId,
                nativeWindowRef: windowRef,
                title: title,
                framePoints: FramePoints(x: effectiveFrame.origin.x, y: effectiveFrame.origin.y, w: effectiveFrame.width, h: effectiveFrame.height),
                scaleFactor: displayScaleFactor(for: effectiveFrame),
                isMinimized: boolAttribute(window, attribute: kAXMinimizedAttribute as CFString) ?? false,
                isOnscreen: candidate?.isOnscreen ?? !(boolAttribute(window, attribute: kAXMinimizedAttribute as CFString) ?? false),
                isMain: boolAttribute(window, attribute: kAXMainAttribute as CFString) ?? false,
                isFocused: boolAttribute(window, attribute: kAXFocusedAttribute as CFString) ?? false
            ))
        }
        return output
    }

    func focusWindow(pid: Int32, windowId: UInt32?, nativeWindowRef: String?) async throws -> FocusWindowResult {
        guard let window = windowElement(pid: pid, windowId: windowId, windowRef: nativeWindowRef) else {
            return FocusWindowResult(focused: false, reason: "window_not_found")
        }
        let appElement = AXUIElementCreateApplication(pid)
        if let focusedWindow = copyAttribute(appElement, attribute: kAXFocusedWindowAttribute as CFString).flatMap(asAXElement),
           sameElement(focusedWindow, window) {
            return FocusWindowResult(focused: true, reason: nil)
        }
        let setMainStatus = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let setFocusedStatus = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let raiseStatus = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let focused = setMainStatus == .success || setFocusedStatus == .success || raiseStatus == .success
        return FocusWindowResult(focused: focused, reason: focused ? nil : "focus_failed")
    }

    func setWindowFrame(pid: Int32, windowId: UInt32?, nativeWindowRef: String?, x: Double, y: Double, width: Double, height: Double) async throws -> (ok: Bool, reason: String?, frame: FramePoints?) {
        guard let window = windowElement(pid: pid, windowId: windowId, windowRef: nativeWindowRef) else {
            return (false, "window_not_found", nil)
        }
        var origin = CGPoint(x: x, y: y)
        var size = CGSize(width: max(100, width), height: max(80, height))
        guard let originValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw ComputerUseError("Failed to create AX frame values.", code: "frame_value_failed")
        }
        let positionStatus = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
        let sizeStatus = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let frame = frameForWindow(window)
        return (
            positionStatus == .success || sizeStatus == .success,
            nil,
            FramePoints(x: frame.origin.x, y: frame.origin.y, w: frame.width, h: frame.height)
        )
    }

    func screenshot(windowId: UInt32) async throws -> ScreenshotPayload {
        try await captureWindow(windowId: windowId)
    }
}

extension MacOSComputerUseBackend {
    func listAxTargets(pid: Int32, windowId: UInt32?, nativeWindowRef: String?, limit: Int) async throws -> AxListResult {
        guard let window = windowElement(pid: pid, windowId: windowId, windowRef: nativeWindowRef) else {
            return AxListResult(targets: [], reason: "window_not_found")
        }
        let boundedLimit = max(1, min(50, limit))
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXComboBox", "AXEditableText", "AXSecureTextField"]
        let structuralRoles: Set<String> = ["AXApplication", "AXWindow", "AXToolbar", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXTabGroup", "AXWebArea"]
        let browserBundleIds: Set<String> = ["com.apple.Safari", "com.google.Chrome", "org.chromium.Chromium", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "net.imput.helium", "org.mozilla.firefox"]
        let windowFrame = frameForWindow(window)
        let windowArea = max(1, windowFrame.width * windowFrame.height)
        let isBrowser = browserBundleIds.contains(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "")
        let elements = collectDescendants(startingAt: window, maxDepth: isBrowser ? 10 : 8)
        var bestByKey: [String: (AXUIElement, Double)] = [:]

        for candidate in elements {
            let role = stringAttribute(candidate, attribute: kAXRoleAttribute as CFString) ?? ""
            let subrole = stringAttribute(candidate, attribute: kAXSubroleAttribute as CFString) ?? ""
            let title = stringAttribute(candidate, attribute: kAXTitleAttribute as CFString) ?? ""
            let description = stringAttribute(candidate, attribute: kAXDescriptionAttribute as CFString) ?? ""
            let value = stringAttribute(candidate, attribute: kAXValueAttribute as CFString) ?? ""
            let actions = actionNames(candidate)
            var focusedSettable = DarwinBoolean(false)
            let focusStatus = AXUIElementIsAttributeSettable(candidate, kAXFocusedAttribute as CFString, &focusedSettable)
            let canFocus = focusStatus == .success && focusedSettable.boolValue
            var valueSettable = DarwinBoolean(false)
            let valueStatus = AXUIElementIsAttributeSettable(candidate, kAXValueAttribute as CFString, &valueSettable)
            let canSetValue = valueStatus == .success && valueSettable.boolValue
            let isText = textRoles.contains(role) || canSetValue
            let canPress = actions.contains(kAXPressAction as String)
            let canScroll = supportsAnyScrollAction(candidate)
            let canAdjust = actions.contains(kAXIncrementAction as String) || actions.contains(kAXDecrementAction as String)
            guard isText || canPress || canFocus || canScroll || canAdjust else { continue }
            guard let frame = frameForElement(candidate), frame.width > 10, frame.height > 10 else { continue }

            let area = frame.width * frame.height
            let label = [title, description, value].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
            let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if structuralRoles.contains(role) {
                if normalizedLabel.isEmpty && !canScroll { continue }
                if role == "AXWebArea" && !isBrowser { continue }
            }
            if role == "AXTextArea" || role == "AXTextView" {
                if area > windowArea * 0.55 && !canSetValue { continue }
            }
            if role == "AXButton" && normalizedLabel.isEmpty && !isBrowser { continue }
            if isBrowser && (role == "AXButton" || role == "AXLink" || role == "AXPopUpButton") && normalizedLabel.isEmpty { continue }
            if actions == [kAXShowMenuAction as String] && !isText { continue }

            var score = 0.0
            if isText {
                score += scoreTextInputElement(candidate, role: role)
                score += canSetValue ? 160 : -80
            }
            if canFocus || canPress {
                score += scoreFocusableElement(candidate, role: role, canFocus: canFocus, canPress: canPress, preferredRoles: [])
            }
            if canScroll { score += 130 }
            if canAdjust { score += 120 }
            if !actions.isEmpty {
                score += scoreActionableElement(candidate, role: role, actions: actions, preferredRoles: [])
            }
            if !normalizedLabel.isEmpty { score += 55 } else if canScroll { score -= 20 } else { score -= 120 }
            if !description.isEmpty { score += 18 }
            if structuralRoles.contains(role) { score -= canScroll ? 40 : 180 }
            if canScroll && role == "AXScrollArea" { score += 180 }
            if area > windowArea * 0.7 && role != "AXTextField" && role != "AXSearchField" { score -= 180 }
            if isBrowser && (role == "AXTextField" || role == "AXSearchField") { score += 100 }
            if isBrowser && role == "AXLink" { score += 35 }
            if subrole == "AXCloseButton" { score -= 140 }
            if normalizedLabel == "close tab" { score -= 180 }
            if normalizedLabel.count > 160 { score -= 80 }
            if score < 120 { continue }

            let key = "\(role)|\(normalizedLabel)|\(Int(frame.midX / 24))|\(Int(frame.midY / 24))"
            if let existing = bestByKey[key], existing.1 >= score { continue }
            bestByKey[key] = (candidate, score)
        }

        let ranked = bestByKey.values.sorted { $0.1 > $1.1 }
        let targets = ranked.prefix(boundedLimit).map { elementPayload(element: $0.0, score: $0.1) }
        return AxListResult(targets: targets, reason: nil)
    }

    func pressElement(elementRef: String, pid: Int32) async throws -> AxActionResult {
        guard let element = refStore.element(for: elementRef) else {
            return AxActionResult(performed: false, reason: "element_ref_invalid", ownerPid: nil)
        }
        return performActionOrAncestor(startingAt: element, action: kAXPressAction as CFString, targetPid: pid)
    }

    func performAction(elementRef: String, pid: Int32, action: String) async throws -> AxActionResult {
        guard let element = refStore.element(for: elementRef) else {
            return AxActionResult(performed: false, reason: "element_ref_invalid", ownerPid: nil)
        }
        return performActionOrAncestor(startingAt: element, action: try axActionName(action), targetPid: pid)
    }

    func focusElement(elementRef: String, pid: Int32) async throws -> AxFocusResult {
        guard let element = refStore.element(for: elementRef) else {
            return AxFocusResult(focused: false, reason: "element_ref_invalid", ownerPid: nil)
        }
        return focusElementOrAncestor(startingAt: element, targetPid: pid)
    }

    func pressAtPoint(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int) async throws -> AxActionResult {
        let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: Double(captureWidth), captureHeight: Double(captureHeight))
        guard let hitElement = hitTestElement(at: point) else {
            return AxActionResult(performed: false, reason: "hit_test_failed", ownerPid: nil)
        }
        return performActionOrAncestor(startingAt: hitElement, action: kAXPressAction as CFString, targetPid: pid)
    }

    func focusAtPoint(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int) async throws -> AxFocusResult {
        let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: Double(captureWidth), captureHeight: Double(captureHeight))
        guard let hitElement = hitTestElement(at: point) else {
            return AxFocusResult(focused: false, reason: "hit_test_failed", ownerPid: nil)
        }
        return focusElementOrAncestor(startingAt: hitElement, targetPid: pid)
    }

    func scrollElement(elementRef: String, pid: Int32, scrollX: Int, scrollY: Int, steps: Int) async throws -> AxScrollResult {
        guard let element = refStore.element(for: elementRef) else {
            return AxScrollResult(scrolled: false, reason: "element_ref_invalid", ownerPid: nil)
        }
        return performScrollActionOrAncestor(startingAt: element, targetPid: pid, scrollX: scrollX, scrollY: scrollY, steps: steps)
    }

    func scrollAtPoint(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int, scrollX: Int, scrollY: Int, steps: Int) async throws -> AxScrollResult {
        let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: Double(captureWidth), captureHeight: Double(captureHeight))
        guard let hitElement = hitTestElement(at: point) else {
            return AxScrollResult(scrolled: false, reason: "hit_test_failed", ownerPid: nil)
        }
        return performScrollActionOrAncestor(startingAt: hitElement, targetPid: pid, scrollX: scrollX, scrollY: scrollY, steps: steps)
    }

    func focusedElement(pid: Int32, windowId: UInt32?, nativeWindowRef: String?) async throws -> FocusedElementResult {
        let app = AXUIElementCreateApplication(pid)
        guard let focusedValue = copyAttribute(app, attribute: kAXFocusedUIElementAttribute as CFString),
              let element = asAXElement(focusedValue) else {
            return FocusedElementResult(exists: false, elementRef: nil, role: nil, subrole: nil, isTextInput: false, isSecure: false, canSetValue: false, reason: nil)
        }
        if windowId != nil || nativeWindowRef != nil {
            guard let window = windowElement(pid: pid, windowId: windowId, windowRef: nativeWindowRef) else {
                return FocusedElementResult(exists: false, elementRef: nil, role: nil, subrole: nil, isTextInput: false, isSecure: false, canSetValue: false, reason: "window_not_found")
            }
            guard isElement(element, descendantOf: window) else {
                return FocusedElementResult(exists: false, elementRef: nil, role: nil, subrole: nil, isTextInput: false, isSecure: false, canSetValue: false, reason: "focused_element_outside_window")
            }
        }
        let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
        let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
        var settable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let canSetValue = settableStatus == .success && settable.boolValue
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXComboBox", "AXEditableText", "AXSecureTextField"]
        return FocusedElementResult(
            exists: true,
            elementRef: refStore.storeElement(element),
            role: role,
            subrole: subrole,
            isTextInput: textRoles.contains(role) || canSetValue,
            isSecure: role == "AXSecureTextField" || subrole == "AXSecureTextField",
            canSetValue: canSetValue,
            reason: nil
        )
    }

    func setValue(elementRef: String, value: String) async throws {
        guard let element = refStore.element(for: elementRef) else {
            throw ComputerUseError("Element reference is no longer valid.", code: "element_ref_invalid")
        }
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        if status != .success {
            throw ComputerUseError("Failed to set value (AX error \(status.rawValue)).", code: "set_value_failed")
        }
    }

    func focusTextInput(pid: Int32, windowId: UInt32?, nativeWindowRef: String?) async throws -> AxFocusResult {
        guard let window = windowElement(pid: pid, windowId: windowId, windowRef: nativeWindowRef) else {
            return AxFocusResult(focused: false, reason: "window_not_found", ownerPid: nil)
        }
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXComboBox", "AXEditableText", "AXSecureTextField"]
        let ranked = collectDescendants(startingAt: window, maxDepth: 8).compactMap { candidate -> (AXUIElement, Double)? in
            let role = stringAttribute(candidate, attribute: kAXRoleAttribute as CFString) ?? ""
            var valueSettable = DarwinBoolean(false)
            let valueStatus = AXUIElementIsAttributeSettable(candidate, kAXValueAttribute as CFString, &valueSettable)
            let canSetValue = valueStatus == .success && valueSettable.boolValue
            guard textRoles.contains(role) || canSetValue else { return nil }
            return (candidate, scoreTextInputElement(candidate, role: role))
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first else {
            return AxFocusResult(focused: false, reason: "no_text_input", ownerPid: nil)
        }
        return focusElementOrAncestor(startingAt: best.0, targetPid: pid)
    }
}

extension MacOSComputerUseBackend {
    func mouseClick(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int, button: MouseButtonName, clickCount: Int) async throws {
        let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: Double(captureWidth), captureHeight: Double(captureHeight))
        try postMouseClick(at: point, pid: pid, button: mouseButton(button), clickCount: clickCount)
    }

    func mouseMove(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int) async throws {
        let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: Double(captureWidth), captureHeight: Double(captureHeight))
        try postMouseMove(to: point, pid: pid)
    }

    func mouseDrag(pid: Int32, windowId: UInt32, nativeWindowRef: String?, path: [CGPointValue], captureWidth: Int, captureHeight: Int) async throws {
        guard path.count >= 2 else {
            throw ComputerUseError("mouseDrag requires a path with at least two points.", code: "invalid_args")
        }
        let points = try path.map {
            try mapWindowPoint(windowId: windowId, x: $0.x, y: $0.y, captureWidth: Double(captureWidth), captureHeight: Double(captureHeight))
        }
        try postMouseDrag(points: points, pid: pid)
    }

    func scrollWheel(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int, scrollX: Int, scrollY: Int) async throws {
        let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: Double(captureWidth), captureHeight: Double(captureHeight))
        try postScrollWheel(at: point, deltaX: scrollX, deltaY: scrollY, pid: pid)
    }

    func keyPress(pid: Int32, keys: [String]) async throws {
        try postKeyPress(keys: keys, pid: pid)
    }

    func typeText(pid: Int32, text: String) async throws {
        try postUnicodeText(text, pid: pid)
    }

    func openBrowserLocation(appName: String, bundleId: String?, url: String) async throws -> Bool {
        guard let lines = browserOpenLocationAppleScript(appName: appName, bundleId: bundleId, url: url) else {
            return false
        }
        try runAppleScript(lines)
        return true
    }
}

private extension MacOSComputerUseBackend {
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

    func windowElement(pid: Int32, windowId: UInt32?, windowRef: String? = nil) -> AXUIElement? {
        if let windowRef, let stored = refStore.window(for: windowRef) {
            AXUIElementSetMessagingTimeout(stored, 1.0)
            var ownerPid: pid_t = 0
            if AXUIElementGetPid(stored, &ownerPid) == .success, ownerPid == pid {
                return stored
            }
        }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        let windows = axElementArray(appElement, attribute: kAXWindowsAttribute as CFString)
        guard !windows.isEmpty else { return nil }
        guard let windowId else { return windows.first }
        let candidates = cgWindowCandidates(pid: pid)
        for window in windows {
            let title = stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? ""
            let frame = frameForWindow(window)
            if let candidate = bestCandidate(frame: frame, title: title, candidates: candidates, usedIds: []), candidate.windowId == windowId {
                return window
            }
        }
        return nil
    }

    func collectDescendants(startingAt root: AXUIElement, maxDepth: Int) -> [AXUIElement] {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var output: [AXUIElement] = []
        while index < queue.count {
            let (element, depth) = queue[index]
            index += 1
            output.append(element)
            if depth >= maxDepth { continue }
            for child in axElementArray(element, attribute: kAXChildrenAttribute as CFString) {
                queue.append((child, depth + 1))
            }
        }
        return output
    }

    func scoreTextInputElement(_ element: AXUIElement, role: String) -> Double {
        var score = 0.0
        if role == "AXSearchField" { score += 120 }
        if role == "AXTextField" { score += 100 }
        if role == "AXComboBox" { score += 80 }
        if role == "AXTextArea" || role == "AXTextView" || role == "AXEditableText" { score += 70 }
        if role == "AXSecureTextField" { score -= 40 }
        if let frame = frameForElement(element) {
            score += min(120, Double(frame.width * frame.height) / 5000.0)
            if frame.width > 40 && frame.height > 16 { score += 20 }
            if frame.origin.y < 220 { score += 15 }
        } else {
            score -= 100
        }
        if !(stringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? "").isEmpty { score += 10 }
        if !(stringAttribute(element, attribute: kAXValueAttribute as CFString) ?? "").isEmpty { score += 5 }
        return score
    }

    func scoreFocusableElement(_ element: AXUIElement, role: String, canFocus: Bool, canPress: Bool, preferredRoles: Set<String>) -> Double {
        var score = 0.0
        if canPress { score += 80 }
        if canFocus { score += 70 }
        if !preferredRoles.isEmpty && preferredRoles.contains(role) { score += 40 }
        switch role {
        case "AXButton": score += 60
        case "AXTextField", "AXSearchField", "AXTextArea", "AXTextView": score += 50
        case "AXList", "AXOutline", "AXRow", "AXCell", "AXLink": score += 35
        case "AXGroup", "AXToolbar", "AXWindow", "AXApplication": score -= 60
        default: break
        }
        if let frame = frameForElement(element) {
            score += min(100, Double(frame.width * frame.height) / 6000.0)
            if frame.width > 24 && frame.height > 14 { score += 10 }
        } else {
            score -= 100
        }
        if !actionNames(element).isEmpty { score += 10 }
        return score
    }

    func scoreActionableElement(_ element: AXUIElement, role: String, actions: [String], preferredRoles: Set<String>) -> Double {
        var score = 0.0
        if !preferredRoles.isEmpty && preferredRoles.contains(role) { score += 40 }
        if actions.contains(kAXPressAction as String) { score += 100 }
        if actions.contains(kAXShowMenuAction as String) { score += 50 }
        if actions.contains(kAXPickAction as String) { score += 45 }
        if actions.contains(kAXConfirmAction as String) { score += 35 }
        switch role {
        case "AXButton": score += 70
        case "AXLink": score += 60
        case "AXRow", "AXCell", "AXList", "AXOutline": score += 40
        case "AXGroup", "AXToolbar", "AXWindow", "AXApplication": score -= 60
        default: break
        }
        if let frame = frameForElement(element) {
            score += min(100, Double(frame.width * frame.height) / 6000.0)
            if frame.width > 20 && frame.height > 14 { score += 10 }
        } else {
            score -= 100
        }
        if !actions.isEmpty { score += Double(min(actions.count, 5) * 4) }
        return score
    }

    func frameForElement(_ element: AXUIElement) -> CGRect? {
        guard let origin = pointAttribute(element, attribute: kAXPositionAttribute as CFString),
              let size = sizeAttribute(element, attribute: kAXSizeAttribute as CFString),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    func elementPayload(element: AXUIElement, score: Double?) -> BackendAxTarget {
        let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
        let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
        let title = stringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? ""
        let description = stringAttribute(element, attribute: kAXDescriptionAttribute as CFString) ?? ""
        let value = stringAttribute(element, attribute: kAXValueAttribute as CFString) ?? ""
        let frame = frameForElement(element)
        var valueSettable = DarwinBoolean(false)
        let valueStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        var focusedSettable = DarwinBoolean(false)
        let focusedStatus = AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &focusedSettable)
        let actions = actionNames(element)
        let canSetValue = valueStatus == .success && valueSettable.boolValue
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXComboBox", "AXEditableText", "AXSecureTextField"]
        return BackendAxTarget(
            elementRef: refStore.storeElement(element),
            role: role,
            subrole: subrole,
            title: title,
            description: description,
            value: value,
            actions: actions,
            isTextInput: textRoles.contains(role) || canSetValue,
            canSetValue: canSetValue,
            canFocus: focusedStatus == .success && focusedSettable.boolValue,
            canPress: actions.contains(kAXPressAction as String),
            canScroll: supportsAnyScrollAction(element),
            canIncrement: actions.contains(kAXIncrementAction as String),
            canDecrement: actions.contains(kAXDecrementAction as String),
            x: Double(frame?.midX ?? 0),
            y: Double(frame?.midY ?? 0),
            score: score
        )
    }

    func pidForElement(_ element: AXUIElement) -> Int32? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return Int32(pid)
    }

    func parentElement(_ element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute: kAXParentAttribute as CFString) else { return nil }
        return asAXElement(value)
    }

    func sameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs as CFTypeRef, rhs as CFTypeRef)
    }

    func isElement(_ element: AXUIElement, descendantOf ancestor: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        var depth = 0
        while let candidate = current, depth < 20 {
            if sameElement(candidate, ancestor) { return true }
            current = parentElement(candidate)
            depth += 1
        }
        return false
    }

    func actionNames(_ element: AXUIElement) -> [String] {
        var actionsValue: CFArray?
        let status = AXUIElementCopyActionNames(element, &actionsValue)
        guard status == .success, let actionsArray = actionsValue as? [AnyObject] else { return [] }
        return actionsArray.compactMap { $0 as? String }
    }

    func supportsAction(_ element: AXUIElement, action: CFString) -> Bool {
        actionNames(element).contains(action as String)
    }
}

private extension MacOSComputerUseBackend {
    func axActionName(_ actionName: String) throws -> CFString {
        switch actionName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "press":
            return kAXPressAction as CFString
        case "increment":
            return kAXIncrementAction as CFString
        case "decrement":
            return kAXDecrementAction as CFString
        case "confirm":
            return kAXConfirmAction as CFString
        case "cancel":
            return kAXCancelAction as CFString
        case "showmenu", "show_menu", "menu":
            return kAXShowMenuAction as CFString
        case "pick":
            return kAXPickAction as CFString
        default:
            throw ComputerUseError("Unsupported AX action '\(actionName)'.", code: "invalid_args")
        }
    }

    var axScrollDownAction: CFString { "AXScrollDown" as CFString }
    var axScrollUpAction: CFString { "AXScrollUp" as CFString }
    var axScrollLeftAction: CFString { "AXScrollLeft" as CFString }
    var axScrollRightAction: CFString { "AXScrollRight" as CFString }

    func scrollActionNames(scrollX: Int, scrollY: Int) -> [CFString] {
        var actions: [CFString] = []
        if scrollY > 0 { actions.append(axScrollDownAction) }
        if scrollY < 0 { actions.append(axScrollUpAction) }
        if scrollX > 0 { actions.append(axScrollRightAction) }
        if scrollX < 0 { actions.append(axScrollLeftAction) }
        return actions
    }

    func supportsAnyScrollAction(_ element: AXUIElement) -> Bool {
        let actions = Set(actionNames(element))
        return actions.contains(axScrollDownAction as String) ||
            actions.contains(axScrollUpAction as String) ||
            actions.contains(axScrollLeftAction as String) ||
            actions.contains(axScrollRightAction as String)
    }

    func performScrollActionOrAncestor(startingAt element: AXUIElement, targetPid: Int32, scrollX: Int, scrollY: Int, steps: Int) -> AxScrollResult {
        let actions = scrollActionNames(scrollX: scrollX, scrollY: scrollY)
        guard !actions.isEmpty else { return AxScrollResult(scrolled: false, reason: "zero_delta", ownerPid: nil) }
        var current: AXUIElement? = element
        var depth = 0
        while let candidate = current, depth < 10 {
            if let pid = pidForElement(candidate), pid != targetPid {
                return AxScrollResult(scrolled: false, reason: "pid_mismatch", ownerPid: pid)
            }
            var didScroll = false
            for _ in 0..<max(1, min(8, steps)) {
                for action in actions where supportsAction(candidate, action: action) {
                    if AXUIElementPerformAction(candidate, action) == .success {
                        didScroll = true
                    }
                }
            }
            if didScroll { return AxScrollResult(scrolled: true, reason: nil, ownerPid: nil) }
            current = parentElement(candidate)
            depth += 1
        }
        return AxScrollResult(scrolled: false, reason: "no_scroll_action", ownerPid: nil)
    }

    func performActionOrAncestor(startingAt element: AXUIElement, action: CFString, targetPid: Int32) -> AxActionResult {
        var current: AXUIElement? = element
        var depth = 0
        while let candidate = current, depth < 10 {
            if let pid = pidForElement(candidate), pid != targetPid {
                return AxActionResult(performed: false, reason: "pid_mismatch", ownerPid: pid)
            }
            if supportsAction(candidate, action: action), AXUIElementPerformAction(candidate, action) == .success {
                return AxActionResult(performed: true, reason: nil, ownerPid: nil)
            }
            current = parentElement(candidate)
            depth += 1
        }
        return AxActionResult(performed: false, reason: "no_matching_action", ownerPid: nil)
    }

    func focusElementOrAncestor(startingAt element: AXUIElement, targetPid: Int32) -> AxFocusResult {
        var current: AXUIElement? = element
        var depth = 0
        while let candidate = current, depth < 10 {
            if let pid = pidForElement(candidate), pid != targetPid {
                return AxFocusResult(focused: false, reason: "pid_mismatch", ownerPid: pid)
            }
            var settable = DarwinBoolean(false)
            let status = AXUIElementIsAttributeSettable(candidate, kAXFocusedAttribute as CFString, &settable)
            if status == .success, settable.boolValue,
               AXUIElementSetAttributeValue(candidate, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
                return AxFocusResult(focused: true, reason: nil, ownerPid: nil)
            }
            current = parentElement(candidate)
            depth += 1
        }
        return AxFocusResult(focused: false, reason: "no_focusable_ancestor", ownerPid: nil)
    }

    func hitTestElement(at point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hitElement)
        guard status == .success else { return nil }
        return hitElement
    }
}

private extension MacOSComputerUseBackend {
    func copyAttribute(_ element: AXUIElement, attribute: CFString) -> AnyObject? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success else { return nil }
        return value
    }

    func boolAttribute(_ element: AXUIElement, attribute: CFString) -> Bool? {
        guard let value = copyAttribute(element, attribute: attribute) else { return nil }
        if let boolValue = value as? Bool { return boolValue }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    func stringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        copyAttribute(element, attribute: attribute) as? String
    }

    func axElementArray(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        guard let value = copyAttribute(element, attribute: attribute) else { return [] }
        if let array = value as? [AXUIElement] { return array }
        if let anyArray = value as? [AnyObject] { return anyArray.compactMap(asAXElement) }
        return []
    }

    func asAXElement(_ value: AnyObject) -> AXUIElement? {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    func pointAttribute(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        guard let value = copyAttribute(element, attribute: attribute) else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    func sizeAttribute(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        guard let value = copyAttribute(element, attribute: attribute) else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    func frameForWindow(_ window: AXUIElement) -> CGRect {
        let origin = pointAttribute(window, attribute: kAXPositionAttribute as CFString) ?? .zero
        let size = sizeAttribute(window, attribute: kAXSizeAttribute as CFString) ?? .zero
        return CGRect(origin: origin, size: size)
    }
}

private extension MacOSComputerUseBackend {
    func cgWindowCandidates(pid: Int32) -> [CGWindowCandidate] {
        guard let entries = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var candidates: [CGWindowCandidate] = []
        for entry in entries {
            guard let ownerPid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, ownerPid == pid else { continue }
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer != 0 { continue }
            guard let windowNumber = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            candidates.append(CGWindowCandidate(
                windowId: windowNumber,
                title: (entry[kCGWindowName as String] as? String) ?? "",
                bounds: bounds,
                isOnscreen: (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            ))
        }
        return candidates
    }

    func bestCandidate(frame: CGRect, title: String, candidates: [CGWindowCandidate], usedIds: Set<UInt32>) -> CGWindowCandidate? {
        var best: (candidate: CGWindowCandidate, score: Double)?
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for candidate in candidates where !usedIds.contains(candidate.windowId) {
            var score = 0.0
            let candidateTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalizedTitle.isEmpty {
                if candidateTitle == normalizedTitle { score += 100 }
                else if candidateTitle.contains(normalizedTitle) { score += 50 }
            }
            let dx = abs(candidate.bounds.origin.x - frame.origin.x)
            let dy = abs(candidate.bounds.origin.y - frame.origin.y)
            let dw = abs(candidate.bounds.width - frame.width)
            let dh = abs(candidate.bounds.height - frame.height)
            score -= Double(dx + dy + dw + dh) / 20.0
            if best == nil || score > best!.score {
                best = (candidate, score)
            }
        }
        return best?.candidate
    }

    func displayScaleFactor(for frame: CGRect) -> Double {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return Double(NSScreen.main?.backingScaleFactor ?? 1.0)
        }
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
            return Double(NSScreen.main?.backingScaleFactor ?? 1.0)
        }
        var chosenDisplay: CGDirectDisplayID?
        var chosenArea: CGFloat = -1
        for display in displays {
            let bounds = CGDisplayBounds(display)
            let overlap = bounds.intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > chosenArea {
                chosenArea = area
                chosenDisplay = display
            }
        }
        guard let display = chosenDisplay, let mode = CGDisplayCopyDisplayMode(display) else {
            return Double(NSScreen.main?.backingScaleFactor ?? 1.0)
        }
        let width = Double(mode.width)
        guard width > 0 else { return 1.0 }
        let scale = Double(mode.pixelWidth) / width
        return scale > 0 ? scale : 1.0
    }
}

private extension MacOSComputerUseBackend {
    func captureWindow(windowId: UInt32) async throws -> ScreenshotPayload {
        guard #available(macOS 14.0, *) else {
            throw ComputerUseError("Window capture requires macOS 14+.", code: "unsupported_os")
        }
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let window = shareable.windows.first(where: { $0.windowID == windowId }) else {
                throw ComputerUseError("Window \(windowId) is not available for capture.", code: "window_not_found")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return try screenshotPayload(image: image, windowId: windowId)
        } catch let error as ComputerUseError {
            if let payload = try cgWindowScreenshot(windowId: windowId) { return payload }
            if let payload = try systemScreenshotWindow(windowId: windowId) { return payload }
            throw error
        } catch {
            if let payload = try cgWindowScreenshot(windowId: windowId) { return payload }
            if let payload = try systemScreenshotWindow(windowId: windowId) { return payload }
            throw ComputerUseError("Screenshot failed: \(error.localizedDescription)", code: "screenshot_failed")
        }
    }

    func screenshotPayload(image: CGImage, windowId: UInt32) throws -> ScreenshotPayload {
        guard let pngData = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ComputerUseError("Failed to encode screenshot as PNG.", code: "encoding_failed")
        }
        let scale = currentWindowBounds(windowId: windowId).map { displayScaleFactor(for: $0) } ?? 1.0
        return ScreenshotPayload(pngData: pngData, width: image.width, height: image.height, scaleFactor: scale)
    }

    func cgWindowScreenshot(windowId: UInt32) throws -> ScreenshotPayload? {
        let options: CGWindowListOption = [.optionIncludingWindow]
        let imageOptions: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        guard let image = CGWindowListCreateImage(.null, options, CGWindowID(windowId), imageOptions),
              image.width > 1,
              image.height > 1 else {
            return nil
        }
        return try screenshotPayload(image: image, windowId: windowId)
    }

    func systemScreenshotWindow(windowId: UInt32) throws -> ScreenshotPayload? {
        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("computer-use-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempUrl) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(windowId), tempUrl.path]
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { process.interrupt() }
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: tempUrl),
              !data.isEmpty,
              let imageRep = NSBitmapImageRep(data: data),
              let cgImage = imageRep.cgImage else {
            return nil
        }
        return try screenshotPayload(image: cgImage, windowId: windowId)
    }

    func currentWindowBounds(windowId: UInt32) -> CGRect? {
        guard let descriptions = CGWindowListCreateDescriptionFromArray([NSNumber(value: windowId)] as CFArray) as? [[String: Any]],
              let first = descriptions.first,
              let boundsDict = first[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
            return nil
        }
        return bounds
    }

    func mapWindowPoint(windowId: UInt32, x: Double, y: Double, captureWidth: Double, captureHeight: Double) throws -> CGPoint {
        guard let bounds = currentWindowBounds(windowId: windowId) else {
            throw ComputerUseError("Target window is no longer available.", code: "window_not_found")
        }
        let relX = min(max(x / max(1, captureWidth), 0), 1)
        let relY = min(max(y / max(1, captureHeight), 0), 1)
        return CGPoint(x: bounds.origin.x + bounds.width * relX, y: bounds.origin.y + bounds.height * relY)
    }
}

private extension MacOSComputerUseBackend {
    func postEvent(_ event: CGEvent, pid: Int32) {
        event.postToPid(pid)
    }

    func postMouseMove(to point: CGPoint, pid: Int32) throws {
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw ComputerUseError("Failed to create mouse move event.", code: "input_failed")
        }
        postEvent(move, pid: pid)
    }

    func mouseButton(_ name: MouseButtonName) -> CGMouseButton {
        switch name {
        case .right: return .right
        case .middle: return .center
        case .left: return .left
        }
    }

    func mouseDownType(for button: CGMouseButton) -> CGEventType {
        switch button {
        case .right: return .rightMouseDown
        case .center: return .otherMouseDown
        default: return .leftMouseDown
        }
    }

    func mouseUpType(for button: CGMouseButton) -> CGEventType {
        switch button {
        case .right: return .rightMouseUp
        case .center: return .otherMouseUp
        default: return .leftMouseUp
        }
    }

    func mouseDraggedType(for button: CGMouseButton) -> CGEventType {
        switch button {
        case .right: return .rightMouseDragged
        case .center: return .otherMouseDragged
        default: return .leftMouseDragged
        }
    }

    func postMouseClick(at point: CGPoint, pid: Int32, button: CGMouseButton = .left, clickCount: Int = 1) throws {
        try postMouseMove(to: point, pid: pid)
        for index in 1...max(1, clickCount) {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: mouseDownType(for: button), mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: mouseUpType(for: button), mouseCursorPosition: point, mouseButton: button) else {
                throw ComputerUseError("Failed to create mouse click event.", code: "input_failed")
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            postEvent(down, pid: pid)
            usleep(12_000)
            postEvent(up, pid: pid)
            if index < clickCount { usleep(70_000) }
        }
    }

    func postMouseDrag(points: [CGPoint], pid: Int32) throws {
        guard points.count >= 2, let first = points.first, let last = points.last else {
            throw ComputerUseError("Drag requires at least two points.", code: "invalid_args")
        }
        try postMouseMove(to: first, pid: pid)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: first, mouseButton: .left) else {
            throw ComputerUseError("Failed to create mouse down event.", code: "input_failed")
        }
        postEvent(down, pid: pid)
        usleep(12_000)
        for point in points.dropFirst() {
            guard let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else {
                throw ComputerUseError("Failed to create mouse drag event.", code: "input_failed")
            }
            postEvent(drag, pid: pid)
            usleep(8_000)
        }
        guard let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: last, mouseButton: .left) else {
            throw ComputerUseError("Failed to create mouse up event.", code: "input_failed")
        }
        postEvent(up, pid: pid)
    }

    func postScrollWheel(at point: CGPoint, deltaX: Int, deltaY: Int, pid: Int32) throws {
        try postMouseMove(to: point, pid: pid)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-deltaY), wheel2: Int32(deltaX), wheel3: 0) else {
            throw ComputerUseError("Failed to create scroll event.", code: "input_failed")
        }
        event.location = point
        postEvent(event, pid: pid)
    }
}

private extension MacOSComputerUseBackend {
    func modifierFlag(_ key: String) -> CGEventFlags? {
        switch key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cmd", "command", "meta": return .maskCommand
        case "ctrl", "control": return .maskControl
        case "shift": return .maskShift
        case "option", "alt": return .maskAlternate
        default: return nil
        }
    }

    func keyCode(_ key: String) -> CGKeyCode? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let table: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
            "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
            "6": 22, "5": 23, "=": 24, "+": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36,
            "l": 37, "j": 38, "'": 39, "\"": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, " ": 49, "`": 50, "~": 50,
            "backspace": 51, "delete": 51, "del": 51, "esc": 53, "escape": 53,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "home": 115, "pageup": 116, "page_up": 116, "page down": 121, "pagedown": 121, "page_down": 121,
            "forwarddelete": 117, "forward_delete": 117, "end": 119,
            "left": 123, "arrowleft": 123, "arrow_left": 123,
            "right": 124, "arrowright": 124, "arrow_right": 124,
            "down": 125, "arrowdown": 125, "arrow_down": 125,
            "up": 126, "arrowup": 126, "arrow_up": 126
        ]
        return table[normalized]
    }

    func keyChord(_ keys: [String]) -> (flags: CGEventFlags, key: String)? {
        guard keys.count >= 2 else { return nil }
        var flags = CGEventFlags()
        for key in keys.dropLast() {
            guard let flag = modifierFlag(key) else { return nil }
            flags.insert(flag)
        }
        return (flags, keys.last ?? "")
    }

    func postKeyPress(keys: [String], pid: Int32) throws {
        if let chord = keyChord(keys) {
            try postKey(chord.key, flags: chord.flags, pid: pid)
            return
        }
        for key in keys {
            let parts = key.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if let chord = keyChord(parts) {
                try postKey(chord.key, flags: chord.flags, pid: pid)
            } else {
                try postKey(key, flags: [], pid: pid)
            }
        }
    }

    func postKey(_ key: String, flags: CGEventFlags, pid: Int32) throws {
        guard let code = keyCode(key) else {
            if key.count == 1 {
                try postUnicodeText(key, pid: pid)
                return
            }
            throw ComputerUseError("Unsupported key '\(key)'.", code: "invalid_args")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw ComputerUseError("Failed to create key event.", code: "input_failed")
        }
        down.flags = flags
        up.flags = flags
        postEvent(down, pid: pid)
        usleep(8_000)
        postEvent(up, pid: pid)
    }

    func postUnicodeText(_ text: String, pid: Int32) throws {
        for scalar in text.unicodeScalars {
            let char = String(scalar)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw ComputerUseError("Failed to create unicode key event.", code: "input_failed")
            }
            setUnicodeString(event: down, text: char)
            setUnicodeString(event: up, text: char)
            postEvent(down, pid: pid)
            usleep(8_000)
            postEvent(up, pid: pid)
        }
    }

    func setUnicodeString(event: CGEvent, text: String) {
        var utf16 = Array(text.utf16)
        utf16.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
    }
}

private extension MacOSComputerUseBackend {
    func escapeAppleScriptString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    func browserOpenLocationAppleScript(appName: String, bundleId: String?, url: String) -> [String]? {
        let browserBundleIds: Set<String> = [
            "com.apple.Safari",
            "com.google.Chrome",
            "org.chromium.Chromium",
            "company.thebrowser.Browser",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi",
            "net.imput.helium"
        ]
        let normalizedName = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let chromeFamilyNames: Set<String> = ["google chrome", "chrome", "chromium", "arc", "brave browser", "brave", "microsoft edge", "edge", "vivaldi", "helium"]
        let target = bundleId.map { "application id \"\(escapeAppleScriptString($0))\"" } ?? "application \"\(escapeAppleScriptString(appName))\""
        let escapedUrl = escapeAppleScriptString(url)
        if bundleId == "com.apple.Safari" || normalizedName == "safari" {
            return ["tell \(target) to set URL of front document to \"\(escapedUrl)\""]
        }
        if browserBundleIds.contains(bundleId ?? "") || chromeFamilyNames.contains(normalizedName) {
            return ["tell \(target) to set URL of active tab of front window to \"\(escapedUrl)\""]
        }
        return nil
    }

    func runAppleScript(_ lines: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = lines.flatMap { ["-e", $0] }
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ComputerUseError("AppleScript failed\(message.map { ": \($0)" } ?? ".")", code: "applescript_failed")
        }
    }
}
#endif
