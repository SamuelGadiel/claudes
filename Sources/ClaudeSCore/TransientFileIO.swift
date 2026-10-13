import Foundation

/// Retry/backoff shared by the two Claude extension patches
/// (`VSCodeExtensionPatcher` and `ClaudeExtensionJSPatchRunner`) — the same
/// class of protection against update timing: VS Code may be in the
/// middle of extracting/writing the files of the new version when
/// `VSCodeExtensionWatcher` reacts to the directory change event, so
/// an immediate read might catch a momentarily empty or
/// partial file, and a write might hit a transient lock (AV scanner,
/// the installing process itself, etc).
enum TransientFileIO {
    static let retryDelaysNanoseconds: [UInt64] = [50_000_000, 150_000_000, 400_000_000, 1_000_000_000]

    static func readRaw(path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// While the extension installs/updates, VS Code may truncate the
    /// file before rewriting it — a read at that instant may
    /// catch it empty.
    static func readWithRetry(path: String) async throws -> String {
        var source = readRaw(path: path)
        for delay in retryDelaysNanoseconds where source.isEmpty {
            try await Task.sleep(nanoseconds: delay)
            source = readRaw(path: path)
        }
        return source
    }

    struct StableReadResult {
        let source: String
        let changed: Bool
    }

    /// Re-reads over a window to distinguish an update in progress from
    /// an already-settled file: if the content changes at any point, it's still
    /// being written; if it never changes, it's a genuinely
    /// stable file (and, if it still doesn't have what we're looking for, it's a
    /// real regression, not a timing false positive).
    static func readUntilStable(path: String, initial: String) async throws -> StableReadResult {
        var latest = initial
        var changed = false
        for delay in retryDelaysNanoseconds {
            try await Task.sleep(nanoseconds: delay)
            let current = readRaw(path: path)
            if current != latest {
                changed = true
                latest = current
            }
        }
        return StableReadResult(source: latest, changed: changed)
    }

    /// Antivirus scanners or the installing process itself may
    /// hold the file open briefly right after an update —
    /// retry with backoff instead of failing on the first attempt.
    static func retryOnTransientLock(_ operation: () throws -> Void) async throws {
        for attempt in 0...retryDelaysNanoseconds.count {
            do {
                try operation()
                return
            } catch {
                let nsError = error as NSError
                let isTransient = nsError.domain == NSPOSIXErrorDomain
                    && (nsError.code == Int(EBUSY) || nsError.code == Int(EPERM))
                guard isTransient, attempt < retryDelaysNanoseconds.count else { throw error }
                try await Task.sleep(nanoseconds: retryDelaysNanoseconds[attempt])
            }
        }
    }
}
