import AppKit
import Darwin
import MachinePulseCore

/// Brings the terminal of an agent session to the front. A session on this
/// Mac is found through its own process; a session on another machine is
/// found through the local `ssh` client whose source port the session saw.
@MainActor
enum TerminalFocus {
    /// Returns a short reason when the terminal could not be shown.
    static func focus(_ session: AgentSessionMetric, isLocal: Bool) async -> String? {
        let pid: Int32
        let tty: String?
        if isLocal {
            pid = session.pid
            tty = session.tty
        } else {
            guard let port = session.sshPort else {
                return "This session does not run in an SSH connection from this Mac."
            }
            guard let client = await sshClient(sourcePort: port) else {
                return "No SSH connection from this Mac matches this session."
            }
            pid = client
            tty = terminalDevice(of: client)
        }

        guard let application = owningApplication(of: pid) else {
            return "MachinePulse could not find the terminal window of this session."
        }
        if let tty, let script = tabScript(bundleIdentifier: application.bundleIdentifier, tty: tty) {
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let code = error?[NSAppleScript.errorNumber] as? Int, code == -1743 {
                application.activate()
                return
                    "Allow MachinePulse to control \(application.localizedName ?? "the terminal") in System Settings › Privacy & Security › Automation."
            }
            if result?.booleanValue == true { return nil }
        }
        application.activate()
        return nil
    }

    static func tabScript(bundleIdentifier: String?, tty: String) -> String? {
        guard tty.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "/") }) else { return nil }
        let device = "/dev/\(tty)"
        switch bundleIdentifier {
        // A Terminal tab whose processes ended keeps its tty name, which the
        // next session can get again. The end of Terminal's activation can
        // bring its last key window back in front after the window moved, so
        // the move is checked and made again. The window goes by id because
        // `targetWindow` is a position in the window order.
        case "com.apple.Terminal":
            return """
                tell application id "com.apple.Terminal"
                    repeat with targetWindow in windows
                        repeat with targetTab in tabs of targetWindow
                            if tty of targetTab is "\(device)" and processes of targetTab is not {} then
                                set targetID to id of targetWindow
                                set selected of targetTab to true
                                activate
                                set miniaturized of window id targetID to false
                                repeat 10 times
                                    set index of window id targetID to 1
                                    delay 0.1
                                    if frontmost and index of window id targetID is 1 then exit repeat
                                end repeat
                                return true
                            end if
                        end repeat
                    end repeat
                    return false
                end tell
                """
        case "com.googlecode.iterm2":
            return """
                tell application id "com.googlecode.iterm2"
                    repeat with targetWindow in windows
                        repeat with targetTab in tabs of targetWindow
                            repeat with targetSession in sessions of targetTab
                                if tty of targetSession is "\(device)" then
                                    select targetWindow
                                    select targetTab
                                    select targetSession
                                    activate
                                    return true
                                end if
                            end repeat
                        end repeat
                    end repeat
                    return false
                end tell
                """
        default:
            return nil
        }
    }

    private static func sshClient(sourcePort: Int) async -> Int32? {
        guard
            let result = try? await CommandRunner.run(
                executable: "/usr/sbin/lsof",
                arguments: ["-nP", "-a", "-c", "ssh", "-iTCP:\(sourcePort)", "-sTCP:ESTABLISHED", "-Fp"],
                timeout: 5
            )
        else { return nil }
        return result.outputString.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("p") }
            .flatMap { Int32($0.dropFirst()) }
    }

    /// The first ancestor that is a regular app: the terminal that hosts the
    /// process, whatever its brand.
    private static func owningApplication(of pid: Int32) -> NSRunningApplication? {
        var current = pid
        var depth = 0
        while current > 1, depth < 16 {
            if let application = NSRunningApplication(processIdentifier: current),
                application.activationPolicy == .regular
            {
                return application
            }
            guard let parent = parent(of: current) else { return nil }
            current = parent
            depth += 1
        }
        return nil
    }

    /// Reads the short record: the full one is refused for processes of other
    /// users, such as the root `login` between a terminal and its shell.
    private static func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(bitPattern: info.pbsi_ppid)
    }

    private static func terminalDevice(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
            info.e_tdev != UInt32(bitPattern: -1),
            let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR)
        else { return nil }
        return String(cString: name)
    }
}
