#if os(macOS)
import SwiftUI
import AppKit
import GamePortKit

@main
struct GamePortApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Launched from Xcode or `swift run` an SPM executable starts as a background process;
        // make it a regular app with a Dock icon and a key window.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup(Brand.displayName) {
            ContentView().environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let gameport = GamePort()
    @Published var checks: [GamePort.Check] = []
    @Published var engines: [String] = []
    @Published var recipes: [Recipe] = []
    private var profilesByRecipe: [String: Profile] = [:]
    private var labResultsByProfile: [String: [LabResult]] = [:]
    @Published var busy: String?
    @Published var log: [String] = []
    @Published var gptkAccepted = false
    @Published var steamBase: SteamBase.Stamp?

    init() { refresh() }

    func refresh() {
        checks = gameport.doctor()
        engines = gameport.engines.installed().map(\.id)
        recipes = gameport.catalog.sorted
        let profiles = gameport.profiles.all()
        profilesByRecipe = Dictionary(profiles.compactMap { p in p.recipeID.map { ($0, p) } }, uniquingKeysWith: { first, _ in first })
        labResultsByProfile = profilesByRecipe.values.reduce(into: [:]) { $0[$1.id] = gameport.profiles.labResults($1.id) }
        gptkAccepted = gameport.licenses.isAccepted("apple-gptk")
        steamBase = (try? gameport.steamBase()).flatMap { $0.isReady ? $0.stamp : nil }
    }

    func say(_ line: String) { log.append(line); if log.count > 400 { log.removeFirst(log.count - 400) } }

    /// Runs blocking work off the main thread, one job at a time, with its messages in the log.
    func job(_ title: String, _ work: @escaping @Sendable (GamePort, @escaping ProgressHandler) async throws -> String?) {
        guard busy == nil else { return }
        busy = title
        say("▶ \(title)")
        let gameport = self.gameport
        Task.detached {
            let progress: ProgressHandler = { msg in Task { @MainActor in self.say("  \(msg)") } }
            do {
                let done = try await work(gameport, progress)
                await MainActor.run { self.say("✓ \(done ?? title)") }
            } catch {
                await MainActor.run { self.say("✗ \(error)") }
            }
            await MainActor.run { self.busy = nil; self.refresh() }
        }
    }

    func profile(for recipe: Recipe) -> Profile? { profilesByRecipe[recipe.id] }

    func evidence(for recipe: Recipe) -> Evidence {
        Evidence.of(recipe, results: profile(for: recipe).flatMap { labResultsByProfile[$0.id] } ?? [],
                    antiCheat: AntiCheatDB.bundled.entry(for: recipe))
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String? = "setup"
    @State private var filter = RecipeFilter()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section(Brand.displayName) {
                    Label("Setup", systemImage: "wrench.and.screwdriver").tag("setup")
                }
                Section("Games") {
                    Menu("Filter recipes", systemImage: "line.3.horizontal.decrease.circle") {
                        Picker("Status", selection: $filter.status) {
                            Text("All statuses").tag(nil as Recipe.Status?)
                            ForEach(Recipe.Status.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                        }
                        Picker("Renderer", selection: $filter.renderer) {
                            Text("All renderers").tag(nil as Renderer?)
                            ForEach(Renderer.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                        }
                    }
                    let matches = filter.apply(to: model.recipes)
                    if matches.isEmpty { Text("No matching recipes").foregroundStyle(.secondary) }
                    ForEach(matches) { r in
                        HStack {
                            EvidenceIcon(level: model.evidence(for: r).level)
                            Text(r.title)
                            Spacer()
                            if model.profile(for: r) != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }.tag(r.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .searchable(text: $filter.query, placement: .sidebar, prompt: "Game, recipe ID or Steam ID")
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if selection == "setup" || selection == nil {
                        SetupView()
                    } else if let id = selection, let r = model.recipes.first(where: { $0.id == id }) {
                        GameView(recipe: r)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                LogView()
            }
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLicense = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Setup").font(.largeTitle.bold())
                GroupBox("System") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.checks, id: \.name) { c in
                            Label("\(c.name): \(c.detail)", systemImage: c.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(c.ok ? Color.primary : Color.red)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("Engine") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let m = model.gameport.defaultManifest {
                            Text(m.displayName).font(.headline)
                            Text("Wine, runtime libraries and renderers. Every part is verified with SHA-256. About 440 MB.")
                                .foregroundStyle(.secondary)
                            HStack {
                                Button(model.engines.contains(m.id) ? "Reinstall" : "Install engine") {
                                    model.job("Engine install") { k, p in try await k.installDefaultEngine(progress: p).id }
                                }.disabled(model.busy != nil)
                                if model.engines.contains(m.id) { Label("Installed", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("Steam base") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Installs and updates Windows Steam once. Every later game starts as a copy of this base, ready in seconds and using almost no disk; games still stay separate from each other. Nobody signs in to the base.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(model.steamBase == nil ? "Build Steam base" : "Rebuild") {
                                model.job("Steam base") { k, p in try await k.steamBase().build(progress: p); return "Steam base ready" }
                            }.disabled(model.engines.isEmpty || model.busy != nil)
                            if let stamp = model.steamBase {
                                Label("Ready · \(stamp.builtAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("D3DMetal (Apple Game Porting Toolkit)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Most DirectX 12 games need D3DMetal. D3DMetal belongs to Apple and comes with its own licence, which you need to accept before it is used.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Read licence") { showLicense = true }
                            if model.gptkAccepted {
                                Label("Accepted", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                                Button("Revoke") { try? model.gameport.licenses.revoke("apple-gptk"); model.refresh() }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }.padding(24)
        }
        .sheet(isPresented: $showLicense) { LicenseSheet() }
    }
}

struct LicenseSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        let license = model.gameport.defaultManifest?.licenses["apple-gptk"]
        VStack(alignment: .leading, spacing: 14) {
            Text(license?.title ?? String(localized: "Licence")).font(.title2.bold())
            Text(license?.summary ?? "")
            if let url = license?.url.flatMap(URL.init(string:)) { Link("Apple's page", destination: url) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("I accept") {
                    try? model.gameport.licenses.accept("apple-gptk")
                    model.refresh()
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
    }
}

struct GameView: View {
    @EnvironmentObject var model: AppModel
    let recipe: Recipe

    var body: some View {
        let profile = model.profile(for: recipe)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(recipe.title).font(.largeTitle.bold())
                HStack(spacing: 12) {
                    Tag(text: recipe.renderer.displayName)
                    Tag(text: "Sync: \(recipe.sync.rawValue)")
                    if let id = recipe.steamAppID { Tag(text: "Steam \(id)") }
                }
                let evidence = model.evidence(for: recipe)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    EvidenceIcon(level: evidence.level)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(evidence.title).bold()
                        if let detail = evidence.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if recipe.renderer == .d3dmetal && !model.gptkAccepted {
                    Label("This game uses D3DMetal. It cannot be played until you accept Apple's licence on the Setup page.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                GroupBox("Steps") {
                    VStack(alignment: .leading, spacing: 10) {
                        Step(n: 1, title: "Create the Windows environment", done: profile != nil) {
                            model.job("\(recipe.title): creating the environment") { k, p in
                                try k.createProfile(recipeID: recipe.id, progress: p).id
                            }
                        }.disabled(model.engines.isEmpty || model.busy != nil)
                        if let profile {
                            let installed = (try? model.gameport.steam(for: profile.id).isInstalled) ?? false
                            Step(n: 2, title: "Install Windows Steam", done: installed) {
                                model.job("Steam install") { k, p in try await k.steam(for: profile.id).install(progress: p); return "Steam installed" }
                            }.disabled(model.busy != nil)
                            Step(n: 3, title: "Open Steam, sign in and download the game", done: false) {
                                model.job("Opening Steam") { k, p in _ = try k.openSteam(profile.id, progress: p); return "Steam started (the first start can take a few minutes)" }
                            }.disabled(!installed || model.busy != nil)
                            if recipe.steamAppID != nil {
                                Step(n: 4, title: "Play", done: false) {
                                    model.job("Starting \(recipe.title)") { k, p in _ = try k.play(profile.id, progress: p); return "Game started" }
                                }.disabled(!installed || model.busy != nil)
                            }
                            HStack {
                                Button("Stop everything") { model.job("Stopping") { k, _ in try k.runner(for: profile.id).killAll(); return "Stopped" } }
                                Button("Show logs") { NSWorkspace.shared.open(model.gameport.profiles.logs(profile.id)) }
                            }.padding(.top, 4)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                if let profile, recipe.configDefaults != nil {
                    Button("Apply missing recipe settings") {
                        model.job("Recipe settings") { k, progress in
                            try k.applyConfigDefaults(profile.id, progress: progress)
                            return "Recipe settings checked"
                        }
                    }
                    .disabled(model.busy != nil)
                    .help("Close the game and Steam first. Existing settings are kept.")
                }
                if let profile, recipe.steamAppID != nil { LabView(profile: profile) }
                if let profile { SnapshotsView(profile: profile) }
                if !recipe.notes.isEmpty {
                    GroupBox("Notes") {
                        VStack(alignment: .leading, spacing: 6) { ForEach(recipe.notes, id: \.self) { Text("• " + $0) } }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                }
                if !recipe.knownIssues.isEmpty {
                    GroupBox("Known issues") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(recipe.knownIssues, id: \.symptom) { i in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(i.symptom).bold()
                                    if let c = i.cause { Text("Cause: \(c)").foregroundStyle(.secondary) }
                                    if let f = i.fix { Text("Fix: \(f)").foregroundStyle(.secondary) }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                }
                if let s = recipe.source { Text("Source: \(s)").font(.footnote).foregroundStyle(.secondary) }
            }.padding(24)
        }
    }
}

/// Runs `gameport lab` for the game and shows what earlier runs measured, with the Mac and engine.
struct LabView: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile

    var body: some View {
        let results = model.gameport.profiles.labResults(profile.id)
        GroupBox("Lab") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Runs the game for 3 minutes, measures FPS from the Metal HUD and records whether it works. Keep the game window in front while it measures.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Test") {
                        model.job("\(profile.title): lab") { k, p in try await k.lab(profile.id, progress: p).summary }
                    }.disabled(model.busy != nil)
                    Button("Find the best renderer") {
                        model.job("\(profile.title): renderer comparison") { k, p in
                            let (best, _) = try await k.findBestRenderer(profile.id, progress: p)
                            return best.map { "Best: \($0.renderer.displayName); the profile now uses it" } ?? "None was measured working; the profile is unchanged"
                        }
                    }.disabled(model.busy != nil)
                    .help("Tries each renderer for 3 minutes (6-9 minutes in all) and picks the fastest one that works.")
                }
                // Only offered once KosmicKrisp is installed in this profile's engine (Tools/kosmickrisp-shim/install.sh).
                if model.gameport.engines.installed().first(where: { $0.id == profile.engineID })?.kosmicKrispShim != nil {
                    Picker("Vulkan driver", selection: Binding(
                        get: { profile.vulkanDriver ?? .moltenvk },
                        set: { driver in
                            var p = profile
                            p.vulkanDriver = driver == .moltenvk ? nil : driver
                            try? model.gameport.profiles.save(p)
                            model.refresh()
                        })) {
                        ForEach(VulkanDriver.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .fixedSize()
                    .help("Used by DXVK (Direct3D 9/10/11) and vkd3d (Direct3D 12). KosmicKrisp is Mesa's open Vulkan driver on Metal; only the game uses it.")
                }
                ForEach(results.prefix(5), id: \.startedAt) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(r.summary, systemImage: r.verdict == .works ? "checkmark.circle.fill" : r.verdict == .notVisible ? "eye.slash" : "exclamationmark.triangle.fill")
                            .foregroundStyle(r.verdict == .works ? Color.green : r.verdict == .notVisible ? Color.secondary : Color.orange)
                        Text("\(r.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(r.machine) · macOS \(r.macOS) · \(r.engineID)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }
}

/// Saved states of a profile to roll back to after an update breaks the game.
struct SnapshotsView: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile
    @State private var confirmRestore: Snapshot?

    var body: some View {
        let snapshots = model.gameport.profiles.listSnapshots(profile.id)
        GroupBox("Snapshots") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Saves the game's state before Steam and game updates, so you can go back if something breaks. One is taken automatically the first time Steam starts each day.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Save now") {
                        model.job("Snapshot") { k, _ in "Saved \(try k.snapshot(profile.id).name)" }
                    }.disabled(model.busy != nil)
                    Toggle("Daily automatic", isOn: Binding(
                        get: { profile.autoSnapshots ?? true },
                        set: { on in
                            var p = profile
                            p.autoSnapshots = on
                            try? model.gameport.profiles.save(p)
                            model.refresh()
                        }))
                }
                ForEach(snapshots, id: \.name) { s in
                    HStack {
                        Image(systemName: s.name.hasPrefix(ProfileStore.autoPrefix) ? "clock.arrow.circlepath" : "bookmark")
                        Text(s.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Text(s.name).foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Button("Restore") { confirmRestore = s }.disabled(model.busy != nil)
                        Button(role: .destructive) {
                            model.job("Deleting snapshot") { k, _ in try k.profiles.deleteSnapshot(profile.id, name: s.name); return "Deleted \(s.name)" }
                        } label: { Image(systemName: "trash") }.disabled(model.busy != nil)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
        .confirmationDialog("Restore this snapshot?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
                            presenting: confirmRestore) { s in
            Button("Restore", role: .destructive) {
                model.job("Restoring") { k, _ in try k.restore(profile.id, snapshot: s.name); return "Restored \(s.name)" }
            }
        } message: { s in
            Text("Everything since \(s.createdAt.formatted()) (downloads, saves, settings) will be lost.")
        }
    }
}

struct EvidenceIcon: View {
    let level: Evidence.Level
    var body: some View {
        switch level {
        case .labWorks: Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .verified: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .community: Image(systemName: "person.2.fill").foregroundStyle(.blue)
        case .untested: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        case .labFailed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .antiCheatRisk: Image(systemName: "shield.slash.fill").foregroundStyle(.orange)
        case .blocked: Image(systemName: "nosign").foregroundStyle(.red)
        }
    }
}

struct Step: View {
    let n: Int
    let title: LocalizedStringKey
    let done: Bool
    let action: () -> Void
    var body: some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle").foregroundStyle(done ? Color.green : Color.secondary).font(.title3)
            Text(title)
            Spacer()
            Button(done ? "Again" : "Start", action: action)
        }
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

struct LogView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log").font(.headline)
                if let busy = model.busy { ProgressView().controlSize(.small); Text(busy).foregroundStyle(.secondary) }
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.log.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }.padding(10).frame(height: 170)
    }
}
#else
@main
enum GamePortAppStub {
    static func main() { print("\(Brand.displayName) runs on macOS only. For the command line: \(Brand.cliName)") }
}
#endif
