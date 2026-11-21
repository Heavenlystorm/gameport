import Foundation

extension EngineStore {
    static func kosmicKrispComponent(for arch: EngineArchitecture) throws -> EngineManifest.Component {
        let pins = try JSONDecoder().decode([String: EngineManifest.Component].self, from: Data(BundledData.kosmicKrisp.utf8))
        guard let pin = pins[arch.rawValue] else { throw GamePortError.missing("KosmicKrisp pin for \(arch.rawValue)") }
        return pin
    }

    /// Install only on request. Old receipts for the bundled CrossOver engine work without reinstalling Wine.
    public func installKosmicKrisp(_ id: String, progress: ProgressHandler? = nil) async throws {
        let installed = try engine(id)
        guard installed.supportsKosmicKrisp else { throw GamePortError.unsupported("\(id) does not declare KosmicKrisp loader support") }
        guard Shell.macOSVersion.majorVersion >= 26 else { throw GamePortError.unsupported("KosmicKrisp needs macOS 26 or later") }
        let arch = installed.manifest.arch
        let pin = try Self.kosmicKrispComponent(for: arch)
        guard let url = URL(string: pin.url), url.scheme == "https" else { throw GamePortError.invalid(pin.url) }
        let file = try await Downloader(cache: paths.downloads).fetch(url, sha256: pin.sha256, size: pin.size, progress: progress)
        try paths.ensure(paths.temp)
        let stage = paths.temp.appendingPathComponent("kosmickrisp-\(UUID().uuidString)")
        let overlay = stage.appendingPathComponent("overlay")
        try paths.ensure(overlay)
        defer { try? FileManager.default.removeItem(at: stage) }
        try place(pin, file: file, engineRoot: overlay)
        let source = stage.appendingPathComponent("shim.c")
        try Data(BundledData.vulkanShimSource.utf8).write(to: source)
        let shim = overlay.appendingPathComponent("libMoltenVK.dylib")
        progress?("Building the \(arch.rawValue) Vulkan shim with Apple's command line tools…")
        try Shell.run("/usr/bin/xcrun", ["clang", "-arch", arch.rawValue, "-mmacosx-version-min=26.0", "-dynamiclib", "-O2",
                                        "-fvisibility=hidden", "-install_name", "@rpath/libgameport_vulkan_shim.dylib", "-o", shim.path, source.path])
        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", shim.path])
        try Shell.run("/usr/bin/lipo", [overlay.appendingPathComponent("libvulkan_kosmickrisp.dylib").path, "-verify_arch", arch.rawValue])
        try FileManager.default.createSymbolicLink(atPath: overlay.appendingPathComponent("libMoltenVK-engine.dylib").path,
                                                   withDestinationPath: "../../frameworks/libMoltenVK.dylib")
        try withInstallLock(id) {
            let current = try engine(id)
            guard current.manifest == installed.manifest else { throw GamePortError.invalid("engine changed during installation, retry") }
            try Shell.run("/usr/bin/lipo", [current.frameworks.appendingPathComponent("libMoltenVK.dylib").path, "-verify_arch", arch.rawValue])
            let renderers = current.root.appendingPathComponent("renderers")
            try paths.ensure(renderers)
            try publish(overlay, at: renderers.appendingPathComponent("kosmickrisp"))
        }
        progress?("Installed KosmicKrisp for \(id)")
    }
}
