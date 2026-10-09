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
              let windowsState = json["windowsState"] as? [String: Any],
              let opened = windowsState["openedWindows"] as? [[String: Any]]
        else {
            return []
        }

        var seen = Set<String>()
        var result: [OpenedWindow] = []

        for entry in opened {
            guard let folderURI = entry["folder"] as? String,
                  let url = URL(string: folderURI),
                  url.isFileURL
            else { continue }

            let path = url.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            result.append(OpenedWindow(path: path, name: (path as NSString).lastPathComponent))
        }

        return result
    }
}
