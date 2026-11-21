import Foundation

/// An engine is assembled from pinned, SHA-256-verified components (Wine, its runtime
/// frameworks, renderer overlays, tools). The manifest is data: bumping an engine is a JSON change.
public struct EngineManifest: Codable, Sendable, Equatable {
    public struct Extract: Codable, Sendable, Equatable {
        /// Path inside the archive to take (empty = the whole archive).
        public var subpath: String
        /// Destination relative to the engine root.
        public var into: String
    }

    public struct Component: Codable, Sendable, Equatable {
        public var name: String
        public var kind: String            // engine | frameworks | renderer | runtime | tool
        public var url: String
        public var sha256: String
        public var size: Int64?
        public var license: String
        public var note: String?
        /// Archives are unpacked and `extract.subpath` copied to `extract.into`.
        /// Without `extract`, the downloaded file itself is placed at `place` (default tools/<name>).
        public var extract: Extract?
        public var place: String?
        public var executable: Bool?
        /// Lower first; a later component may overwrite a file an earlier one installed.
        public var order: Int?
    }

    public struct License: Codable, Sendable, Equatable {
        public var title: String
        public var summary: String
        public var url: String?
        /// Renderers that may only be used after the user accepts this licence.
        public var gatesRenderers: [String]
    }

    public var schema: Int
    public var id: String
    public var displayName: String
    public var arch: String               // x86_64 (runs under Rosetta 2) | arm64
    public var minMacOS: String
    public var wineLoader: String         // relative path of the wine binary
    public var wineServer: String
    public var components: [Component]
    public var baseEnvironment: [String: String]
    public var licenses: [String: License]
    public var notes: [String]

    public var requiresRosetta: Bool { arch == "x86_64" }

    public static func load(_ url: URL) throws -> EngineManifest {
        let manifest = try JSONDecoder().decode(EngineManifest.self, from: Data(contentsOf: url))
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        try validateID(id, what: "engine id")
        guard schema == 1 else { throw GamePortError.unsupported("engine manifest schema \(schema)") }
        var names = Set<String>()
        for c in components {
            guard names.insert(c.name).inserted else { throw GamePortError.invalid("duplicate component \(c.name)") }
            guard c.sha256.count == 64, c.sha256.allSatisfy(\.isHexDigit) else { throw GamePortError.invalid("\(c.name): sha256") }
            guard c.url.hasPrefix("https://") else { throw GamePortError.invalid("\(c.name): URL must use https") }
            if let e = c.extract {
                _ = try Archive.safeSubpath(e.subpath)
                _ = try Archive.safeSubpath(e.into)
            }
            if let p = c.place { _ = try Archive.safeSubpath(p) }
        }
    }
}

/// An engine on disk.
public struct InstalledEngine: Sendable {
    public let manifest: EngineManifest
    public let root: URL

    public var id: String { manifest.id }
    public var wine: URL { root.appendingPathComponent(manifest.wineLoader) }
    public var wineServer: URL { root.appendingPathComponent(manifest.wineServer) }
    public var frameworks: URL { root.appendingPathComponent("frameworks", isDirectory: true) }

    /// A renderer overlay: the engine's own `renderers/<name>` wins over the one the runtime
    /// frameworks bundle (`frameworks/renderer/<name>`), so a newer DXMT can replace the bundled one.
    public func rendererDirectory(_ name: String) -> URL? {
        let candidates = [
            root.appendingPathComponent("renderers/\(name)", isDirectory: true),
            frameworks.appendingPathComponent("renderer/\(name)", isDirectory: true),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("wine").path) || FileManager.default.fileExists(atPath: $0.appendingPathComponent("external").path) }
    }

    /// The KosmicKrisp shim, when KosmicKrisp is installed in `renderers/kosmickrisp`
    /// (Tools/kosmickrisp-shim/install.sh): the shim, its link back to MoltenVK and the driver itself.
    public var kosmicKrispShim: URL? {
        let dir = root.appendingPathComponent("renderers/kosmickrisp", isDirectory: true)
        let parts = ["libMoltenVK.dylib", "libMoltenVK-engine.dylib", "libvulkan_kosmickrisp.dylib"]
        guard parts.allSatisfy({ FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }) else { return nil }
        return dir.appendingPathComponent("libMoltenVK.dylib")
    }

    /// Base environment with `${root}` and `${frameworks}` expanded.
    public func baseEnvironment() -> [String: String] {
        manifest.baseEnvironment.mapValues {
            $0.replacingOccurrences(of: "${root}", with: root.path)
              .replacingOccurrences(of: "${frameworks}", with: frameworks.path)
        }
    }
}

public struct EngineStore: Sendable {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    static let receiptName = "gameport-engine.json"

    public func installed() -> [InstalledEngine] {
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: paths.engines.path) else { return [] }
        return ids.sorted().compactMap { try? engine($0) }
    }

    public func engine(_ id: String) throws -> InstalledEngine {
        try validateID(id, what: "engine id")
        let root = paths.engine(id)
        let receipt = root.appendingPathComponent(Self.receiptName)
        guard FileManager.default.fileExists(atPath: receipt.path) else { throw GamePortError.missing("engine \(id) is not installed") }
        let manifest = try JSONDecoder().decode(EngineManifest.self, from: Data(contentsOf: receipt))
        return InstalledEngine(manifest: manifest, root: root)
    }

    /// Bundled manifests shipped inside the app.
    public static func bundledManifests() -> [EngineManifest] {
        BundledData.engineManifests.compactMap { text in
            guard let m = try? JSONDecoder().decode(EngineManifest.self, from: Data(text.utf8)), (try? m.validate()) != nil else { return nil }
            return m
        }
    }

    /// Installs into a staging folder and swaps it in only when every component verified,
    /// so a failed install never leaves a half engine behind.
    @discardableResult
    public func install(_ manifest: EngineManifest, progress: ProgressHandler? = nil) async throws -> InstalledEngine {
        try manifest.validate()
        try paths.ensure(paths.engines, paths.downloads, paths.temp)
        let downloader = Downloader(cache: paths.downloads)
        let staging = paths.temp.appendingPathComponent("engine-\(manifest.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let ordered = manifest.components.enumerated().sorted { ($0.element.order ?? 0, $0.offset) < ($1.element.order ?? 0, $1.offset) }.map(\.element)
        for component in ordered {
            guard let url = URL(string: component.url) else { throw GamePortError.invalid(component.url) }
            let file = try await downloader.fetch(url, sha256: component.sha256, size: component.size, progress: progress)
            try place(component, file: file, engineRoot: staging)
            progress?("Installed: \(component.name)")
        }
        let receipt = try JSONEncoder.pretty.encode(manifest)
        try receipt.write(to: staging.appendingPathComponent(Self.receiptName))

        let target = paths.engine(manifest.id)
        if FileManager.default.fileExists(atPath: target.path) {
            let old = paths.temp.appendingPathComponent("old-\(manifest.id)-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: target, to: old)
            try? FileManager.default.removeItem(at: old)
        }
        try FileManager.default.moveItem(at: staging, to: target)
        let engine = InstalledEngine(manifest: manifest, root: target)
        guard FileManager.default.fileExists(atPath: engine.wine.path) else { throw GamePortError.missing("no wine in the engine: \(manifest.wineLoader)") }
        return engine
    }

    func place(_ c: EngineManifest.Component, file: URL, engineRoot: URL) throws {
        let fm = FileManager.default
        guard let extract = c.extract else {
            let dest = engineRoot.appendingPathComponent(try Archive.safeSubpath(c.place ?? "tools/\(c.name)"))
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: file, to: dest)
            if c.executable ?? (c.kind == "tool") {
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
            return
        }
        let unpack = engineRoot.deletingLastPathComponent().appendingPathComponent("unpack-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: unpack) }
        try Archive.extract(file, into: unpack)
        let sub = try Archive.safeSubpath(extract.subpath)
        var source = sub.isEmpty ? unpack : unpack.appendingPathComponent(sub)
        if !fm.fileExists(atPath: source.path), fm.fileExists(atPath: unpack.appendingPathComponent("./" + sub).path) {
            source = unpack.appendingPathComponent("./" + sub)
        }
        guard fm.fileExists(atPath: source.path) else { throw GamePortError.missing("\(c.name): '\(extract.subpath)' is not in the archive") }
        let dest = engineRoot.appendingPathComponent(try Archive.safeSubpath(extract.into))
        try mergeCopy(from: source, to: dest)
    }

    /// Copies a file or a directory tree, overwriting files that already exist at the destination.
    func mergeCopy(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        let type = (try? fm.attributesOfItem(atPath: source.path)[.type]) as? FileAttributeType
        var isDir: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isDir)
        // Framework bundles are full of symlinks (Versions/Current): copy those as links, never follow them.
        if type == .typeSymbolicLink || !isDir.boolValue {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: source, to: dest)
            return
        }
        if !fm.fileExists(atPath: dest.path) {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: dest)
            return
        }
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            try mergeCopy(from: source.appendingPathComponent(name), to: dest.appendingPathComponent(name))
        }
    }

    public func remove(_ id: String) throws {
        try validateID(id, what: "engine id")
        try FileManager.default.removeItem(at: paths.engine(id))
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
