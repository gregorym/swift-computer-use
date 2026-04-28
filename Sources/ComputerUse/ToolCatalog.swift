import Foundation

enum ToolCatalog {
    static let names: Set<String> = Set(tools.map(\.name))

    static let tools: [ComputerUseTool] = [
        tool("list_apps", "List running macOS apps that can be inspected for computer-use windows.", object()),
        tool("list_windows", "List controllable windows for running macOS apps, with titles, ids, geometry, and focus state.", object(
            property("app", string("Optional app name filter, e.g. Safari")),
            property("bundleId", string("Optional bundle ID filter, e.g. com.apple.Safari")),
            property("pid", number("Optional process ID filter from list_apps"))
        )),
        tool("screenshot", "Capture the current controlled macOS window, returning semantic AX targets and attaching an image only when fallback is needed.", object(
            property("app", string("Optional app name, e.g. Safari")),
            property("windowTitle", string("Optional window title filter")),
            property("window", windowSelector()),
            property("image", imageMode())
        )),
        tool("click", "Click inside the current controlled window by AX target ref or screenshot-relative coordinates.", object(
            property("x", number("X coordinate in screenshot pixels")),
            property("y", number("Y coordinate in screenshot pixels")),
            property("ref", string("Optional AX target ref from the latest screenshot, e.g. @e1")),
            property("button", enumString(["left", "right", "middle"], description: "Mouse button, default left")),
            property("clickCount", number("Number of clicks, default 1")),
            property("window", windowSelector()),
            property("stateId", stateId()),
            property("image", imageMode())
        )),
        tool("double_click", "Double-click inside the current controlled window by AX target ref or screenshot-relative coordinates.", object(
            property("x", number("X coordinate in screenshot pixels")),
            property("y", number("Y coordinate in screenshot pixels")),
            property("ref", string("Optional AX target ref from the latest screenshot, e.g. @e1")),
            property("button", enumString(["left", "right", "middle"], description: "Mouse button, default left")),
            property("window", windowSelector()),
            property("stateId", stateId()),
            property("image", imageMode())
        )),
        tool("move_mouse", "Move the mouse to screenshot-relative coordinates in the current controlled window.", object(
            property("x", number("X coordinate in screenshot pixels")),
            property("y", number("Y coordinate in screenshot pixels")),
            property("window", windowSelector()),
            property("stateId", stateId()),
            property("image", imageMode())
        ), required: ["x", "y"]),
        tool("drag", "Drag along a path of screenshot-relative coordinates in the current controlled window.", object(
            property("path", .object([
                "type": "array",
                "minItems": 2,
                "description": "At least two points, each as {x,y}",
                "items": .object([
                    "type": "object",
                    "properties": .object([
                        "x": .object(["type": "number"]),
                        "y": .object(["type": "number"])
                    ]),
                    "required": .array(["x", "y"])
                ])
            ])),
            property("ref", string("Optional AX adjustable target ref from the latest screenshot, e.g. @e1")),
            property("window", windowSelector()),
            property("stateId", stateId()),
            property("image", imageMode())
        )),
        tool("scroll", "Scroll at screenshot-relative coordinates in the current controlled window.", object(
            property("x", number("X coordinate in screenshot pixels")),
            property("y", number("Y coordinate in screenshot pixels")),
            property("ref", string("Optional AX scroll target ref from the latest screenshot, e.g. @e1")),
            property("scrollX", number("Horizontal scroll delta in pixels")),
            property("scrollY", number("Vertical scroll delta in pixels")),
            property("window", windowSelector()),
            property("stateId", stateId()),
            property("image", imageMode())
        )),
        tool("keypress", "Press one key, a key sequence, or a modifier chord in the current controlled window.", object(
            property("keys", .object([
                "type": "array",
                "minItems": 1,
                "description": "Keys to press. Examples: Enter, Tab, Escape, Command+L.",
                "items": .object(["type": "string"])
            ])),
            property("window", windowSelector()),
            property("stateId", stateId()),
            property("image", imageMode())
        ), required: ["keys"]),
        tool("type_text", "Insert text into the currently focused control in the current controlled window.", object(
            property("text", string("Text to type")),
            property("window", windowSelector()),
            property("stateId", stateId()),
            property("image", imageMode())
        ), required: ["text"]),
        tool("set_text", "Replace an AX text control value by ref, or the currently focused text control when no ref is provided.", object(
            property("text", string("Replacement text value")),
            property("ref", string("Optional AX text target ref from the latest screenshot, e.g. @e1")),
            property("window", windowSelector()),
            property("stateId", stateId()),
            property("image", imageMode())
        ), required: ["text"]),
        tool("wait", "Pause briefly, then return the latest semantic state of the current controlled window.", object(
            property("ms", number("Milliseconds to wait, default 1000")),
            property("window", windowSelector()),
            property("stateId", stateId()),
            property("image", imageMode())
        )),
        tool("arrange_window", "Move or resize a target window for deterministic layout before interacting with it.", object(
            property("window", windowSelector()),
            property("preset", enumString(["center_large", "left_half", "right_half", "top_half", "bottom_half"], description: "Window layout preset")),
            property("x", number("Window x position in screen points")),
            property("y", number("Window y position in screen points")),
            property("width", number("Window width in screen points")),
            property("height", number("Window height in screen points")),
            property("image", imageMode())
        )),
        tool("navigate_browser", "Navigate a target browser window directly to a URL or search string without relying on address-bar keyboard focus.", object(
            property("url", string("URL or browser-search string to open")),
            property("window", windowSelector()),
            property("image", imageMode())
        ), required: ["url"]),
        tool("computer_actions", "Execute a batch of computer-use actions in the current controlled window, then return one latest state update.", object(
            property("actions", .object([
                "type": "array",
                "minItems": 1,
                "maxItems": 20,
                "description": "One to twenty actions to run sequentially",
                "items": .object([
                    "type": "object",
                    "properties": .object([
                        "type": enumString(["click", "double_click", "move_mouse", "drag", "scroll", "keypress", "type_text", "set_text", "wait"], description: "Action type")
                    ]),
                    "required": .array(["type"])
                ])
            ])),
            property("window", windowSelector()),
            property("stateId", stateId()),
            property("image", imageMode())
        ), required: ["actions"])
    ]

    private static func tool(_ name: String, _ description: String, _ schema: JSONValue, required: [String] = []) -> ComputerUseTool {
        var object = schema.objectValue ?? [:]
        object["required"] = .array(required.map(JSONValue.string))
        object["additionalProperties"] = false
        return ComputerUseTool(name: name, description: description, parameters: .object(object))
    }

    private static func object(_ properties: (String, JSONValue)... ) -> JSONValue {
        var output: [String: JSONValue] = [:]
        for (name, schema) in properties {
            output[name] = schema
        }
        return .object([
            "type": "object",
            "properties": .object(output)
        ])
    }

    private static func property(_ name: String, _ schema: JSONValue) -> (String, JSONValue) {
        (name, schema)
    }

    private static func string(_ description: String) -> JSONValue {
        .object(["type": "string", "description": .string(description)])
    }

    private static func number(_ description: String) -> JSONValue {
        .object(["type": "number", "description": .string(description)])
    }

    private static func enumString(_ values: [String], description: String) -> JSONValue {
        .object([
            "type": "string",
            "enum": .array(values.map(JSONValue.string)),
            "description": .string(description)
        ])
    }

    private static func windowSelector() -> JSONValue {
        .object([
            "anyOf": .array([
                .object(["type": "string", "description": "Optional window ref from list_windows, e.g. @w1"]),
                .object(["type": "number", "description": "Optional numeric windowId from list_windows"])
            ])
        ])
    }

    private static func imageMode() -> JSONValue {
        enumString(["auto", "always", "never"], description: "Optional screenshot attachment mode, default auto")
    }

    private static func stateId() -> JSONValue {
        string("Optional state id from the latest screenshot")
    }
}
