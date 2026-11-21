# KosmicKrisp shim (experiment)

Wine's `win32u` loads `libMoltenVK.dylib` by name and resolves Vulkan through its `vkGetInstanceProcAddr`.
KosmicKrisp (Mesa's Vulkan 1.4 driver on Metal) only exports the loader interface (`vk_icdGetInstanceProcAddr`),
so it cannot replace MoltenVK directly. `shim.c` is a small `libMoltenVK.dylib` that forwards to the
KosmicKrisp library next to it, with no Vulkan loader in between. Only the game itself goes to KosmicKrisp: a
process whose .exe lives under `steamapps\common\` (set `GAMEPORT_KOSMICKRISP_MATCH` to match something else).
Every other process (Steam, its web helper, explorer, Wine's services) is forwarded to the engine's real
MoltenVK: on KosmicKrisp Steam's web UI got no device and its window stayed black (first test, 2026-10-31).

Setup (once): downloads Sikarugir's `kosmickrisp-x86_64.zip` (release 20261029, SHA-256 `5c55c95b…0fc93b`) into
`~/Downloads/gameport-build/kk`, then builds the shim into the engine:

```sh
Tools/kosmickrisp-shim/install.sh
```

Then pick it for a game: `.build/debug/gameport vulkan <profile> kosmickrisp` (back with `moltenvk`). GamePort sets
`CX_LIBVULKAN` and `CX_ACTIVE_GRAPHICS_BACKEND` for that profile.

Measure a profile on KosmicKrisp with extra driver logging (the profile is restored afterwards):

```sh
Tools/kosmickrisp-shim/try.sh team-fortress-2 dxmt 150
```

The DXMT renderer is the cleanest test for D3D9 games: Steam's window draws through DXMT (Metal, no Vulkan), and
the game's D3D9 goes through DXVK's d3d9 to Vulkan, so the game is the only Vulkan user. TF2 measured 246 FPS
this way on MoltenVK, which is the number to compare with.

Every process that loads Vulkan logs one line, `kosmickrisp-shim: <exe> on MoltenVK` or
`kosmickrisp-shim: <exe> on KosmicKrisp …`. DXVK's `Device name` line shows which driver answered.
On KosmicKrisp the shim also logs what `vkCreateInstance`, `vkEnumeratePhysicalDevices` and `vkCreateDevice`
return, plus the device's name, Vulkan version and extension list (saved to `lab/kosmickrisp/device-extensions.txt`).
`GAMEPORT_VK_TRACE=1` turns the same logging on for MoltenVK; MoltenVK's list on an M1 is in
`research_notes/moltenvk-1.4.2-m1-device-extensions.txt`. `try.sh` files its lab results under
`profiles/<id>/lab/kosmickrisp/`, so experiments never count as the profile's evidence, and sets
`DXVK_LOG_LEVEL=debug` for the run.

When the driver refuses a device with `VK_ERROR_FEATURE_NOT_PRESENT`, the shim names each requested feature it
does not report and retries once with those switched off (DXVK's D3D9 always asks for `fillModeNonSolid`, which
KosmicKrisp lacks). `GAMEPORT_VK_KEEP_FEATURES=1` keeps the error instead.

KosmicKrisp needs macOS 26 or later.
