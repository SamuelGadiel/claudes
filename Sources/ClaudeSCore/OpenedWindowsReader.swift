import Foundation

public struct OpenedWindow: Sendable {
    public let path: String
    public let name: String
}

/// Reads the VS Code windows currently open from its storage.json —
/// no special permission needed, full path (no ambiguity
/// from names). See plans/specs/05-app-status-bar.
public enum OpenedWindowsReader {
    static let storagePath = (
        "~/Library/Application Support/Code/User/globalStorage/storage.json" as NSString
    ).expandingTildeInPath

    public static func read() -> [OpenedWindow] {
        guard let data = FileManager.default.contents(atPath: storagePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windowsState = json["windowsState"] as? [String: Any]
        else {
            return []
        }

        var seen = Set<String>()
        var result: [OpenedWindow] = []

        func append(folderURI: String?) {
            guard let folderURI, let url = URL(string: folderURI), url.isFileURL else { return }
            let path = url.path
            guard !seen.contains(path) else { return }
            seen.insert(path)
            result.append(OpenedWindow(path: path, name: (path as NSString).lastPathComponent))
        }

        // With a single window open, VS Code keeps it in `lastActiveWindow`
        // and leaves `openedWindows` empty — it only starts listing windows
        // there once there are 2+ open at once. Confirmed by reading a real
        // storage.json with exactly one window open. Missing this is why a
        // lone open project used to vanish from the panel.
        if let lastActive = windowsState["lastActiveWindow"] as? [String: Any] {
            append(folderURI: lastActive["folder"] as? String)
        }

        let opened = windowsState["openedWindows"] as? [[String: Any]] ?? []
        for entry in opened {
            append(folderURI: entry["folder"] as? String)
        }

        return result
    }
}
