# Claude Usage widget

A small desktop widget for macOS that shows your Claude plan usage (current session and this week) without opening the app.

- **Data:** reads Claude Code's login from the Keychain and calls the same usage endpoint `/usage` uses. Refreshes every 5 minutes, after wake, or when you click the widget.
- **Drag** to move it. **Right-click** for: Refresh, Keep on Top of Windows, Launch at Login, Open Usage in Browser, Quit.
- If it says *Login expired*, use Claude Code once (it renews its own login) and the widget picks up the new token on its next refresh.

## Build

```sh
./build.sh           # builds build/Claude Usage.app
./build.sh install   # also copies it to ~/Applications and launches it
```

Needs the Xcode command-line tools (`swiftc`). Source lives in `Sources/`.
