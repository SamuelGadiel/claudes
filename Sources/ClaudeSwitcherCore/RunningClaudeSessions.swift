import Foundation

public struct RunningClaudeSession: Sendable {
    public let pid: Int32
    public let cwd: String?
    /// nil when CLAUDE_CONFIG_DIR is not in the process's environment — in that
    /// case it's using the system default (~/.claude).
    public let configDirFromEnv: String?
    /// true when the process has the flags that only the official VS
    /// Code extension (or another integrated editor) passes — used to avoid duplicating
    /// with OpenedWindowsReader's list.
    public let isManagedByEditor: Bool
}

/// Detects running `claude` processes (inside or outside an editor) and reads
/// their real CLAUDE_CONFIG_DIR from the environment — not an inference. Validated
/// on this machine without any special permission (sysctl/proc_pidinfo are
/// standard APIs for processes owned by the same user). See plans/specs/06.
public enum RunningClaudeSessions {
    /// Flags that only appear in processes launched by an integrated editor
    /// (today, the official VS Code extension) — never in a `claude` typed
    /// manually in the terminal.
    private static let editorManagedMarkers = ["--output-format", "--input-format"]

    public static func list() -> [RunningClaudeSession] {
        pidsNamed("claude").compactMap { pid in
            guard let argv = processArgsAndEnv(pid: pid) else { return nil }
            let isManaged = argv.arguments.contains { editorManagedMarkers.contains($0) }
            let configDir = argv.environment["CLAUDE_CONFIG_DIR"]
            let cwd = currentWorkingDirectory(pid: pid)
            return RunningClaudeSession(
                pid: pid, cwd: cwd, configDirFromEnv: configDir, isManagedByEditor: isManaged
            )
        }
    }

    // MARK: - Enumerate PIDs by name (sysctl KERN_PROC_ALL)

    private static func pidsNamed(_ name: String) -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(actualCount).compactMap { proc in
            var comm = proc.kp_proc.p_comm
            let commName = withUnsafePointer(to: &comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) }
            }
            return commName == name ? proc.kp_proc.p_pid : nil
        }
    }

    // MARK: - argv/envp (sysctl KERN_PROCARGS2)

    private static func processArgsAndEnv(pid: Int32) -> (arguments: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        // Layout: argc (Int32) then NUL-separated strings: exec path, argv[1..],
        // then envp — all in one flat byte region. We don't need to honor argc
        // precisely to find CLAUDE_CONFIG_DIR; splitting on NUL and classifying
        // "KEY=VALUE" strings as env and the rest as args is enough here.
        var strings: [String] = []
        var current = [UInt8]()
        for byte in buffer.dropFirst(4) {
            if byte == 0 {
                if !current.isEmpty, let s = String(bytes: current, encoding: .utf8) {
                    strings.append(s)
                }
                current = []
            } else {
                current.append(byte)
            }
        }

        var environment: [String: String] = [:]
        var arguments: [String] = []
        for s in strings {
            if let eq = s.firstIndex(of: "="), s[s.startIndex..<eq].allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) {
                environment[String(s[s.startIndex..<eq])] = String(s[s.index(after: eq)...])
            } else {
                arguments.append(s)
            }
        }
        return (arguments, environment)
    }

    // MARK: - cwd (proc_pidinfo PROC_PIDVNODEPATHINFO)

    private static func currentWorkingDirectory(pid: Int32) -> String? {
        let PROC_PIDVNODEPATHINFO: Int32 = 9
        let bufferSize = 4352
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &buffer, Int32(bufferSize))
        guard ret > 0 else { return nil }

        var current = [UInt8]()
        for byte in buffer {
            if byte >= 0x20 && byte < 0x7f {
                current.append(byte)
            } else {
                if current.count > 1, let s = String(bytes: current, encoding: .ascii), s.hasPrefix("/") {
                    return s
                }
                current = []
            }
        }
        return nil
    }
}
