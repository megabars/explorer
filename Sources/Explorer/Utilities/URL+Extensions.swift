import Foundation

extension URL {
    /// POSIX path with `~` replaced for the home directory for display.
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = self.path
        if p.hasPrefix(home) {
            return "~" + p.dropFirst(home.count)
        }
        return p
    }

    /// All path components as URLs, from root to self.
    var pathComponentURLs: [URL] {
        let parts = self.standardizedFileURL.pathComponents
        var result: [URL] = []
        var accumulated = ""
        for part in parts {
            if part == "/" {
                accumulated = "/"
            } else {
                accumulated = accumulated == "/" ? "/\(part)" : "\(accumulated)/\(part)"
            }
            result.append(URL(fileURLWithPath: accumulated))
        }
        return result
    }
}
