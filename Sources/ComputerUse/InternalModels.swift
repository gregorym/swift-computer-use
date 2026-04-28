import Foundation

enum ImageMode: String, Sendable {
    case auto
    case always
    case never
}

enum MouseButtonName: String, Sendable {
    case left
    case right
    case middle
}

struct FramePoints: Equatable, Sendable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var json: JSONValue {
        .object([
            "x": .number(x),
            "y": .number(y),
            "w": .number(w),
            "h": .number(h)
        ])
    }
}

struct BackendApp: Equatable, Sendable {
    var appName: String
    var bundleId: String?
    var pid: Int32
    var isFrontmost: Bool
}

struct BackendWindow: Equatable, Sendable {
    var windowId: UInt32?
    var nativeWindowRef: String?
    var title: String
    var framePoints: FramePoints
    var scaleFactor: Double
    var isMinimized: Bool
    var isOnscreen: Bool
    var isMain: Bool
    var isFocused: Bool
}

struct BackendFrontmost: Equatable, Sendable {
    var appName: String
    var bundleId: String?
    var pid: Int32
    var windowTitle: String?
    var windowId: UInt32?
    var nativeWindowRef: String?
}

struct ScreenshotPayload: Equatable, Sendable {
    var pngData: Data
    var width: Int
    var height: Int
    var scaleFactor: Double
}

struct BackendAxTarget: Equatable, Sendable {
    var elementRef: String
    var role: String
    var subrole: String
    var title: String
    var description: String
    var value: String
    var actions: [String]
    var isTextInput: Bool
    var canSetValue: Bool
    var canFocus: Bool
    var canPress: Bool
    var canScroll: Bool
    var canIncrement: Bool
    var canDecrement: Bool
    var x: Double
    var y: Double
    var score: Double?
}

struct AxListResult: Equatable, Sendable {
    var targets: [BackendAxTarget]
    var reason: String?
}

struct AxTarget: Equatable, Sendable {
    var ref: String
    var elementRef: String
    var role: String
    var subrole: String
    var title: String
    var description: String
    var value: String
    var actions: [String]
    var isTextInput: Bool
    var canSetValue: Bool
    var canFocus: Bool
    var canPress: Bool
    var canScroll: Bool
    var canIncrement: Bool
    var canDecrement: Bool
    var x: Double
    var y: Double
    var score: Double?

    var json: JSONValue {
        .object([
            "ref": .string(ref),
            "elementRef": .string(elementRef),
            "role": .string(role),
            "subrole": .string(subrole),
            "title": .string(title),
            "description": .string(description),
            "value": .string(value),
            "actions": .array(actions.map(JSONValue.string)),
            "isTextInput": .bool(isTextInput),
            "canSetValue": .bool(canSetValue),
            "canFocus": .bool(canFocus),
            "canPress": .bool(canPress),
            "canScroll": .bool(canScroll),
            "canIncrement": .bool(canIncrement),
            "canDecrement": .bool(canDecrement),
            "x": .number(x),
            "y": .number(y),
            "score": JSONValue.numberOrNull(score)
        ])
    }
}

struct CurrentTarget: Equatable, Sendable {
    var appName: String
    var bundleId: String?
    var pid: Int32
    var windowTitle: String
    var windowId: UInt32
    var windowRef: String?
    var nativeWindowRef: String?
}

struct ResolvedTarget: Equatable, Sendable {
    var appName: String
    var bundleId: String?
    var pid: Int32
    var windowTitle: String
    var windowId: UInt32
    var windowRef: String?
    var nativeWindowRef: String?
    var framePoints: FramePoints
    var scaleFactor: Double
    var isMinimized: Bool
    var isOnscreen: Bool
    var isMain: Bool
    var isFocused: Bool
}

struct CurrentCapture: Equatable, Sendable {
    var stateId: String
    var width: Int
    var height: Int
    var scaleFactor: Double
    var timestamp: Int64
}

struct StateTargetSnapshot: Equatable, Sendable {
    var pid: Int32
    var windowId: UInt32
    var windowRef: String?
}

struct WindowRefRecord: Equatable, Sendable {
    var ref: String
    var appName: String
    var bundleId: String?
    var pid: Int32
    var windowTitle: String
    var windowId: UInt32?
    var nativeWindowRef: String?
    var framePoints: FramePoints
    var scaleFactor: Double
    var isMinimized: Bool
    var isOnscreen: Bool
    var isMain: Bool
    var isFocused: Bool
}

struct CaptureResult: Sendable {
    var target: ResolvedTarget
    var capture: CurrentCapture
    var image: ScreenshotPayload?
    var axTargets: [AxTarget]
    var axDiagnostics: AxDiagnostics?
    var activation: ActivationFlags
}

struct ActivationFlags: Equatable, Sendable {
    var activated: Bool = false
    var unminimized: Bool = false
    var raised: Bool = false

    var json: JSONValue {
        .object([
            "activated": .bool(activated),
            "unminimized": .bool(unminimized),
            "raised": .bool(raised)
        ])
    }
}

struct AxDiagnostics: Equatable, Sendable {
    var reason: String?
    var message: String?

    var json: JSONValue {
        .object([
            "reason": JSONValue.stringOrNull(reason),
            "message": JSONValue.stringOrNull(message)
        ])
    }
}

struct FocusWindowResult: Equatable, Sendable {
    var focused: Bool
    var reason: String?
}

struct AxActionResult: Equatable, Sendable {
    var performed: Bool
    var reason: String?
    var ownerPid: Int32?
}

struct AxFocusResult: Equatable, Sendable {
    var focused: Bool
    var reason: String?
    var ownerPid: Int32?
}

struct AxScrollResult: Equatable, Sendable {
    var scrolled: Bool
    var reason: String?
    var ownerPid: Int32?
}

struct FocusedElementResult: Equatable, Sendable {
    var exists: Bool
    var elementRef: String?
    var role: String?
    var subrole: String?
    var isTextInput: Bool
    var isSecure: Bool
    var canSetValue: Bool
    var reason: String?
}

struct ExecutionTrace: Equatable, Sendable {
    var strategy: String
    var axAttempted: Bool?
    var axSucceeded: Bool?
    var fallbackUsed: Bool?
    var runtimeMode: String
    var variant: String
    var stealthCompatible: Bool
    var nonStealthReason: String?
    var actionCount: Int?
    var completedActionCount: Int?
    var actions: [BatchActionTrace]?

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "strategy": .string(strategy),
            "runtimeMode": .string(runtimeMode),
            "variant": .string(variant),
            "stealthCompatible": .bool(stealthCompatible)
        ]
        if let axAttempted { object["axAttempted"] = .bool(axAttempted) }
        if let axSucceeded { object["axSucceeded"] = .bool(axSucceeded) }
        if let fallbackUsed { object["fallbackUsed"] = .bool(fallbackUsed) }
        if let nonStealthReason { object["nonStealthReason"] = .string(nonStealthReason) }
        if let actionCount { object["actionCount"] = .number(Double(actionCount)) }
        if let completedActionCount { object["completedActionCount"] = .number(Double(completedActionCount)) }
        if let actions { object["actions"] = .array(actions.map(\.json)) }
        return .object(object)
    }
}

struct BatchActionTrace: Equatable, Sendable {
    var index: Int
    var type: String
    var strategy: String
    var durationMs: Int
    var axAttempted: Bool?
    var axSucceeded: Bool?
    var fallbackUsed: Bool?
    var runtimeMode: String
    var variant: String
    var stealthCompatible: Bool
    var nonStealthReason: String?

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "index": .number(Double(index)),
            "type": .string(type),
            "strategy": .string(strategy),
            "durationMs": .number(Double(durationMs)),
            "runtimeMode": .string(runtimeMode),
            "variant": .string(variant),
            "stealthCompatible": .bool(stealthCompatible)
        ]
        if let axAttempted { object["axAttempted"] = .bool(axAttempted) }
        if let axSucceeded { object["axSucceeded"] = .bool(axSucceeded) }
        if let fallbackUsed { object["fallbackUsed"] = .bool(fallbackUsed) }
        if let nonStealthReason { object["nonStealthReason"] = .string(nonStealthReason) }
        return .object(object)
    }
}

struct PendingBrowserAddress: Equatable, Sendable {
    var text: String
    var pid: Int32
    var windowId: UInt32
}
