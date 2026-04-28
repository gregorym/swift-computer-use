import Foundation
import Testing
@testable import ComputerUse

@Test func exposesExpectedToolCatalog() async throws {
    let session = ComputerUseSession(config: .init(), backend: FakeBackend())
    let names = Set(session.tools.map(\.name))
    #expect(names == Set([
        "list_apps",
        "list_windows",
        "screenshot",
        "click",
        "double_click",
        "move_mouse",
        "drag",
        "scroll",
        "keypress",
        "type_text",
        "set_text",
        "wait",
        "arrange_window",
        "navigate_browser",
        "computer_actions"
    ]))
    for tool in session.tools {
        #expect(tool.parameters.objectValue?["type"]?.stringValue == "object")
        #expect(tool.parameters.objectValue?["properties"]?.objectValue != nil)
    }
}

@Test func listWindowsReusesStableRefs() async throws {
    let backend = FakeBackend()
    let session = ComputerUseSession(config: .init(), backend: backend)

    let first = try await session.execute(tool: "list_windows", arguments: ["app": "TextEdit"])
    let second = try await session.execute(tool: "list_windows", arguments: ["app": "TextEdit"])

    let firstRef = first.details["windows"]?.arrayValue?.first?["windowRef"]?.stringValue
    let secondRef = second.details["windows"]?.arrayValue?.first?["windowRef"]?.stringValue
    #expect(firstRef == "@w1")
    #expect(secondRef == firstRef)
}

@Test func screenshotAutoAttachesImageWhenAxTargetsAreMissing() async throws {
    let backend = FakeBackend()
    await backend.setAxTargets([])
    let session = ComputerUseSession(config: .init(), backend: backend)

    let result = try await session.execute(tool: "screenshot", arguments: ["image": "auto"])

    #expect(result.details["imageReason"]?.stringValue == "no_ax_targets")
    #expect(result.content.contains { content in
        if case .image(let data, let mimeType) = content {
            return data == Data([0x89, 0x50, 0x4E, 0x47]) && mimeType == "image/png"
        }
        return false
    })
}

@Test func staleStateIdIsRejectedBeforeAction() async throws {
    let backend = FakeBackend()
    let session = ComputerUseSession(config: .init(), backend: backend)

    let screenshot = try await session.execute(tool: "screenshot", arguments: ["image": "never"])
    let staleStateId = try #require(screenshot.details["capture"]?["stateId"]?.stringValue)
    _ = try await session.execute(tool: "wait", arguments: ["ms": 0, "image": "never"])

    await #expect(throws: ComputerUseError.self) {
        _ = try await session.execute(tool: "click", arguments: [
            "x": 10,
            "y": 10,
            "stateId": .string(staleStateId),
            "image": "never"
        ])
    }
    #expect(await backend.mouseClickCount == 0)
}

@Test func strictModeBlocksCoordinateFallback() async throws {
    let backend = FakeBackend()
    await backend.setPointAxActionsSucceed(false)
    let session = ComputerUseSession(config: .init(stealthMode: true), backend: backend)
    let screenshot = try await session.execute(tool: "screenshot", arguments: ["image": "never"])
    let stateId = try #require(screenshot.details["capture"]?["stateId"]?.stringValue)

    await #expect(throws: ComputerUseError.self) {
        _ = try await session.execute(tool: "click", arguments: [
            "x": 10,
            "y": 10,
            "stateId": .string(stateId),
            "image": "never"
        ])
    }
    #expect(await backend.mouseClickCount == 0)
}

@Test func batchRejectsMoreThanTwentyActions() async throws {
    let backend = FakeBackend()
    let session = ComputerUseSession(config: .init(), backend: backend)
    let screenshot = try await session.execute(tool: "screenshot", arguments: ["image": "never"])
    let stateId = try #require(screenshot.details["capture"]?["stateId"]?.stringValue)
    let actions = Array(repeating: JSONValue.object(["type": "wait", "ms": 0]), count: 21)

    await #expect(throws: ComputerUseError.self) {
        _ = try await session.execute(tool: "computer_actions", arguments: [
            "stateId": .string(stateId),
            "actions": .array(actions),
            "image": "never"
        ])
    }
}

@Test func setTextUsesAxSetValueWhenRefIsSettable() async throws {
    let backend = FakeBackend()
    let session = ComputerUseSession(config: .init(), backend: backend)

    _ = try await session.execute(tool: "screenshot", arguments: ["image": "never"])
    _ = try await session.execute(tool: "set_text", arguments: [
        "ref": "@e1",
        "text": "hello",
        "image": "never"
    ])

    #expect(await backend.valueForElement("text-1") == "hello")
}

@Test func nativeBackendPermissionSmokeWhenEnabled() async throws {
    guard ProcessInfo.processInfo.environment["COMPUTER_USE_RUN_NATIVE_TESTS"] == "1" else {
        return
    }
    let session = ComputerUseSession()
    _ = await session.checkPermissions()
}

actor FakeBackend: ComputerUseBackend {
    var mouseClickCount = 0
    private var pointAxActionsSucceed = true
    private var values: [String: String] = [:]
    private var axTargets: [BackendAxTarget] = [
        BackendAxTarget(
            elementRef: "text-1",
            role: "AXTextField",
            subrole: "",
            title: "Name",
            description: "",
            value: "",
            actions: ["AXPress"],
            isTextInput: true,
            canSetValue: true,
            canFocus: true,
            canPress: true,
            canScroll: false,
            canIncrement: false,
            canDecrement: false,
            x: 25,
            y: 25,
            score: 300
        ),
        BackendAxTarget(
            elementRef: "scroll-1",
            role: "AXScrollArea",
            subrole: "",
            title: "List",
            description: "",
            value: "",
            actions: ["AXScrollDown", "AXScrollUp"],
            isTextInput: false,
            canSetValue: false,
            canFocus: false,
            canPress: false,
            canScroll: true,
            canIncrement: false,
            canDecrement: false,
            x: 50,
            y: 50,
            score: 240
        ),
        BackendAxTarget(
            elementRef: "button-1",
            role: "AXButton",
            subrole: "",
            title: "OK",
            description: "",
            value: "",
            actions: ["AXPress"],
            isTextInput: false,
            canSetValue: false,
            canFocus: true,
            canPress: true,
            canScroll: false,
            canIncrement: false,
            canDecrement: false,
            x: 70,
            y: 70,
            score: 220
        )
    ]

    func setAxTargets(_ targets: [BackendAxTarget]) {
        axTargets = targets
    }

    func setPointAxActionsSucceed(_ value: Bool) {
        pointAxActionsSucceed = value
    }

    func valueForElement(_ elementRef: String) -> String? {
        values[elementRef]
    }

    func checkPermissions() async -> ComputerUsePermissionStatus {
        ComputerUsePermissionStatus(accessibility: true, screenRecording: true)
    }

    func openPermissionPane(_ kind: ComputerUsePermissionKind) async throws {}

    func listApps() async throws -> [BackendApp] {
        [
            BackendApp(appName: "TextEdit", bundleId: "com.apple.TextEdit", pid: 100, isFrontmost: true)
        ]
    }

    func listWindows(pid: Int32) async throws -> [BackendWindow] {
        [
            BackendWindow(
                windowId: 1,
                nativeWindowRef: "native-w1",
                title: "Untitled",
                framePoints: FramePoints(x: 0, y: 0, w: 200, h: 120),
                scaleFactor: 1,
                isMinimized: false,
                isOnscreen: true,
                isMain: true,
                isFocused: true
            )
        ]
    }

    func getFrontmost() async throws -> BackendFrontmost {
        BackendFrontmost(appName: "TextEdit", bundleId: "com.apple.TextEdit", pid: 100, windowTitle: "Untitled", windowId: 1, nativeWindowRef: "native-w1")
    }

    func focusWindow(pid: Int32, windowId: UInt32?, nativeWindowRef: String?) async throws -> FocusWindowResult {
        FocusWindowResult(focused: true, reason: nil)
    }

    func setWindowFrame(pid: Int32, windowId: UInt32?, nativeWindowRef: String?, x: Double, y: Double, width: Double, height: Double) async throws -> (ok: Bool, reason: String?, frame: FramePoints?) {
        (true, nil, FramePoints(x: x, y: y, w: width, h: height))
    }

    func screenshot(windowId: UInt32) async throws -> ScreenshotPayload {
        ScreenshotPayload(pngData: Data([0x89, 0x50, 0x4E, 0x47]), width: 200, height: 120, scaleFactor: 1)
    }

    func listAxTargets(pid: Int32, windowId: UInt32?, nativeWindowRef: String?, limit: Int) async throws -> AxListResult {
        AxListResult(targets: Array(axTargets.prefix(limit)), reason: nil)
    }

    func pressElement(elementRef: String, pid: Int32) async throws -> AxActionResult {
        AxActionResult(performed: true, reason: nil, ownerPid: nil)
    }

    func performAction(elementRef: String, pid: Int32, action: String) async throws -> AxActionResult {
        AxActionResult(performed: true, reason: nil, ownerPid: nil)
    }

    func focusElement(elementRef: String, pid: Int32) async throws -> AxFocusResult {
        AxFocusResult(focused: true, reason: nil, ownerPid: nil)
    }

    func pressAtPoint(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int) async throws -> AxActionResult {
        AxActionResult(performed: pointAxActionsSucceed, reason: pointAxActionsSucceed ? nil : "hit_test_failed", ownerPid: nil)
    }

    func focusAtPoint(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int) async throws -> AxFocusResult {
        AxFocusResult(focused: pointAxActionsSucceed, reason: pointAxActionsSucceed ? nil : "hit_test_failed", ownerPid: nil)
    }

    func scrollElement(elementRef: String, pid: Int32, scrollX: Int, scrollY: Int, steps: Int) async throws -> AxScrollResult {
        AxScrollResult(scrolled: true, reason: nil, ownerPid: nil)
    }

    func scrollAtPoint(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int, scrollX: Int, scrollY: Int, steps: Int) async throws -> AxScrollResult {
        AxScrollResult(scrolled: true, reason: nil, ownerPid: nil)
    }

    func focusedElement(pid: Int32, windowId: UInt32?, nativeWindowRef: String?) async throws -> FocusedElementResult {
        FocusedElementResult(exists: true, elementRef: "text-1", role: "AXTextField", subrole: "", isTextInput: true, isSecure: false, canSetValue: true, reason: nil)
    }

    func setValue(elementRef: String, value: String) async throws {
        values[elementRef] = value
    }

    func focusTextInput(pid: Int32, windowId: UInt32?, nativeWindowRef: String?) async throws -> AxFocusResult {
        AxFocusResult(focused: true, reason: nil, ownerPid: nil)
    }

    func mouseClick(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int, button: MouseButtonName, clickCount: Int) async throws {
        mouseClickCount += 1
    }

    func mouseMove(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int) async throws {}
    func mouseDrag(pid: Int32, windowId: UInt32, nativeWindowRef: String?, path: [CGPointValue], captureWidth: Int, captureHeight: Int) async throws {}
    func scrollWheel(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int, scrollX: Int, scrollY: Int) async throws {}
    func keyPress(pid: Int32, keys: [String]) async throws {}
    func typeText(pid: Int32, text: String) async throws {}

    func openBrowserLocation(appName: String, bundleId: String?, url: String) async throws -> Bool {
        true
    }
}
