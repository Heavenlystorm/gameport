import Foundation

/// Which driver turns Vulkan (DXVK, vkd3d) into Metal for a game.
public enum VulkanDriver: String, Codable, Sendable, CaseIterable {
    /// MoltenVK, bundled with the engine.
    case moltenvk
    /// KosmicKrisp: Mesa's Vulkan 1.4 driver on Metal (macOS 26+), reached through GamePort's shim
    /// (Tools/kosmickrisp-shim). Experimental: only the game uses it; Steam and Wine stay on MoltenVK.
    case kosmickrisp

    public var displayName: String {
        switch self {
        case .moltenvk: return "MoltenVK"
        case .kosmickrisp: return "KosmicKrisp (experimental)"
        }
    }
}

/// How a game's Direct3D reaches Metal.
public enum Renderer: String, Codable, Sendable, CaseIterable {
    /// Wine's own D3D-on-OpenGL. Old games and launcher UIs.
    case wined3d
    /// DXMT: Direct3D 10/11 straight to Metal (LGPL-2.1+ since v0.80; MIT before).
    case dxmt
    /// Apple's D3DMetal (Game Porting Toolkit): Direct3D 11/12 to Metal. Apple licence, 64-bit only.
    case d3dmetal
    /// DXVK: Direct3D 9/10/11 to Vulkan, then MoltenVK to Metal.
    case dxvk

    public var displayName: String {
        switch self {
        case .wined3d: return "WineD3D (OpenGL)"
        case .dxmt: return "DXMT (D3D10/11 → Metal)"
        case .d3dmetal: return "D3DMetal (D3D11/12 → Metal, Apple GPTK)"
        case .dxvk: return "DXVK (D3D9/10/11 → Vulkan → Metal)"
        }
    }

    /// The licence id (from the engine manifest) that must be accepted before this renderer is used.
    public func gatingLicense(in manifest: EngineManifest) -> String? {
        manifest.licenses.first { $0.value.gatesRenderers.contains(rawValue) }?.key
    }

    /// Environment that points Wine at this renderer's DLL overlay.
    /// Overlays go on WINEDLLPATH_PREPEND (supported by the engine's 0003 patch) and the D3D DLLs
    /// are set to native-then-builtin so the overlay's copies load instead of Wine's own.
    public func environment(engine: InstalledEngine) throws -> [String: String] {
        var env: [String: String] = [:]
        func dir(_ name: String) throws -> URL {
            guard let d = engine.rendererDirectory(name) else { throw GamePortError.missing("the \(name) renderer is not in the engine (\(engine.id))") }
            return d
        }
        // DXVK's D3D9 ("d9vk") keeps D3D9 games off wined3d on every Metal backend when present.
        let d9vk = engine.rendererDirectory("d9vk")?.appendingPathComponent("wine").path
        func withD9VK(_ overlays: [String]) -> String { ((d9vk.map { [$0] } ?? []) + overlays).joined(separator: ":") }

        switch self {
        case .wined3d:
            break
        case .dxmt:
            env["WINEDLLPATH_PREPEND"] = withD9VK([try dir("dxmt").appendingPathComponent("wine").path])
            env["WINEDLLOVERRIDES"] = "dxgi,d3d11,d3d10core" + (d9vk != nil ? ",d3d9" : "") + "=n,b"
        case .d3dmetal:
            let d3dm = try dir("d3dmetal")
            var overlays = [d3dm.appendingPathComponent("wine").path]
            // D3DMetal is 64-bit only: 32-bit D3D10/11 falls through to DXMT instead of wined3d.
            if let dxmt = engine.rendererDirectory("dxmt") { overlays.append(dxmt.appendingPathComponent("wine").path) }
            env["WINEDLLPATH_PREPEND"] = withD9VK(overlays)
            env["WINEDLLOVERRIDES"] = "dxgi,d3d11,d3d10core,d3d12,d3d12core" + (d9vk != nil ? ",d3d9" : "") + "=n,b"
            let external = d3dm.appendingPathComponent("external").path
            env["CX_D3DMETALPATH"] = external
            env["DYLD_FALLBACK_LIBRARY_PATH+"] = external
            env["DYLD_FALLBACK_FRAMEWORK_PATH+"] = external
        case .dxvk:
            env["WINEDLLPATH_PREPEND"] = withD9VK([try dir("dxvk").appendingPathComponent("wine").path])
            env["WINEDLLOVERRIDES"] = "dxgi,d3d11,d3d10core" + (d9vk != nil ? ",d3d9" : "") + "=n,b"
        }
        return env
    }
}

public enum SyncMode: String, Codable, Sendable, CaseIterable {
    case msync, esync, none

    public var environment: [String: String] {
        switch self {
        case .msync: return ["WINEMSYNC": "1", "WINEESYNC": "0"]
        case .esync: return ["WINEMSYNC": "0", "WINEESYNC": "1"]
        case .none: return ["WINEMSYNC": "0", "WINEESYNC": "0"]
        }
    }
}

/// Merges `extra` into `base`. Keys ending in `+` append: `:` for paths, `;` for WINEDLLOVERRIDES.
/// WINEDLLOVERRIDES is always appended, never replaced, so a recipe cannot silently drop the renderer's.
public func mergeEnvironment(_ base: [String: String], _ extra: [String: String]) -> [String: String] {
    var env = base
    for (rawKey, value) in extra.sorted(by: { $0.key < $1.key }) {
        let append = rawKey.hasSuffix("+") || rawKey == "WINEDLLOVERRIDES"
        let key = rawKey.hasSuffix("+") ? String(rawKey.dropLast()) : rawKey
        if append, let existing = env[key], !existing.isEmpty {
            let sep = key == "WINEDLLOVERRIDES" ? ";" : ":"
            env[key] = existing + sep + value
        } else {
            env[key] = value
        }
    }
    return env
}
