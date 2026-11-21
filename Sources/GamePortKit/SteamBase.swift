import Foundation

/// One Windows Steam per engine, installed and self-updated once. New game profiles start as an
/// APFS clone of it: each still has its own prefix and nothing is shared at run time, but a profile is
/// ready in seconds instead of repeating Steam's install and first update (~240 MB) in every profile.
/// Nobody ever signs in to the base, so no account data is copied into the clones.
public struct SteamBase: Sendable {
    public let paths: Paths
    public let engine: InstalledEngine

    public init(paths: Paths, engine: InstalledEngine) { self.paths = paths; self.engine = engine }

    public struct Stamp: Codable, Sendable {
        public var engineID: String
        public var builtAt: Date
    }

    public var directory: URL { paths.base(engine.id) }
    public var prefix: URL { directory.appendingPathComponent("prefix", isDirectory: true) }
    var stampFile: URL { directory.appendingPathComponent("base.json") }
    var steamDirectory: URL { prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true) }

    /// Written only after Steam finished its first update, so a half-built base is never cloned.
    public var stamp: Stamp? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: stampFile)).flatMap { try? decoder.decode(Stamp.self, from: $0) }
    }

    public var isReady: Bool { stamp != nil && FileManager.default.fileExists(atPath: prefix.path) }

    var runner: WineRunner {
        WineRunner(paths: paths, engine: engine,
                   profile: Profile(id: "steam-base", title: "Steam base", recipeID: nil, engineID: engine.id),
                   recipe: nil, directory: directory)
    }

    /// Steam's own updater has finished once both its package receipt and the web helper are in place.
    var steamUpdated: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: steamDirectory.appendingPathComponent("package/steam_client_win64.installed").path)
            && fm.fileExists(atPath: steamDirectory.appendingPathComponent("bin/cef/cef.win64/steamwebhelper.exe").path)
    }

    /// Builds the base from scratch: new prefix, Steam installed, Steam started once to download its
    /// ~240 MB update, then shut down. Takes as long as one Steam first run; every later profile saves it.
    public func build(timeout: TimeInterval = 45 * 60, progress: ProgressHandler? = nil) async throws {
        try? FileManager.default.removeItem(at: directory)
        let runner = self.runner
        progress?("Preparing the Windows environment…")
        try runner.boot()
        let steam = SteamClient(runner: runner)
        try await steam.install(progress: progress)

        progress?("Starting Steam once so it updates itself (~240 MB; a few minutes depending on your connection)…")
        _ = try runner.spawn([steam.windowsExe, "-silent"], sync: SyncMode.none, logName: "steam-base.log")
        let start = Date()
        var lastReport = Date.distantPast
        while !steamUpdated {
            guard Date().timeIntervalSince(start) < timeout else {
                try runner.killAll()
                throw GamePortError.process("Steam's first update did not finish within \(Int(timeout / 60)) minutes", 1)
            }
            if Date().timeIntervalSince(lastReport) >= 60 {
                progress?("\(Int(Date().timeIntervalSince(start) / 60)) min: \(updateStatus() ?? "Steam is starting")")
                lastReport = Date()
            }
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        // Give Steam a moment to finish writing, then ask it to quit; force it if it will not.
        try await Task.sleep(nanoseconds: 20_000_000_000)
        try steam.shutdown(within: 90)

        // Remove what belongs to this one run, not to a fresh Steam.
        for leftover in ["logs", "dumps", "config/loginusers.vdf"] {
            try? FileManager.default.removeItem(at: steamDirectory.appendingPathComponent(leftover))
        }
        try runner.isolateHostDrives()
        let encoder = JSONEncoder.pretty
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Stamp(engineID: engine.id, builtAt: Date())).write(to: stampFile)
        progress?("Steam base ready (\(Int(Date().timeIntervalSince(start) / 60)) min).")
    }

    /// The last download line of Steam's bootstrap log, e.g. "Downloading update (133,128 of 336,229 KB)...".
    func updateStatus() -> String? {
        let log = steamDirectory.appendingPathComponent("logs/bootstrap_log.txt")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last.map { line in
            String(line.drop { $0 != "]" }.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Clones the base prefix to `destination`, which must not exist yet.
    public func clone(to destination: URL) throws {
        guard isReady else { throw GamePortError.missing("the Steam base (\(Brand.cliName) base build)") }
        try CopyOnWrite.clone(prefix, to: destination)
    }

    public func delete() throws {
        try FileManager.default.removeItem(at: directory)
    }
}
