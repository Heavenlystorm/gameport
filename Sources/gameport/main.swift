import Foundation
import GamePortKit

let cli = Brand.cliName
let usage = """
\(Brand.displayName): runs Windows games on Apple Silicon Macs.

Usage:
  \(cli) doctor                         Check system requirements
  \(cli) engine install                 Download, verify and install the bundled engine
  \(cli) engine list                    Installed engines
  \(cli) license show apple-gptk        Show the licence summary
  \(cli) license accept apple-gptk      Accept Apple's GPTK licence for D3DMetal
  \(cli) recipes [words or Steam ID] [--status <status>] [--renderer <renderer>]
  \(cli) anticheat <game name|Steam id> Before downloading: does anti-cheat block it on a Mac?
  \(cli) base build                     Build the Steam base (once; later profiles are ready in seconds)
  \(cli) base status                    Steam base status
  \(cli) profile create <recipe> [id]   Create an isolated Windows environment for a game
  \(cli) profile list                   Profiles
  \(cli) config <profile>               Apply missing optional recipe settings after closing the game
  \(cli) snapshot <profile> [name]      Snapshot a profile (before an update)
  \(cli) snapshot list <profile>        Snapshots
  \(cli) snapshot restore <profile> <name>  Roll a profile back to a snapshot
  \(cli) snapshot delete <profile> <name>   Delete a snapshot
  \(cli) snapshot auto <profile> on|off Daily automatic snapshot before Steam starts (default: on)
  \(cli) steam install <profile>        Install Windows Steam in a profile
  \(cli) steam open <profile>           Open Steam (sign in, store, downloads)
  \(cli) play <profile>                 Start the game
  \(cli) stop <profile>                 Stop everything in a profile
  \(cli) lab <profile> [renderer,…] [s] Start the game, measure FPS and record whether it works
  \(cli) lab <profile> auto [s]         Try every renderer and set the fastest working one
  \(cli) vulkan <profile> [driver]      Vulkan driver for the game: moltenvk (default) or kosmickrisp (experimental)
  \(cli) env <profile>                  Show the game's environment variables
  \(cli) run <profile> <windows command…>  Run a Windows program in a profile

Data: ~/Library/Application Support/\(Brand.dataFolder) (override with \(Brand.homeEnvironmentVariable))
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Asks a yes/no question on the terminal; anything but yes/y counts as no.
func confirm(_ question: String) -> Bool {
    print("\(question) [yes/no] ", terminator: "")
    return ["yes", "y"].contains(readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "")
}

@Sendable func progress(_ message: String) { print("  • \(message)") }
let gameport = GamePort()
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func arg(_ i: Int, _ name: String) -> String {
    guard i < args.count else { fail("missing argument: \(name)\n\n\(usage)") }
    return args[i]
}

do {
    switch command {
    case "doctor":
        var allOK = true
        for c in gameport.doctor() {
            print("\(c.ok ? "✓" : "✗") \(c.name): \(c.detail)")
            allOK = allOK && c.ok
        }
        exit(allOK ? 0 : 1)

    case "engine":
        switch arg(0, "install|list") {
        case "install":
            print("Installing the engine (about 440 MB to download)…")
            let engine = try await gameport.installDefaultEngine(progress: progress)
            print("✓ Installed: \(engine.id)")
        case "list":
            let list = gameport.engines.installed()
            if list.isEmpty { print("No engine installed. Run `\(cli) engine install`.") }
            for e in list { print("\(e.id)  \(e.manifest.displayName)") }
        default: fail(usage)
        }

    case "license":
        let action = arg(0, "show|accept|revoke"), id = arg(1, "licence")
        guard let license = gameport.defaultManifest?.licenses[id] else { fail("unknown licence \(id)") }
        switch action {
        case "show":
            print("\(license.title)\n\n\(license.summary)\n\(license.url.map { "\nFull text: \($0)" } ?? "")")
            print("\nStatus: \(gameport.licenses.isAccepted(id) ? "accepted" : "not accepted")")
        case "accept":
            print("\(license.title)\n\n\(license.summary)\n")
            guard confirm("Do you accept?") else { fail("not accepted") }
            try gameport.licenses.accept(id)
            print("✓ Accepted.")
        case "revoke":
            try gameport.licenses.revoke(id)
            print("✓ Revoked.")
        default: fail(usage)
        }

    case "recipes":
        var filter = RecipeFilter()
        var words: [String] = []
        var tokens = args.makeIterator()
        while let token = tokens.next() {
            switch token {
            case "--status":
                guard let value = tokens.next(), let status = Recipe.Status(rawValue: value) else {
                    fail("--status expects one of " + Recipe.Status.allCases.map(\.rawValue).joined(separator: ", "))
                }
                filter.status = status
            case "--renderer":
                guard let value = tokens.next(), let renderer = Renderer(rawValue: value) else {
                    fail("--renderer expects one of " + Renderer.allCases.map(\.rawValue).joined(separator: ", "))
                }
                filter.renderer = renderer
            default:
                guard !token.hasPrefix("--") else { fail("unknown recipes option \(token)") }
                words.append(token)
            }
        }
        filter.query = words.joined(separator: " ")
        let matches = filter.apply(to: gameport.catalog.sorted)
        if matches.isEmpty { print("No matching recipes.") }
        for r in matches {
            let appID = r.steamAppID.map { "Steam \($0)" } ?? "-"
            print("\(r.id.padding(toLength: 26, withPad: " ", startingAt: 0)) \(r.renderer.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(r.status.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(appID.padding(toLength: 14, withPad: " ", startingAt: 0)) \(r.title)")
        }

    case "config":
        let id = arg(0, "profile")
        guard args.count == 1 else { fail("expected config <profile>") }
        try gameport.applyConfigDefaults(id, progress: progress)

    case "base":
        let base = try gameport.steamBase()
        switch arg(0, "build|status|delete") {
        case "build":
            print("Building the Steam base: a Windows environment, Steam and Steam's first update. This happens once.")
            try await base.build(progress: progress)
            print("✓ Ready. New profiles are now cloned from this base.")
        case "status":
            if let stamp = base.stamp, base.isReady {
                print("✓ Steam base ready: \(stamp.engineID), \(stamp.builtAt.formatted())")
            } else {
                print("No Steam base. Build it with `\(cli) base build`; until then every profile installs Steam from scratch.")
            }
        case "delete":
            try base.delete()
            print("✓ Deleted. Existing profiles are not affected.")
        default: fail(usage)
        }

    case "snapshot":
        switch arg(0, "profile|list|restore|delete|auto") {
        case "list":
            let id = arg(1, "profile")
            let list = gameport.profiles.listSnapshots(id)
            if list.isEmpty { print("No snapshots for \(id).") }
            for s in list { print("\(s.name)  \(s.createdAt.formatted())  [\(s.engineID)]") }
        case "restore":
            let id = arg(1, "profile"), name = arg(2, "name")
            guard confirm("Profile \(id) goes back to snapshot \(name); everything since then (downloads, saves) is lost. Are you sure?") else { fail("cancelled") }
            try gameport.restore(id, snapshot: name)
            print("✓ Restored.")
        case "auto":
            let id = arg(1, "profile"), value = arg(2, "on|off")
            guard ["on", "off"].contains(value) else { fail(usage) }
            var profile = try gameport.profiles.load(id)
            profile.autoSnapshots = value == "on"
            try gameport.profiles.save(profile)
            print("✓ Automatic snapshots: \(value)")
        case "delete":
            let id = arg(1, "profile"), name = arg(2, "name")
            guard confirm("Snapshot \(name) will be deleted. Are you sure?") else { fail("cancelled") }
            try gameport.profiles.deleteSnapshot(id, name: name)
            print("✓ Deleted.")
        default:
            let id = arg(0, "profile")
            print("Stopping the profile and taking a snapshot…")
            let s = try gameport.snapshot(id, name: args.count > 1 ? args[1] : nil)
            print("✓ Saved \(s.name). To go back: \(cli) snapshot restore \(id) \(s.name)")
        }

    case "anticheat":
        let query = args.joined(separator: " ")
        guard !query.isEmpty else { fail("a game name or Steam id is needed") }
        let hits = AntiCheatDB.bundled.search(query)
        if hits.isEmpty { print("Not in the anti-cheat list (\(AntiCheatDB.bundled.entries.count) games). That does not mean the game works.") }
        for e in hits {
            let mark = e.risk == .blocked ? "✗" : e.risk == .onlineDenied ? "!" : "·"
            print("\(mark) \(e.title)\(e.steamAppID.map { " (Steam \($0))" } ?? ""): \(e.summary)")
        }
        print("Source: highball-db / Are We Anti-Cheat Yet? (MIT)")

    case "profile":
        switch arg(0, "create|list|delete") {
        case "create":
            let recipe = arg(1, "recipe")
            let profile = try gameport.createProfile(recipeID: recipe, profileID: args.count > 2 ? args[2] : nil, progress: progress)
            let next = (try? gameport.steam(for: profile.id).isInstalled) == true ? "\(cli) steam open" : "\(cli) steam install"
            print("✓ Profile ready: \(profile.id). Next: \(next) \(profile.id)")
        case "list":
            for p in gameport.profiles.all() { print("\(p.id)  \(p.title)  [\(p.engineID)]") }
        case "delete":
            let id = arg(1, "profile")
            guard confirm("Profile \(id) and everything in it (installed games, saves) will be deleted. Are you sure?") else { fail("cancelled") }
            try gameport.profiles.delete(id)
            print("✓ Deleted.")
        default: fail(usage)
        }

    case "steam":
        let action = arg(0, "install|open"), id = arg(1, "profile")
        let steam = try gameport.steam(for: id)
        switch action {
        case "install":
            try await steam.install(progress: progress)
            print("✓ Steam installed. Next: \(cli) steam open \(id) (sign in and download the game)")
        case "open":
            let p = try gameport.openSteam(id, progress: progress)
            print("Opening Steam (pid \(p.processIdentifier)). The first start can take a few minutes. Log: \(gameport.profiles.logs(id).appendingPathComponent("steam.log").path)")
        default: fail(usage)
        }

    case "play":
        let id = arg(0, "profile")
        let steam = try gameport.steam(for: id)
        if let appID = steam.runner.recipe?.steamAppID, !steam.isGameInstalled(appID: appID) {
            print("Warning: Steam does not show the game as fully installed yet (appmanifest_\(appID)). Trying anyway.")
        }
        let p = try gameport.play(id, progress: progress)
        print("Game started (pid \(p.processIdentifier)). Log: \(gameport.profiles.logs(id).appendingPathComponent("game.log").path)")

    case "lab":
        let id = arg(0, "profile")
        var renderers: [Renderer?] = [nil]
        var seconds = 180
        var auto = false
        for extra in args.dropFirst() {
            if let n = Int(extra) { seconds = n; continue }
            if extra == "auto" { auto = true; continue }
            renderers = try extra.split(separator: ",").map { name in
                guard let r = Renderer(rawValue: String(name)) else { throw GamePortError.invalid("renderer \(name)") }
                return r
            }
        }
        if auto {
            let candidates = try gameport.labCandidates(id)
            print("Trying: \(candidates.map(\.rawValue).joined(separator: ", ")) (\(seconds) s each)")
            let (best, runs) = try await gameport.findBestRenderer(id, seconds: seconds, progress: progress)
            print("\nResult (\(runs.first?.machine ?? ""), macOS \(runs.first?.macOS ?? "")):")
            for r in runs { print("  \(r.summary)") }
            if let best { print("✓ \(id) now uses \(best.renderer.displayName).") }
            else { print("No renderer was measured working; the profile is unchanged.") }
            exit(0)
        }
        var results: [LabResult] = []
        for renderer in renderers {
            let r = try await gameport.lab(id, renderer: renderer, seconds: seconds, progress: progress)
            print("  → \(r.summary)")
            results.append(r)
        }
        print("\nResult (\(results.first?.machine ?? ""), macOS \(results.first?.macOS ?? "")):")
        for r in results { print("  \(r.summary)") }
        print("Details: \(gameport.profiles.directory(id).appendingPathComponent("lab").path)")

    case "stop":
        try gameport.runner(for: arg(0, "profile")).killAll()
        print("✓ Stopped.")

    case "vulkan":
        let id = arg(0, "profile")
        var profile = try gameport.profiles.load(id)
        guard args.count > 1 else {
            print("\(id): \((profile.vulkanDriver ?? .moltenvk).displayName)")
            exit(0)
        }
        guard let driver = VulkanDriver(rawValue: args[1]) else { fail("unknown Vulkan driver \(args[1]) (moltenvk, kosmickrisp)") }
        if driver == .kosmickrisp, try gameport.runner(for: id).engine.kosmicKrispShim == nil {
            fail("KosmicKrisp is not installed in this profile's engine. Install it with Tools/kosmickrisp-shim/install.sh")
        }
        profile.vulkanDriver = driver == .moltenvk ? nil : driver
        try gameport.profiles.save(profile)
        print("✓ \(id) uses \(driver.displayName) for Vulkan (DXVK's D3D9/10/11, vkd3d's D3D12).")

    case "env":
        let env = try gameport.runner(for: arg(0, "profile")).environment()
        for (k, v) in env.sorted(by: { $0.key < $1.key }) { print("\(k)=\(v)") }

    case "run":
        let id = arg(0, "profile")
        let rest = Array(args.dropFirst())
        guard !rest.isEmpty else { fail("no command to run") }
        exit(try gameport.runner(for: id).runAttached(rest))

    case "help", "-h", "--help":
        print(usage)

    default:
        fail("unknown command \(command)\n\n\(usage)")
    }
} catch {
    fail("\(error)")
}
