import XCTest
@testable import GamePortKit

final class EngineArchitectureTests: XCTestCase {
    var root: URL!
    var kit: GamePort!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        kit = GamePort(paths: Paths(root: root))
        try kit.paths.ensure(root)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func engine(_ arch: EngineArchitecture) throws -> InstalledEngine {
        var m = try XCTUnwrap(EngineStore.bundledManifests().first)
        m.id = arch.rawValue
        m.arch = arch
        if arch == .fex { m.fexModules = .init(x64: "modules/xtajit64.dll", x86: "modules/xtajit.dll") }
        let e = InstalledEngine(manifest: m, root: kit.paths.engine(m.id))
        for file in [e.wine, e.wineServer] {
            try kit.paths.ensure(file.deletingLastPathComponent())
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        if let modules = m.fexModules {
            for name in [modules.x64, modules.x86] {
                let file = e.root.appendingPathComponent(name)
                try kit.paths.ensure(file.deletingLastPathComponent())
                try Data("fixture".utf8).write(to: file)
            }
        }
        try JSONEncoder().encode(m).write(to: e.root.appendingPathComponent(EngineStore.receiptName))
        return try kit.engines.engine(m.id)
    }

    private func profile(_ id: String, engine: InstalledEngine, recipe: String = "3dmark-demo") throws -> Profile {
        var p = Profile(id: id, title: id, recipeID: recipe, engineID: engine.id)
        p.renderer = .wined3d
        try kit.profiles.save(p)
        let steam = try kit.steam(for: id)
        try kit.paths.ensure(steam.exe.deletingLastPathComponent(), steam.steamapps)
        try Data().write(to: steam.exe)
        try Data(#""StateFlags" "4""#.utf8).write(to: steam.steamapps.appendingPathComponent("appmanifest_231350.acf"))
        return p
    }

    func testLegacyReceiptAndLabHistory() throws {
        let e = try engine(.rosetta)
        var m = e.manifest
        m.id = try XCTUnwrap(EngineStore.bundledManifests().first?.id)
        m.supportsKosmicKrisp = nil
        let decoded = try JSONDecoder().decode(EngineManifest.self, from: JSONEncoder().encode(m))
        XCTAssertNil(decoded.fexModules)
        XCTAssertTrue(decoded.requiresRosetta)
        XCTAssertTrue(InstalledEngine(manifest: decoded, root: e.root).supportsKosmicKrisp)
        let old = #"{"profileID":"g","renderer":"dxmt","sync":"msync","engineID":"old","macOS":"15","machine":"M1","startedAt":0,"seconds":60,"verdict":"works","hudLog":"hud"}"#
        var result = try JSONDecoder().decode(LabResult.self, from: Data(old.utf8))
        XCTAssertNil(result.engineArchitecture)
        result.engineArchitecture = .fex
        XCTAssertEqual(try JSONDecoder().decode(LabResult.self, from: JSONEncoder().encode(result)).engineArchitecture, .fex)
    }

    func testFEXModuleAndHostValidation() throws {
        let e = try engine(.fex)
        XCTAssertNoThrow(try e.checkFiles())
        XCTAssertNoThrow(try e.checkHost(version: "26.5.1", appleSilicon: true, rosetta: { XCTFail("FEX needs no Rosetta probe"); return false }))
        XCTAssertThrowsError(try e.checkHost(version: "13.6", appleSilicon: true))
        XCTAssertThrowsError(try e.checkHost(version: "26.5", appleSilicon: false))
        let x64 = try engine(.rosetta)
        XCTAssertThrowsError(try x64.checkHost(version: "26.5", appleSilicon: true, rosetta: { false }))
        try fm.removeItem(at: e.root.appendingPathComponent("modules/xtajit64.dll"))
        XCTAssertThrowsError(try e.checkFiles())
        var m = e.manifest
        m.fexModules?.x64 = "../xtajit64.dll"
        XCTAssertThrowsError(try m.validate())
        m.fexModules = nil
        XCTAssertThrowsError(try m.validate())
    }

    func testNativeEnvironmentRejectsD3DMetalAndStripsRosettaFlag() throws {
        let e = try engine(.fex)
        var p = try profile("native", engine: e)
        p.advertiseAVX = true
        p.environment["ROSETTA_ADVERTISE_AVX"] = "1"
        let runner = WineRunner(paths: kit.paths, engine: e, profile: p, recipe: nil)
        XCTAssertNil(try runner.environment()["ROSETTA_ADVERTISE_AVX"])
        XCTAssertThrowsError(try Renderer.d3dmetal.environment(engine: e))
    }

    func testFallbackUsesPreparedAlternateWithoutChangingPrimary() throws {
        let x64 = try engine(.rosetta), native = try engine(.fex)
        let first = try profile("first", engine: x64), second = try profile("second", engine: native)
        try kit.setFallback(first.id, to: second.id)
        let primary = try kit.playbackRunner(first.id, checkHost: { _ in })
        XCTAssertEqual(primary.profile.id, first.id)
        let alternate = try kit.playbackRunner(first.id, checkHost: {
            try $0.checkHost(version: "26.5", appleSilicon: true, rosetta: { false })
        })
        XCTAssertEqual(alternate.profile.id, second.id)
        XCTAssertNotEqual(primary.prefix, alternate.prefix)
        XCTAssertNotEqual(primary.home, alternate.home)
        XCTAssertEqual(try kit.profiles.load(first.id).engineID, x64.id)
        try fm.removeItem(at: try kit.steam(for: second.id).steamapps.appendingPathComponent("appmanifest_231350.acf"))
        try kit.engines.remove(x64.id)
        XCTAssertThrowsError(try kit.playbackRunner(first.id, checkHost: { _ in }))
        try kit.setFallback(first.id, to: nil)
        XCTAssertNil(try kit.profiles.load(first.id).fallbackProfileID)
    }

    func testInvalidPairAndLicenceErrorsDoNotSwitchEngines() throws {
        let x64 = try engine(.rosetta), native = try engine(.fex)
        var first = try profile("first", engine: x64)
        _ = try profile("other", engine: native, recipe: "elden-ring")
        XCTAssertThrowsError(try kit.setFallback(first.id, to: "other"))
        XCTAssertThrowsError(try kit.setFallback(first.id, to: first.id))
        XCTAssertThrowsError(try kit.setFallback(first.id, to: "../elsewhere"))
        _ = try profile("second", engine: native)
        first.renderer = .d3dmetal
        first.fallbackProfileID = "second"
        try kit.profiles.save(first)
        XCTAssertThrowsError(try kit.playbackRunner(first.id, checkHost: { _ in })) {
            XCTAssertEqual($0 as? GamePortError, .licenseNotAccepted("apple-gptk"))
        }
    }

    func testComparisonControlsAndIsolatesBothTrials() throws {
        let x64 = try engine(.rosetta), native = try engine(.fex)
        var first = try profile("first", engine: x64), second = try profile("second", engine: native)
        first.sync = .esync
        second.sync = .msync
        second.renderer = .dxvk
        try kit.profiles.save(first)
        try kit.profiles.save(second)
        let pair = try kit.comparisonRunners(first.id, with: second.id, checkHost: { _ in })
        XCTAssertEqual(pair.map(\.engine.manifest.arch), [.rosetta, .fex])
        XCTAssertEqual(pair.map(\.effectiveRenderer), [.wined3d, .wined3d])
        XCTAssertEqual(pair.map(\.effectiveSync), [.esync, .esync])
        XCTAssertEqual(try kit.profiles.load(second.id).renderer, .dxvk)
        XCTAssertEqual(try kit.profiles.load(second.id).sync, .msync)
        XCTAssertNotEqual(pair[0].prefix, pair[1].prefix)
        try fm.removeItem(at: try kit.steam(for: second.id).exe)
        XCTAssertThrowsError(try kit.comparisonRunners(first.id, with: second.id, checkHost: { _ in }))
    }

    func testOptionalDriverPinsAreArchitectureSpecificAndExcludedFromBaseInstall() throws {
        let a = try EngineStore.kosmicKrispComponent(for: .fex), x = try EngineStore.kosmicKrispComponent(for: .rosetta)
        XCTAssertEqual(a.sha256, "c597a17c708b7ba4a617d90a55f0c84101898dff1db7b10ae976da07d2c1b31a")
        XCTAssertEqual(x.sha256, "5c55c95bfeae56e2ed8dc9ebbf85c702813ae67638f0b544310fd186bb0fc93b")
        for pin in [a, x] {
            XCTAssertEqual(URL(string: pin.url)?.scheme, "https")
            XCTAssertEqual(pin.extract?.subpath, "libvulkan_kosmickrisp.dylib")
            XCTAssertFalse(EngineStore.bundledManifests().flatMap(\.components).contains { $0.url == pin.url })
        }
    }

    func testIncompleteReinstallPreservesWorkingEngineAndOptionalDriver() async throws {
        let e = try engine(.fex)
        let driver = e.root.appendingPathComponent("renderers/kosmickrisp/libMoltenVK.dylib")
        try kit.paths.ensure(driver.deletingLastPathComponent())
        try Data("installed shim".utf8).write(to: driver)
        var empty = e.manifest
        empty.components = []
        do {
            _ = try await kit.engines.install(empty)
            XCTFail("empty staging must fail")
        } catch GamePortError.missing { }
        XCTAssertNoThrow(try kit.engines.engine(e.id).checkFiles())
        XCTAssertEqual(try String(contentsOf: driver, encoding: .utf8), "installed shim")
    }

    func testCachedFEXManifestInstallsAndKeepsOptionalDriverOnReinstall() async throws {
        var m = try XCTUnwrap(EngineStore.bundledManifests().first)
        m.id = "local-native"
        m.arch = .fex
        m.fexModules = .init(x64: "fex/xtajit64.dll", x86: "fex/xtajit.dll")
        m.components = []
        let payload = Data("#!/bin/sh\nexit 0\n".utf8)
        let sha = Checksum.sha256(data: payload)
        try kit.paths.ensure(kit.paths.downloads)
        try payload.write(to: Downloader(cache: kit.paths.downloads).cachedFile(sha256: sha, name: "fixture"))
        for path in [m.wineLoader, m.wineServer, "fex/xtajit64.dll", "fex/xtajit.dll", "frameworks/libMoltenVK.dylib"] {
            m.components.append(.init(name: URL(fileURLWithPath: path).lastPathComponent, kind: "runtime",
                                      url: "https://example.invalid/fixture", sha256: sha, license: "fixture",
                                      place: path, executable: path == m.wineLoader || path == m.wineServer))
        }
        let e = try await kit.engines.install(m)
        XCTAssertNoThrow(try e.checkFiles())
        let folder = e.root.appendingPathComponent("renderers/kosmickrisp")
        try kit.paths.ensure(folder)
        for file in ["libvulkan_kosmickrisp.dylib", "libMoltenVK.dylib"] {
            try Data(file.utf8).write(to: folder.appendingPathComponent(file))
        }
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("libMoltenVK-engine.dylib").path,
                                   withDestinationPath: "../../frameworks/libMoltenVK.dylib")
        let replacement = try await kit.engines.install(m)
        let shim = try XCTUnwrap(replacement.kosmicKrispShim)
        XCTAssertEqual(try Data(contentsOf: shim), Data("libMoltenVK.dylib".utf8))
        XCTAssertEqual(try kit.engines.engine(m.id).manifest, m)
    }
}
