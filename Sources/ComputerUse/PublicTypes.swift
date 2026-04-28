import Foundation

public struct ComputerUseConfig: Equatable, Sendable {
    public var browserUse: Bool
    public var stealthMode: Bool

    public init(browserUse: Bool = true, stealthMode: Bool = false) {
        self.browserUse = browserUse
        self.stealthMode = stealthMode
    }
}

public struct ComputerUseTool: Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public enum ComputerUseContent: Equatable, Sendable {
    case text(String)
    case image(data: Data, mimeType: String)
}

public struct ComputerUseToolResult: Equatable, Sendable {
    public var content: [ComputerUseContent]
    public var details: JSONValue

    public init(content: [ComputerUseContent], details: JSONValue) {
        self.content = content
        self.details = details
    }
}

public enum ComputerUsePermissionKind: String, Sendable {
    case accessibility
    case screenRecording
}

public struct ComputerUsePermissionStatus: Equatable, Sendable {
    public var accessibility: Bool
    public var screenRecording: Bool

    public init(accessibility: Bool, screenRecording: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }
}

public struct ComputerUseError: Error, LocalizedError, Equatable, Sendable {
    public var message: String
    public var code: String

    public init(_ message: String, code: String = "computer_use_error") {
        self.message = message
        self.code = code
    }

    public var errorDescription: String? {
        message
    }
}
