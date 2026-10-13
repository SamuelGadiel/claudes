import Foundation

/// Resolves the real PATH of the user's login shell — the only recourse against
/// the minimal PATH that a GUI app launched via Finder/LaunchServices inherits from
/// launchd. Expensive: measures ~2s on this machine (oh-my-zsh/powerlevel10k in
/// `.zshrc`) — that's why it's only called as a last resort by
/// `ClaudeExecutable`, never directly by anyone who just needs to run `claude`.
enum ShellPath {
    private static var cached: String?

    static func resolved() -> String {
        if let cached { return cached }
        let resolved = resolve()
        cached = resolved
        return resolved
    }

    /// More reliable than the `$SHELL` env var for a GUI app (which doesn't
    /// inherit the user's terminal environment) — reads directly from the
    /// system's user database.
    static func loginShell() -> String {
        guard let pw = getpwuid(getuid()) else { return "/bin/zsh" }
        return String(cString: pw.pointee.pw_shell)
    }

    private static func resolve() -> String {
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let shell = loginShell()
        // Unique delimiter around the real value — an interactive shell (-i)
        // may print banners/MOTD from plugins (oh-my-zsh, starship, etc.)
        // before our echo; without this, that noise would pollute the extracted PATH.
        let marker = "__cs_path__"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -i loads .zshrc/.bashrc, -l loads .zprofile — between the two
        // they cover where most people export PATH.
        process.arguments = ["-ilc", "echo \"\(marker):$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            return fallback
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        // A misconfigured login shell could hang waiting for something —
        // we never let that hang the resolution indefinitely.
        if semaphore.wait(timeout: .now() + 5) == .timedOut, process.isRunning {
            process.terminate()
            return fallback
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return fallback }

        for line in output.split(separator: "\n").reversed() {
            if line.hasPrefix("\(marker):") {
                let value = line.dropFirst(marker.count + 1).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? fallback : value
            }
        }
        return fallback
    }
}
