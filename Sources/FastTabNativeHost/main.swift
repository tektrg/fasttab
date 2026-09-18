import Foundation

// FastTab native-messaging host.
//
// Chrome launches this child process when the FastTab extension opens a
// native-messaging port. It is a pure pipe between Chrome (stdin/stdout) and
// the already-running FastTab.app (a Unix domain socket): a frame read on one
// side is written verbatim to the other. The framing is identical on both sides
// (4-byte little-endian length prefix + payload), so this file never parses or
// interprets a message — it carries no state and has no logic beyond the relay.
//
// If FastTab.app isn't running, the socket connect fails and the host exits
// cleanly; the extension then shows "not connected". The extension reconnects
// on its own, which spawns a fresh host that succeeds once the app is up.
//
// Never write anything to stdout except relayed frames — Chrome reads that
// stream as framing. Diagnostics go to stderr only.

// Must match `ExtensionBridge.socketPath` in the FastTab target. The two are
// separate executables with no shared library, so the path is declared in both
// places — keep them in sync. `FASTTAB_HOST_SOCKET` overrides the path for the
// relay smoke test; production runs without it.
private let socketPath: String = {
    if let override = ProcessInfo.processInfo.environment["FASTTAB_HOST_SOCKET"], !override.isEmpty {
        return override
    }
    return NSHomeDirectory() + "/Library/Application Support/com.trungluong.FastTab/extension-bridge.sock"
}()

private func connectSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
    socketPath.withCString { pathCString in
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            _ = strlcpy(sunPath, pathCString, sunPathSize)
        }
    }

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        return nil
    }
    return fd
}

private func readExact(fd: Int32, into buffer: UnsafeMutableRawPointer, count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let n = read(fd, buffer.advanced(by: offset), count - offset)
        if n <= 0 { return false }
        offset += n
    }
    return true
}

/// Reads one native-messaging frame (4-byte LE length + payload), or nil at
/// EOF/error. Cap guards against a corrupt length prefix.
private func readFrame(fd: Int32) -> Data? {
    var lengthBytes = [UInt8](repeating: 0, count: 4)
    let gotLength = lengthBytes.withUnsafeMutableBytes { ptr in
        readExact(fd: fd, into: ptr.baseAddress!, count: 4)
    }
    guard gotLength else { return nil }

    let length = Int(lengthBytes[0])
        | (Int(lengthBytes[1]) << 8)
        | (Int(lengthBytes[2]) << 16)
        | (Int(lengthBytes[3]) << 24)
    guard length >= 0, length <= 64 * 1024 * 1024 else { return nil }

    var payload = [UInt8](repeating: 0, count: length)
    let gotPayload = payload.withUnsafeMutableBytes { ptr in
        readExact(fd: fd, into: ptr.baseAddress!, count: length)
    }
    guard gotPayload else { return nil }

    var frame = Data()
    frame.reserveCapacity(4 + length)
    frame.append(contentsOf: lengthBytes)
    frame.append(contentsOf: payload)
    return frame
}

private func writeAll(fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress, !data.isEmpty else { return true }
        var offset = 0
        while offset < data.count {
            let n = write(fd, base.advanced(by: offset), data.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

private func log(_ message: String) {
    let line = "[FastTabNativeHost] \(message)\n"
    line.withCString { ptr in
        _ = write(STDERR_FILENO, ptr, strlen(ptr))
    }
}

guard let socketFD = connectSocket() else {
    log("connect to \(socketPath) failed (FastTab not running?); exiting cleanly")
    exit(0)
}

let stdinFD = FileHandle.standardInput.fileDescriptor
let stdoutFD = FileHandle.standardOutput.fileDescriptor

/// Chrome's native-messaging protocol closes the port when the host sends an
/// unsolicited frame (anything not in direct response to the extension). The
/// bridge's keepalive pings are app<->bridge protocol, not for Chrome — if the
/// host forwards them to stdout, Chrome kills the connection. Filter them out.
@Sendable
private func isPingOrPong(_ frame: Data) -> Bool {
    // Length-prefixed frame: 4 bytes LE length + JSON payload. The JSON
    // "type" field is always near the start. Checking for "ping" or "pong"
    // within the JSON is sufficient — no false positives on real tab data.
    let payload = frame.dropFirst(4)
    guard let json = String(data: payload, encoding: .utf8) else { return false }
    return json.contains("\"type\":\"ping\"") || json.contains("\"type\":\"pong\"")
}

@Sendable
private func isPing(_ frame: Data) -> Bool {
    let payload = frame.dropFirst(4)
    guard let json = String(data: payload, encoding: .utf8) else { return false }
    return json.contains("\"type\":\"ping\"")
}

// Pump stdin → socket. EOF on stdin means Chrome closed the port (extension
// unloaded, browser quit) — the relay is done, exit.
Thread.detachNewThread {
    while let frame = readFrame(fd: stdinFD) {
        if !writeAll(fd: socketFD, frame) { exit(0) }
    }
    exit(0)
}

// Pump socket → stdout. Filter out ping/pong — Chrome sees an unsolicited
// frame from the host and closes the port, which kills the connection.
// For keepalive pings from the app's bridge, reply directly back with pong
// on the socket so the app knows the host is alive and doesn't mark it stale.
Thread.detachNewThread {
    while let frame = readFrame(fd: socketFD) {
        if isPing(frame) {
            let pongPayload = "{\"v\":1,\"type\":\"pong\",\"seq\":0,\"payload\":{}}".data(using: .utf8)!
            var pongFrame = Data()
            var len = UInt32(pongPayload.count).littleEndian
            pongFrame.append(Data(bytes: &len, count: 4))
            pongFrame.append(pongPayload)
            if !writeAll(fd: socketFD, pongFrame) { exit(0) }
            continue
        }
        if isPingOrPong(frame) { continue }
        if !writeAll(fd: stdoutFD, frame) { exit(0) }
    }
    exit(0)
}

// Keep the process alive; the pump threads own shutdown.
dispatchMain()
