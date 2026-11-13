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
        case "com.apple.Terminal":
            return """
                tell application id "com.apple.Terminal"
                    repeat with targetWindow in windows
                        repeat with targetTab in tabs of targetWindow
                            if tty of targetTab is "\(device)" then
                                set miniaturized of targetWindow to false
                                set selected of targetTab to true
                                set index of targetWindow to 1
                                activate
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
            guard let info = processInfo(of: current) else { return nil }
            current = Int32(bitPattern: info.pbi_ppid)
            depth += 1
        }
        return nil
    }

    private static func terminalDevice(of pid: Int32) -> String? {
        guard let info = processInfo(of: pid), info.e_tdev != UInt32(bitPattern: -1) else { return nil }
        guard let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        return String(cString: name)
    }

    private static func processInfo(of pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}
