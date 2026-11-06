import Foundation

/// An absolute path with every symbolic link resolved and each name as the file system spells
/// it, the way `realpath(3)` gives it.
///
/// git and FSEvents name files this way, so a path compared with theirs must be one. Foundation's
/// `resolvingSymlinksInPath()` drops `/private` from `/private/tmp` and `/private/var`, and
/// `standardizedFileURL` leaves links as they are, so neither matches them.
public struct CanonicalPath: Hashable, Sendable, CustomStringConvertible {
    /// The path, without a trailing `/` unless it's the root.
    public let path: String

    /// Canonicalizes a path, resolving its deepest part that exists and keeping the rest as
    /// written, so a path that's gone, or not there yet, still gets one name.
    public init(_ url: URL) {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            path = String(cString: resolved)
            return
        }
        let absolute = url.standardizedFileURL.path
        var existing = absolute
        var missing: [String] = []
        while true {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                path = missing.reversed().reduce(base) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
                return
            }
            guard existing != "/", !existing.isEmpty else {
                path = absolute
                return
            }
            missing.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
    }

    /// Canonicalizes a path given as a string.
    public init(path: String) { self.init(URL(fileURLWithPath: path)) }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// The last name in the path.
    public var name: String { (path as NSString).lastPathComponent }

    public var description: String { path }

    /// Returns a path's components below this one, or nil if it isn't this path or inside it.
    ///
    /// - Parameter other: A canonical path, such as one FSEvents reported.
    public func components(of other: String) -> [Substring]? {
        if other == path { return [] }
        let prefix = path == "/" ? "/" : path + "/"
        guard other.hasPrefix(prefix) else { return nil }
        return other.dropFirst(prefix.count).split(separator: "/")
    }
}
