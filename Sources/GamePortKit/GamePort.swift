import Foundation

/// The operations the app and the CLI share. Everything a button does goes through here.
public struct GamePort: Sendable {
    public let paths: Paths
    public init(paths: Paths = .default()) { self.paths = paths }

    public var engines: EngineStore { EngineStore(paths: paths) }
    public var profiles: ProfileStore { ProfileStore(paths: paths) }
    public var licenses: LicenseStore { LicenseStore(paths: paths) }
    public var catalog: RecipeCatalog { RecipeCatalog.load(paths: paths) }

    /// The engine new profiles use: the first bundled manifest.
    public var defaultManifest: EngineManifest? { EngineStore.bundledManifests().first }

    public struct Check: Sendable {
        public var name: String
        public var ok: Bool
        public var detail: String
    }

    /// What must be true before anything can run.
    public func doctor() -> [Check] {
        var checks: [Check] = []
        #if os(macOS)
        let v = Shell.macOSVersion
        checks.append(Check(name: "macOS", ok: v.majorVersion >= 14, detail: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (14 or later required)"))
        checks.append(Check(name: "Apple Silicon", ok: Shell.isAppleSilicon, detail: Shell.isAppleSilicon ? "yes" : "Intel Macs are not supported"))
        let rosetta = Shell.rosettaInstalled
        checks.append(Check(name: "Rosetta 2", ok: rosetta, detail: rosetta ? "installed" : "not installed: softwareupdate --install-rosetta --agree-to-license"))
        #else
        checks.append(Check(name: "macOS", ok: false, detail: "\(Brand.displayName) runs games on macOS only"))
        #endif
        let installed = engines.installed()
        checks.append(Check(name: "Engine", ok: !installed.isEmpty, detail: installed.isEmpty ? "not installed: \(Brand.cliName) engine install" : installed.map(\.id).joined(separator: ", ")))
        return checks
    }

    public func installDefaultEngine(progress: ProgressHandler? = nil) async throws -> InstalledEngine {
        guard let manifest = defaultManifest else { throw GamePortError.missing("bundled engine manifest") }
        return try await engines.install(manifest, progress: progress)
    }

    /// Creates an isolated environment for a recipe. With a Steam base for the engine the prefix is an
    /// APFS clone of it (seconds, Steam already updated); otherwise a fresh prefix is booted.
    @discardableResult
    public func createProfile(recipeID: String, profileID: String? = nil, engineID: String? = nil, progress: ProgressHandler? = nil) throws -> Profile {
        guard let recipe = catalog[recipeID] else { throw GamePortError.missing("recipe \(recipeID)") }
        let engine = try engineID.map { try engines.engine($0) } ?? (engines.installed().first ?? { throw GamePortError.missing("no engine installed") }())
        let id = profileID ?? recipe.id
        try validateID(id, what: "profile id")
        if (try? profiles.load(id)) != nil { throw GamePortError.invalid("profile \(id) already exists") }
        let profile = Profile(id: id, title: recipe.title, recipeID: recipe.id, engineID: engine.id)
        try profiles.save(profile)
        // The prefix itself does not need a licence-gated renderer: set it up with wined3d, keep the choice.
        var setupProfile = profile
        if let license = recipe.renderer.gatingLicense(in: engine.manifest), !licenses.isAccepted(license) {
            progress?("Note: the game cannot start until the \(license) licence is accepted.")
            setupProfile.renderer = .wined3d
        }
        let runner = WineRunner(paths: paths, engine: engine, profile: setupProfile, recipe: recipe)
        let base = SteamBase(paths: paths, engine: engine)
        if base.isReady {
            progress?("Cloning the Steam base…")
            try base.clone(to: runner.prefix)
            try runner.settle()
        } else {
            progress?("Preparing the Windows environment (1-2 minutes the first time)…")
            try runner.boot()
        }
        return profile
    }

    public func steamBase(engineID: String? = nil) throws -> SteamBase {
        let engine = try engineID.map { try engines.engine($0) } ?? (engines.installed().first ?? { throw GamePortError.missing("no engine installed") }())
        return SteamBase(paths: paths, engine: engine)
    }

    /// Stops the profile (so Wine has flushed its registry) and snapshots its prefix.
    @discardableResult
    public func snapshot(_ profileID: String, name: String? = nil) throws -> Snapshot {
        try runner(for: profileID).killAll()
        try runner(for: profileID).waitForServer()
        return try profiles.createSnapshot(profileID, name: name)
    }

    /// Steam updates itself and its games whenever it starts, so once a day, before it does, the profile
    /// gets an automatic snapshot (the newest two are kept). Returns nil when none was due or it failed:
    /// a missing snapshot must never stop the player from starting Steam.
    @discardableResult
    public func autoSnapshot(_ profileID: String, now: Date = Date()) -> Snapshot? {
        guard let profile = try? profiles.load(profileID), profile.autoSnapshots ?? true,
              FileManager.default.fileExists(atPath: profiles.prefix(profileID).path),
              profiles.autoSnapshotDue(profileID, now: now) else { return nil }
        let snapshot = try? snapshot(profileID, name: ProfileStore.autoPrefix + ProfileStore.snapshotName(now))
        try? profiles.pruneAutoSnapshots(profileID, keep: 2)
        return snapshot
    }

    public func openSteam(_ profileID: String, progress: ProgressHandler? = nil) throws -> Process {
        if let s = autoSnapshot(profileID) { progress?("Automatic snapshot: \(s.name)") }
        return try steam(for: profileID).openClient()
    }

    public func play(_ profileID: String, progress: ProgressHandler? = nil) throws -> Process {
        if let s = autoSnapshot(profileID) { progress?("Automatic snapshot: \(s.name)") }
        return try steam(for: profileID).play()
    }

    /// Stops the profile and rolls its prefix (and engine choice) back to a snapshot.
    @discardableResult
    public func restore(_ profileID: String, snapshot name: String) throws -> Snapshot {
        if let snapshot = profiles.listSnapshots(profileID).first(where: { $0.name == name }) {
            _ = try engines.engine(snapshot.engineID) // the engine it was taken with must still be installed
        }
        try runner(for: profileID).killAll()
        try runner(for: profileID).waitForServer()
        return try profiles.restoreSnapshot(profileID, name: name)
    }

    public func runner(for profileID: String) throws -> WineRunner {
        let profile = try profiles.load(profileID)
        let engine = try engines.engine(profile.engineID)
        let recipe = profile.recipeID.flatMap { catalog[$0] }
        return WineRunner(paths: paths, engine: engine, profile: profile, recipe: recipe)
    }

    public func steam(for profileID: String) throws -> SteamClient {
        SteamClient(runner: try runner(for: profileID))
    }
}
