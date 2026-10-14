import Foundation

/// Launches subprocesses like `Process` does, but with TCC responsibility
/// explicitly disclaimed at spawn time — the child becomes its own
/// "responsible process" instead of inheriting ours.
///
/// Without this, every TCC-protected resource the `claude` binary happens
/// to touch (Downloads, Photos, iCloud Drive, folders managed by Google
/// Drive/Apple Music, etc.) shows a permission prompt attributed to THIS
/// app — confusing and alarming for a menu bar account switcher that never
/// asked for any of that itself. Confirmed by reading how macOS TCC works:
/// child processes inherit their "responsible process" from the parent by
/// default, and the system shows/attributes the permission dialog to
/// whichever process is responsible — not necessarily the one actually
/// making the call. `responsibility_spawnattrs_setdisclaim` is a private
/// but widely-used API (real terminal emulators like Ghostty use it for
/// the exact same reason: a shell they spawn shouldn't make every tool run
/// inside it ask for permissions attributed to the terminal app) that
/// breaks that inheritance chain right at `posix_spawn` time. `Process`
/// (Foundation's wrapper over `posix_spawn`) doesn't expose spawn
/// attributes, so this reimplements just enough of its surface to be a
/// drop-in replacement at the call sites that launch `claude`.
public final class DisclaimedProcess {
    /// Where to connect one of the child's standard streams.
    public enum Stdio {
        /// Don't redirect — the child inherits this process's own fd,
        /// same as leaving stdin/stdout/stderr untouched on `Process`.
        case inherit
        /// A simple handle, not a pipe we own the other end of (e.g.
        /// `.nullDevice`, or a file opened for writing) — no automatic
        /// close happens on our side after spawning.
        case handle(FileHandle)
        /// A `Pipe` we own one end of. After spawning, the end handed to
        /// the child is closed on our side automatically — the parent
        /// only ever touches the other end (`fileHandleForWriting` for
        /// stdin, `fileHandleForReading` for stdout/stderr).
        case pipe(Pipe)
    }

    public var executableURL: URL?
    public var arguments: [String] = []
    public var environment: [String: String]?
    public var currentDirectoryURL: URL?
    public var standardInput: Stdio = .inherit
    public var standardOutput: Stdio = .inherit
    public var standardError: Stdio = .inherit
    public var terminationHandler: ((DisclaimedProcess) -> Void)?

    private var pid: pid_t = -1
    public private(set) var terminationStatus: Int32 = 0
    public private(set) var isRunning = false
    private var monitorSource: DispatchSourceProcess?

    public init() {}

    public enum SpawnError: LocalizableError, CustomStringConvertible {
        case noExecutableURL
        case spawnFailed(Int32)

        public var l10nKey: String {
            switch self {
            case .noExecutableURL: return "no executableURL set"
            case .spawnFailed: return "posix_spawn failed with errno %d"
            }
        }

        public var l10nArgs: [CVarArg] {
            switch self {
            case .noExecutableURL: return []
            case .spawnFailed(let code): return [code]
            }
        }

        public var description: String { englishText }
    }

    public func run() throws {
        guard let executableURL else { throw SpawnError.noExecutableURL }
        let path = executableURL.path

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        func childFileDescriptor(for stdio: Stdio) -> Int32? {
            switch stdio {
            case .inherit: return nil
            case .handle(let handle): return handle.fileDescriptor
            case .pipe(let pipe): return pipe.fileHandleForReading.fileDescriptor
            }
        }
        func childFileDescriptorForWriting(for stdio: Stdio) -> Int32? {
            switch stdio {
            case .inherit: return nil
            case .handle(let handle): return handle.fileDescriptor
            case .pipe(let pipe): return pipe.fileHandleForWriting.fileDescriptor
            }
        }

        if let fd = childFileDescriptor(for: standardInput) {
            posix_spawn_file_actions_adddup2(&fileActions, fd, 0)
        }
        if let fd = childFileDescriptorForWriting(for: standardOutput) {
            posix_spawn_file_actions_adddup2(&fileActions, fd, 1)
        }
        if let fd = childFileDescriptorForWriting(for: standardError) {
            posix_spawn_file_actions_adddup2(&fileActions, fd, 2)
        }
        if let currentDirectoryURL {
            posix_spawn_file_actions_addchdir_np(&fileActions, currentDirectoryURL.path)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        DisclaimedProcess.disclaimResponsibility(&attr)

        let argv = [path] + arguments
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        defer { for ptr in cArgv where ptr != nil { free(ptr) } }

        let envDict = environment ?? ProcessInfo.processInfo.environment
        var cEnv: [UnsafeMutablePointer<CChar>?] = envDict.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer { for ptr in cEnv where ptr != nil { free(ptr) } }

        var spawnedPid: pid_t = -1
        let result = posix_spawn(&spawnedPid, path, &fileActions, &attr, &cArgv, &cEnv)

        // The end of any pipe we dup'd into the child must be closed on our
        // side, or reads on the other end never see EOF.
        if case .pipe(let pipe) = standardInput { try? pipe.fileHandleForReading.close() }
        if case .pipe(let pipe) = standardOutput { try? pipe.fileHandleForWriting.close() }
        if case .pipe(let pipe) = standardError { try? pipe.fileHandleForWriting.close() }

        guard result == 0 else { throw SpawnError.spawnFailed(result) }

        pid = spawnedPid
        isRunning = true

        let source = DispatchSource.makeProcessSource(identifier: spawnedPid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(spawnedPid, &status, 0)
            self.terminationStatus = (status >> 8) & 0xFF
            self.isRunning = false
            self.monitorSource = nil
            self.terminationHandler?(self)
        }
        source.resume()
        monitorSource = source
    }

    public func terminate() {
        guard isRunning else { return }
        kill(pid, SIGTERM)
    }

    /// `claude` in `--input-format stream-json ... -p` mode was observed
    /// ignoring SIGTERM entirely (confirmed: closing stdin, waiting, then
    /// `terminate()` left it running indefinitely — had to be killed with
    /// SIGKILL from outside to actually go away). For a read-only flow like
    /// get_usage (never mid-write, unlike a credential renewal or login
    /// flow), there's no data-loss risk in forcing this.
    public func forceTerminate() {
        guard isRunning else { return }
        kill(pid, SIGKILL)
    }

    public func waitUntilExit() {
        guard isRunning else { return }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        terminationStatus = (status >> 8) & 0xFF
        isRunning = false
    }

    /// Resolved via `dlsym` (not linked directly) because this is a
    /// private API, absent from public SDK headers — silently does
    /// nothing on a system where it's unavailable, rather than failing to
    /// launch the process at all over a best-effort privacy improvement.
    private static func disclaimResponsibility(_ attr: inout posix_spawnattr_t?) {
        typealias SetdisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            return
        }
        let fn = unsafeBitCast(symbol, to: SetdisclaimFn.self)
        _ = fn(&attr, 1)
    }
}
