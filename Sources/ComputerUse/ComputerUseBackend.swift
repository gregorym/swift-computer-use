import Foundation

protocol ComputerUseBackend: Sendable {
    func checkPermissions() async -> ComputerUsePermissionStatus
    func openPermissionPane(_ kind: ComputerUsePermissionKind) async throws

    func listApps() async throws -> [BackendApp]
    func listWindows(pid: Int32) async throws -> [BackendWindow]
    func getFrontmost() async throws -> BackendFrontmost

    func focusWindow(pid: Int32, windowId: UInt32?, nativeWindowRef: String?) async throws -> FocusWindowResult
    func setWindowFrame(pid: Int32, windowId: UInt32?, nativeWindowRef: String?, x: Double, y: Double, width: Double, height: Double) async throws -> (ok: Bool, reason: String?, frame: FramePoints?)
    func screenshot(windowId: UInt32) async throws -> ScreenshotPayload

    func listAxTargets(pid: Int32, windowId: UInt32?, nativeWindowRef: String?, limit: Int) async throws -> AxListResult
    func pressElement(elementRef: String, pid: Int32) async throws -> AxActionResult
    func performAction(elementRef: String, pid: Int32, action: String) async throws -> AxActionResult
    func focusElement(elementRef: String, pid: Int32) async throws -> AxFocusResult
    func pressAtPoint(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int) async throws -> AxActionResult
    func focusAtPoint(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int) async throws -> AxFocusResult
    func scrollElement(elementRef: String, pid: Int32, scrollX: Int, scrollY: Int, steps: Int) async throws -> AxScrollResult
    func scrollAtPoint(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int, scrollX: Int, scrollY: Int, steps: Int) async throws -> AxScrollResult
    func focusedElement(pid: Int32, windowId: UInt32?, nativeWindowRef: String?) async throws -> FocusedElementResult
    func setValue(elementRef: String, value: String) async throws
    func focusTextInput(pid: Int32, windowId: UInt32?, nativeWindowRef: String?) async throws -> AxFocusResult

    func mouseClick(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int, button: MouseButtonName, clickCount: Int) async throws
    func mouseMove(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int) async throws
    func mouseDrag(pid: Int32, windowId: UInt32, nativeWindowRef: String?, path: [CGPointValue], captureWidth: Int, captureHeight: Int) async throws
    func scrollWheel(pid: Int32, windowId: UInt32, nativeWindowRef: String?, x: Double, y: Double, captureWidth: Int, captureHeight: Int, scrollX: Int, scrollY: Int) async throws
    func keyPress(pid: Int32, keys: [String]) async throws
    func typeText(pid: Int32, text: String) async throws
    func openBrowserLocation(appName: String, bundleId: String?, url: String) async throws -> Bool
}

struct CGPointValue: Equatable, Sendable {
    var x: Double
    var y: Double

    var json: JSONValue {
        .object(["x": .number(x), "y": .number(y)])
    }
}
