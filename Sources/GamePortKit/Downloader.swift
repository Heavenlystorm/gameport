import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public typealias ProgressHandler = @Sendable (_ message: String) -> Void

/// Downloads into a content-addressed cache: a file is kept only once its SHA-256 matches,
/// so an interrupted or tampered download is never used.
public struct Downloader: Sendable {
    public let cache: URL

    public init(cache: URL) { self.cache = cache }

    public func cachedFile(sha256: String, name: String) -> URL {
        cache.appendingPathComponent("\(sha256.prefix(16))-\(name)")
    }

    /// Returns a verified local file for `url`. With `sha256 == nil` the download is kept under its
    /// own hash and the caller decides whether that is acceptable (Steam's ever-changing installer).
    public func fetch(_ url: URL, sha256: String?, size: Int64? = nil, progress: ProgressHandler? = nil) async throws -> URL {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let name = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        if let sha256 {
            let cached = cachedFile(sha256: sha256, name: name)
            if FileManager.default.fileExists(atPath: cached.path) {
                if (try? Checksum.verify(file: cached, sha256: sha256)) != nil {
                    progress?("Cached: \(name)")
                    return cached
                }
                try? FileManager.default.removeItem(at: cached)
            }
        }
        progress?("Downloading: \(name)\(size.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? "")")
        let partial = cache.appendingPathComponent("\(UUID().uuidString).part")
        try await download(url, to: partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        if let size, let actual = try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64, actual != size {
            throw GamePortError.invalid("\(name): expected size \(size), downloaded \(actual)")
        }
        let actual = try Checksum.sha256(file: partial)
        if let sha256, actual != sha256.lowercased() {
            throw GamePortError.checksum(file: name, expected: sha256, actual: actual)
        }
        let final = cachedFile(sha256: actual, name: name)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: partial, to: final)
        progress?("Verified: \(name)")
        return final
    }

    private func download(_ url: URL, to destination: URL) async throws {
        guard url.scheme == "https" else { throw GamePortError.invalid("only https downloads are allowed: \(url)") }
        let (temp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            throw GamePortError.invalid("HTTP \(http.statusCode): \(url)")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }
}

/// Unpacks .tar.gz / .tar.xz / .tgz with the system tar (bsdtar on macOS reads all of them).
public enum Archive {
    public static func extract(_ archive: URL, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path])
    }

    /// Refuses archive paths that would escape `root` (absolute paths, `..`).
    public static func safeSubpath(_ subpath: String) throws -> String {
        let trimmed = subpath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = trimmed.split(separator: "/")
        guard !subpath.hasPrefix("/"), !parts.contains(".."), !trimmed.isEmpty || subpath.isEmpty else {
            throw GamePortError.invalid("unsafe path: \(subpath)")
        }
        return trimmed
    }
}
