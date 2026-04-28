# ComputerUse

`ComputerUse` is a Swift package for controlling visible macOS windows from an agent runtime.

It provides a list of computer-use tools and implements those tools locally. It does not call an LLM, choose a model, send prompts, or talk to OpenAI/Pi/Anthropic/etc. Your app can pass the tool definitions to any model or agent system, then call `ComputerUseSession.execute(tool:arguments:)` when that system asks to run a tool.

## What It Does

- Lists running apps and windows.
- Captures a target window and returns semantic Accessibility targets such as `@e1`.
- Clicks, scrolls, drags, types, presses keys, sets text values, waits, and arranges windows.
- Prefers macOS Accessibility actions over raw mouse/keyboard events.
- Returns text plus optional PNG image content when visual fallback is useful.
- Keeps state IDs and window refs so callers can detect stale screenshots.

## Requirements

- macOS 14 or newer
- Swift 6.2 or newer
- Host executable permissions:
  - Accessibility
  - Screen Recording

Permissions are granted to the app or executable that imports and runs this package, not to the package itself.

## Install

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/gregorym/swift-computer-use.git", branch: "main")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "ComputerUse", package: "swift-computer-use")
        ]
    )
]
```

For local development:

```swift
.package(path: "../swift-computer-use")
```

## Quick Start

```swift
import ComputerUse

let session = ComputerUseSession()

let permissionStatus = await session.checkPermissions()
if !permissionStatus.accessibility {
    try await session.openPermissionPane(.accessibility)
}
if !permissionStatus.screenRecording {
    try await session.openPermissionPane(.screenRecording)
}

let tools = session.tools

let screenshot = try await session.execute(tool: "screenshot", arguments: [
    "image": "auto"
])

let click = try await session.execute(tool: "click", arguments: [
    "ref": "@e1"
])
```

`tools` contains names, descriptions, and JSON-schema parameter objects. Pass those to your agent runtime. When the runtime asks to call a tool, pass the tool name and JSON arguments to `execute`.

## Normal Workflow

1. Call `screenshot` first. It selects the current controlled window and returns current UI state.
2. If `axTargets` contains useful refs such as `@e1`, prefer refs over coordinates.
3. Use coordinates only when no suitable AX target exists. Coordinates are window-relative screenshot pixels.
4. Pass `stateId` from the latest result when using coordinates, so stale screenshots are rejected.
5. Every successful action returns a refreshed semantic state.

Example:

```swift
let state = try await session.execute(tool: "screenshot", arguments: [
    "app": "TextEdit",
    "image": "auto"
])

let stateId = state.details["capture"]?["stateId"]?.stringValue

_ = try await session.execute(tool: "set_text", arguments: [
    "ref": "@e1",
    "text": "Hello from Swift"
])

_ = try await session.execute(tool: "click", arguments: [
    "x": 120,
    "y": 80,
    "stateId": .string(stateId ?? ""),
    "image": "never"
])
```

## Discovering Windows

Use `list_apps` and `list_windows` when the target app or window is ambiguous.

```swift
let apps = try await session.execute(tool: "list_apps")

let windows = try await session.execute(tool: "list_windows", arguments: [
    "app": "Safari"
])

let selected = try await session.execute(tool: "screenshot", arguments: [
    "window": "@w1"
])
```

Window refs such as `@w1` are stable within the session and can be passed to later tool calls:

```swift
try await session.execute(tool: "click", arguments: [
    "window": "@w1",
    "ref": "@e1"
])
```

## Handling Results

Each result has two parts:

- `content`: user-facing text and optional PNG images
- `details`: structured JSON for state, target, execution metadata, AX targets, and config

```swift
for item in result.content {
    switch item {
    case .text(let text):
        print(text)
    case .image(let data, let mimeType):
        print("Image:", data.count, mimeType)
    }
}

if let targets = result.details["axTargets"]?.arrayValue {
    print("AX target count:", targets.count)
}
```

Important detail fields:

- `target`: app, bundle ID, pid, title, window ID, and window ref
- `capture`: state ID, width, height, scale factor, timestamp, coordinate space
- `axTargets`: semantic UI targets with capabilities like `canPress`, `canSetValue`, and `canScroll`
- `execution`: strategy, AX/fallback status, and strict-mode compatibility
- `imageReason`: why an image was attached, when one is attached

## Tools

| Tool               | Purpose                                                             |
| ------------------ | ------------------------------------------------------------------- |
| `list_apps`        | List running macOS apps.                                            |
| `list_windows`     | List windows, titles, geometry, focus state, and `@w` refs.         |
| `screenshot`       | Select or refresh the controlled window.                            |
| `click`            | Click by AX ref or screenshot coordinate.                           |
| `double_click`     | Double-click by AX ref or coordinate.                               |
| `move_mouse`       | Move the pointer to screenshot coordinates.                         |
| `drag`             | Drag along a coordinate path or adjust an AX target.                |
| `scroll`           | Scroll by AX ref or screenshot coordinate.                          |
| `keypress`         | Press keys such as `Enter`, `Tab`, `Escape`, or `Command+L`.        |
| `type_text`        | Insert text into the focused control.                               |
| `set_text`         | Replace an AX text value by ref or focused text control.            |
| `wait`             | Pause and return refreshed state.                                   |
| `arrange_window`   | Move or resize a window using presets or explicit frame values.     |
| `navigate_browser` | Navigate supported browser windows directly to a URL/search string. |
| `computer_actions` | Run 1 to 20 actions as a batch and return one refreshed state.      |

## Configuration

```swift
let session = ComputerUseSession(config: .init(
    browserUse: true,
    stealthMode: false
))
```

Options:

- `browserUse`: when `false`, known browser windows are refused.
- `stealthMode`: when `true`, only background-safe AX paths are allowed. Raw mouse, raw keyboard, foreground-focus, and cursor fallbacks are blocked.

## Image Mode

Most tools accept `image`:

- `"auto"`: attach an image only when useful for fallback or verification.
- `"always"`: always attach a PNG screenshot.
- `"never"`: suppress image attachment.

```swift
try await session.execute(tool: "screenshot", arguments: [
    "image": "always"
])
```

## Batch Actions

Use `computer_actions` when the next actions are obvious and no intermediate screenshot is needed.

```swift
try await session.execute(tool: "computer_actions", arguments: [
    "actions": [
        ["type": "click", "ref": "@e1"],
        ["type": "set_text", "ref": "@e2", "text": "hello"],
        ["type": "keypress", "keys": ["Enter"]]
    ],
    "image": "auto"
])
```

Do not batch when later actions depend on seeing the result of earlier actions.

## Development

Build and test:

```bash
swift build
swift test
```

The default tests use a fake backend and do not require Accessibility or Screen Recording permission.

To run the gated native smoke test:

```bash
COMPUTER_USE_RUN_NATIVE_TESTS=1 swift test
```

## Notes

- The package currently supports macOS only.
- Accessibility quality varies by app. When AX coverage is weak, results may include a screenshot image so the caller can fall back to visual reasoning.
- Browser direct navigation is implemented for Safari and Chromium-family browsers where macOS scripting supports it.
