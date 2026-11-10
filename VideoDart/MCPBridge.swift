import AppKit

/// What `VideoDart --mcp` runs instead of the app: a relay between an MCP client's stdio
/// and the socket the running app listens on. It knows nothing about the protocol beyond
/// where a line ends, so there is one implementation of every tool — the app's — and no
/// second process that could write the queue.
///
/// Nothing here may start `NSApplication`, Sparkle, `Prefs` or SelfCheck: an MCP client
/// launches this for every session, and it must never show up as a second VideoDart.
enum MCPBridge {
    private static let unreachable =
        "VideoDart could not be started, or agent access is turned off. Open VideoDart and check Settings ▸ Agents."

    static func run() -> Never {
        // A client that goes away mid-reply closes stdout; the default action for the
        // signal that follows is to die with no chance to exit cleanly.
        signal(SIGPIPE, SIG_IGN)

        let path = MCPSocket.url.path
        let fd = reach(path)
        if fd >= 0 { relay(fd) }
        explain(path)
    }

    // MARK: - Finding the app

    private static func reach(_ path: String) -> Int32 {
        var fd = MCPSocket.connect(path)
        if fd >= 0 { return fd }

        // A client with two sessions starts two relays in the same instant. Without
        // this, both find nobody listening and each launches a copy of the app.
        let lock = open(AppSupport.file("mcp.lock").path, O_CREAT | O_RDWR, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer { if lock >= 0 { close(lock) } }

        fd = MCPSocket.connect(path)
        if fd >= 0 { return fd }

        var patience = 15.0
        if isAppRunning {
            // Up and not listening: agent access is off, or this is its first second.
            // Either way there is nothing to start, and no reason to wait the full time.
            patience = 4
            note("VideoDart is running but not answering; waiting for it.")
        } else if !launch() {
            return -1
        }
        let deadline = Date().addingTimeInterval(patience)
        while Date() < deadline {
            usleep(200_000)
            fd = MCPSocket.connect(path)
            if fd >= 0 { return fd }
        }
        return -1
    }

    /// This copy of the app, not any copy: a build beside an installed one shares the
    /// bundle identifier, and the other one may be older than the server.
    private static var isAppRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let here = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains {
            $0.processIdentifier != getpid() && $0.bundleURL?.resolvingSymlinksInPath() == here
        }
    }

    private static func launch() -> Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            note("Not inside an app bundle, so there is no VideoDart to start: \(bundle.path)")
            return false
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -g: in the background — the user is in their editor, not asking for a window.
        // No -n: `open` on a path starts that copy even while another with the same
        // identifier is running, and on a copy already running it starts nothing — which
        // is the right answer if the user opened the app in the same second.
        task.arguments = ["-g", bundle.path]
        task.standardOutput = FileHandle.standardError
        task.standardError = FileHandle.standardError
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            note("Could not start VideoDart: \(error.localizedDescription)")
            return false
        }
        note("Starting VideoDart.")
        return task.terminationStatus == 0
    }

    // MARK: - Relaying

    /// `unsent` is whatever stdin had already delivered past the last whole line.
    private static func relay(_ fd: Int32, unsent: LineBuffer = LineBuffer()) -> Never {
        // stdin → socket, on its own thread: both directions block.
        Thread.detachNewThread {
            var buffer = unsent
            while let bytes = MCPSocket.readSome(STDIN_FILENO) {
                for line in buffer.append(bytes) {
                    guard MCPSocket.writeAll(fd, Data((line + "\n").utf8)) else { exit(0) }
                }
            }
            // Half-close rather than exit: requests already sent are still owed their
            // answers, and `printf … | VideoDart --mcp` would otherwise print nothing.
            // The app answers what it has, closes, and the loop below ends.
            shutdown(fd, SHUT_WR)
        }

        // socket → stdout. Whole lines only, written unbuffered, so the client never
        // reads half a message and never waits on one sitting in a buffer here.
        var buffer = LineBuffer()
        while let bytes = MCPSocket.readSome(fd) {
            for line in buffer.append(bytes) {
                guard MCPSocket.writeAll(STDOUT_FILENO, Data((line + "\n").utf8)) else { exit(0) }
            }
        }
        exit(0)
    }

    /// No app to talk to. Stay up and answer every request with the reason, so the client
    /// shows a sentence instead of "server exited" — and take the app if it turns up.
    private static func explain(_ path: String) -> Never {
        note(unreachable)
        var buffer = LineBuffer()
        while let bytes = MCPSocket.readSome(STDIN_FILENO) {
            let lines = buffer.append(bytes)
            for (index, line) in lines.enumerated() {
                let fd = MCPSocket.connect(path)
                if fd >= 0 {
                    MCPSocket.writeAll(fd, Data(lines[index...].map { $0 + "\n" }.joined().utf8))
                    relay(fd, unsent: buffer)
                }
                guard let id = JSON(parsing: line)?["id"], id != .null else { continue }
                let reply = MCP.error(id: id, code: -32000, unreachable)
                guard MCPSocket.writeAll(STDOUT_FILENO, Data((reply.line + "\n").utf8)) else { exit(0) }
            }
        }
        exit(0)
    }

    /// stdout is the protocol; anything for a person goes to stderr, where clients log it.
    private static func note(_ text: String) {
        FileHandle.standardError.write(Data("videodart: \(text)\n".utf8))
    }
}
