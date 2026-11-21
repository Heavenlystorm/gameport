import XCTest
@testable import GamePortKit

final class RecipeFilterTests: XCTestCase {
    func testCombinedFiltersAcrossLargeCatalog() throws {
        var recipes = (0..<600).map { Recipe(id: "game-\($0)", title: "Game \($0)", renderer: .dxmt) }
        recipes += [Recipe(id: "hbdb-quest", title: "Étoile Quest", steamAppID: 90210, renderer: .dxvk, status: .community)]
        let sorted = RecipeCatalog(recipes: recipes).sorted
        var filter = RecipeFilter()
        XCTAssertEqual(filter.apply(to: sorted), sorted)
        filter.renderer = .dxvk
        filter.status = .community
        for query in ["  quEst\tETOILE ", "hbdb", "90210", "quest 90210"] {
            filter.query = query
            XCTAssertEqual(filter.apply(to: sorted).map(\.id), ["hbdb-quest"])
        }
        filter.status = .verified
        XCTAssertTrue(filter.apply(to: sorted).isEmpty)
        filter = RecipeFilter()
        filter.query = "9021"
        XCTAssertTrue(filter.apply(to: sorted).isEmpty)
    }
}

final class LabMeasurementTests: XCTestCase {
    private func hud(_ stamp: String, _ pid: Int, _ payload: String) -> String {
        "2026-10-30 16:02:\(stamp) Df wine[\(pid):abc] [com.apple.metal.hud:Logging] metal-HUD: \(payload)"
    }

    func testPercentileUsesOnlyMeasuredGameFrameIntervals() throws {
        // 98 fast frames and two 50 ms frames → nearest-rank p99 = 50 ms (20 FPS).
        let pairs = (Array(repeating: "10,2", count: 98) + ["50,2", "50,2"]).joined(separator: ",")
        let game = hud("01.000", 10, "101,0,10,\(pairs)")
        let samples = MetalHUDLog.parse([hud("00.000", 10, "1,0,10<private>"), game, game,
                                         hud("01.000", 20, "5000,0,10,200,2")].joined(separator: "\n"))
        let selected = LabResult.gameSamples(samples, gamePIDs: [10])
        XCTAssertEqual(selected.flatMap(\.presentIntervalsMS).count, 100)
        let stats = try XCTUnwrap(LabStats.from(selected))
        XCTAssertEqual(stats.onePercentLowFPS, 20)
        XCTAssertEqual(stats.averageFPS, 100)
    }

    func testRedactionMalformedPairsSmallSamplesAndWarmup() throws {
        let pairs = Array(repeating: "40,2", count: 100).joined(separator: ",")
        let samples = MetalHUDLog.parse([
            hud("01.000", 10, "1,0,10,\(pairs)"), hud("02.000", 10, "101,0,10<private>"),
            hud("03.000", 10, "201,0,10,-1,3,nan,1,inf,2,20,,16,2,20"),
            hud("04.000", 10, "nan,0,10,20,2")
        ].joined(separator: "\n"))
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples.last?.presentIntervalsMS, [16])
        XCTAssertEqual(LabStats.from(samples)?.onePercentLowFPS, 25)
        let steady = try XCTUnwrap(LabStats.from(samples, after: samples[1].time))
        XCTAssertNil(steady.onePercentLowFPS)
        XCTAssertEqual(steady.averageFPS, 100)
    }

    func testThermalRoundTripAndOlderResults() throws {
        XCTAssertNil(LabThermalState.peak([]))
        XCTAssertEqual(LabThermalState.peak([.nominal, .serious, .fair]), .serious)
        XCTAssertNil(LabThermalState(rawValue: 99))
        let legacy = #"{"profileID":"g","renderer":"dxmt","sync":"msync","engineID":"e","macOS":"15","machine":"Mac","startedAt":0,"seconds":2,"verdict":"works","hudLog":"hud","whole":{"frames":120,"seconds":2,"averageFPS":60,"typicalFPS":60,"slowestFPS":60,"stalls":0,"stallSeconds":0}}"#
        var run = try JSONDecoder().decode(LabResult.self, from: Data(legacy.utf8))
        XCTAssertNil(run.whole?.onePercentLowFPS)
        XCTAssertNil(run.peakThermalState)
        run.peakThermalState = .serious
        let decoded = try JSONDecoder().decode(LabResult.self, from: JSONEncoder().encode(run))
        XCTAssertTrue(decoded.summary.contains("peak thermal state serious"))
        XCTAssertTrue(decoded.summary.contains("1% low unavailable"))
    }

    func testTriageOrderingAndRecoveredSteamGPU() {
        let game = "err: VK_ERROR_DEVICE_LOST\nwine: Unhandled exception\nerr: Failed to create Vulkan instance"
        let cef = "GPU process exited unexpectedly\nGPU process exited unexpectedly"
        let expected = ["unhandled exception", "Vulkan initialization failed", "Vulkan device lost",
                        "Steam's GPU process crashed 2 times", "the game exited before the end"]
        for input in [game, game.split(separator: "\n").reversed().joined(separator: "\n")] {
            XCTAssertEqual(LabTriage.findings(game: input, cef: cef, bootstrap: "", gameExited: true), expected)
        }
        XCTAssertEqual(LabTriage.findings(game: "", cef: "GPU process exited unexpectedly", bootstrap: nil, gameExited: false), [])
    }

    func testGamePIDTieIsDeterministic() {
        let points = [20, 10].flatMap { pid in
            [1, 101].map { MetalHUDLog.Sample(time: Double($0), pid: pid, frame: Double($0)) }
        }
        XCTAssertEqual(MetalHUDLog.busiestProcess(points), 10)
        XCTAssertEqual(MetalHUDLog.busiestProcess(points.reversed()), 10)
    }

    func testCounterResetAndGameExitInLastMeasurementWindow() throws {
        let frames = [200, 220, 5, 25]
        let samples = frames.enumerated().map { MetalHUDLog.Sample(time: Double($0.offset), pid: 1, frame: Double($0.element)) }
        let stats = try XCTUnwrap(LabStats.from(samples))
        XCTAssertEqual(stats.frames, 40)
        XCTAssertEqual(stats.seconds, 2)
        XCTAssertEqual(stats.averageFPS, 20)
        XCTAssertEqual(LabResult.verdict(Array(samples.suffix(2)), end: 4, gameStarted: true, gameExited: true), .stopped)
        XCTAssertEqual(LabResult.verdict(Array(samples.suffix(2)), end: 4, gameStarted: false), .noFrames)
    }
}

final class ConfigPatcherTests: XCTestCase {
    let entry = ConfigPatcher.INI(file: "Game/Engine.ini", section: "SystemSettings", key: "Windowed", value: "1")
    var prefix: URL!
    var game: URL!
    var ini: URL { game.appendingPathComponent("Engine.ini") }

    override func setUpWithError() throws {
        prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        game = prefix.appendingPathComponent("drive_c/users/player/AppData/Local/Game")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: prefix) }

    func testAddsMissingKeyWithExactBackupAndNoSecondWrite() throws {
        let original = "\u{FEFF}; note\r\n[sYsTeMsEtTiNgS]\r\n;Windowed=0\r\nOther=2\r\n[Next]\r\nWindowed=0"
        try Data(original.utf8).write(to: ini)
        _ = try ConfigPatcher.apply(entry, in: prefix, user: "player")
        XCTAssertEqual(try Data(contentsOf: ini), Data(original.replacingOccurrences(of: "\r\n;Windowed", with: "\r\nWindowed=1\r\n;Windowed").utf8))
        _ = try ConfigPatcher.apply(entry, in: prefix, user: "player")
        let backups = try FileManager.default.contentsOfDirectory(at: game, includingPropertiesForKeys: nil).filter { $0.pathExtension == "bak" }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), Data(original.utf8))
    }

    func testRespectsCustomSettingsAcrossRepeatedSections() throws {
        let text = "[SystemSettings]\nX=1\n[Other]\nx=4\n[SYSTEMSETTINGS] ; override\n wINdowed = 0 ; player choice\n"
        XCTAssertEqual(try ConfigPatcher.adding(entry, to: text), text)
        XCTAssertEqual(try ConfigPatcher.adding(entry, to: "x=1"), "x=1\n[SystemSettings]\nWindowed=1\n")
    }

    func testCreatesMissingINIAndRejectsBinaryTraversalAndLinks() throws {
        try ConfigPatcher.apply(entry, in: prefix, user: "player")
        XCTAssertEqual(try String(contentsOf: ini, encoding: .utf8), "[SystemSettings]\nWindowed=1\n")
        try Data([0xff, 0xfe, 0, 4]).write(to: ini)
        XCTAssertThrowsError(try ConfigPatcher.apply(entry, in: prefix, user: "player"))
        XCTAssertEqual(try Data(contentsOf: ini), Data([0xff, 0xfe, 0, 4]))
        for path in ["../Game/Engine.ini", "/Game/Engine.ini", "Game/save.sav", "Game/../../escape.ini", "Game\\foo/Engine.ini"] {
            var bad = entry
            bad.file = path
            XCTAssertThrowsError(try ConfigPatcher.apply(bad, in: prefix, user: "player"))
        }
        XCTAssertThrowsError(try ConfigPatcher.apply(entry, in: prefix, user: "../player"))
        let fm = FileManager.default
        let moved = prefix.appendingPathComponent("saved")
        try fm.moveItem(at: game, to: moved)
        try fm.createSymbolicLink(at: game, withDestinationURL: moved)
        XCTAssertThrowsError(try ConfigPatcher.apply(entry, in: prefix, user: "player"))
        try fm.removeItem(at: game)
        try fm.createDirectory(at: game, withIntermediateDirectories: false)
        let target = moved.appendingPathComponent("nonexistent")
        try fm.createSymbolicLink(at: ini, withDestinationURL: target)
        XCTAssertThrowsError(try ConfigPatcher.apply(entry, in: prefix, user: "player"))
        XCTAssertFalse(fm.fileExists(atPath: target.path))
    }

    func testRegistryDefaultsAreScopedAndNeverOverwrite() throws {
        let key = #"HKCU\Software\Wine\AppDefaults\demo.exe\Mac Driver"#
        var r = Recipe.RegistryValue(key: key, name: "CaptureDisplaysForFullscreen", type: "REG_SZ", data: "n")
        XCTAssertEqual(try ConfigPatcher.registryLine(r), #"HKCU,"Software\Wine\AppDefaults\demo.exe\Mac Driver","CaptureDisplaysForFullscreen",0x00000002,"n""#)
        r.type = "REG_DWORD"
        r.data = "0xff"
        XCTAssertTrue(try ConfigPatcher.registryLine(r).hasSuffix(",0x00010003,255"))
        r.data = "4294967296"
        XCTAssertThrowsError(try ConfigPatcher.registryLine(r))
        r.type = "REG_SZ"
        r.data = "value\r\n[another section]"
        XCTAssertThrowsError(try ConfigPatcher.registryLine(r))
        r.data = "n"
        r.key = #"HKCU\Software\Wine\Mac Driver"#
        XCTAssertThrowsError(try ConfigPatcher.registryLine(r))
        XCTAssertNotNil(RecipeCatalog(recipes: RecipeCatalog.bundled())["hogwarts-legacy"]?.configDefaults?.ini?.first)
    }
}
