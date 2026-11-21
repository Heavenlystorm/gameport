# Open DirectX 12 path (no D3DMetal)

Why: D3DMetal is x86_64-only and Apple-licensed, so on a Rosetta-free ARM64 engine (and for anyone who
avoids the D3DMetal grey area) D3D12 games need an open path: **D3D12 → Vulkan (vkd3d) → Metal (MoltenVK or
KosmicKrisp)**. These notes record what GamePort's current engine has, what blocks it, and the next experiment.
Written 2026-10-31.

## What the engine has today

Engine `x64-crossover26.3-hb20261014` (x86_64, Rosetta):

| Piece | What it is | Where |
| --- | --- | --- |
| Wine's built-in `d3d12.dll` / `d3d12core.dll` | upstream **vkd3d** (CrossOver 26.3 lists vkd3d 1.18) | `engine/lib/wine/x86_64-windows/` |
| `winevulkan` | Wine's Vulkan thunk | `engine/lib/wine/x86_64-*/` |
| `libMoltenVK.dylib` | Highball's patched **MoltenVK 1.4.2** (driverVersion 10402 = "0.2.2210" in DXVK's log) | `frameworks/` |
| `moltenvkcx/libMoltenVK.dylib` | CodeWeavers' MoltenVK fork, based on 1.2.10 (CrossOver 25), not used | `frameworks/moltenvkcx/` |

**How Wine reaches Vulkan:** `win32u.so` `dlopen`s **`libMoltenVK.dylib` by name** (found through
`DYLD_FALLBACK_LIBRARY_PATH` = `frameworks/`). There is no Vulkan loader (`libvulkan.1.dylib`) and no ICD JSON in
between. So a different Vulkan driver can only be swapped in by putting it where that name resolves, and it
must export the full Vulkan API itself (`vkGetInstanceProcAddr` etc.), as MoltenVK does.

Which D3D12 runs today: with the DXMT or DXVK renderer GamePort does not override `d3d12`, so a D3D12 game gets
Wine's built-in vkd3d on MoltenVK. With the D3DMetal renderer it gets D3DMetal. Nobody has measured the vkd3d
path in GamePort yet.

## What MoltenVK 1.4.2 offers (from GamePort's DXVK lab log, M1, 2026-10-31)

DXVK 1.10 printed the device as **Vulkan 1.1.357**. MoltenVK clamps the advertised API version (it has
`MVK_CONFIG_API_VERSION_TO_ADVERTISE`, and reports no more than the app asked for; DXVK 1.10 asks for 1.1),
so this number is not proof the driver lacks 1.3. Features DXVK checked:

| Feature | MoltenVK 1.4.2 on M1 |
| --- | --- |
| `samplerMirrorClampToEdge` (`VK_KHR_sampler_mirror_clamp_to_edge`) | yes |
| `VK_EXT_robustness2`: robustImageAccess2 / robustBufferAccess2 / nullDescriptor | yes / **no** / **no** |
| `bufferDeviceAddress` | **no** (as reported to DXVK) |
| timeline semaphores, extended dynamic state, demote-to-helper, shaderInt64 | yes |
| geometryShader, transformFeedback, shaderFloat64, pipelineStatisticsQuery, depthBounds | **no** |

## What the D3D12 translators need

**vkd3d-proton (v3.1, Oct 2026)**, hard requirements from its README:
- Vulkan **1.3**
- descriptor indexing with ≥ 1,000,000 update-after-bind descriptors per type (all
  `VkPhysicalDeviceDescriptorIndexingFeatures`)
- `samplerMirrorClampToEdge`, `shaderDrawParameters`
- `VK_EXT_robustness2`, `VK_KHR_push_descriptor`
- strongly recommended: `VK_EXT_mutable_descriptor_type`, `VK_EXT_descriptor_buffer`, `VK_EXT_image_view_min_lod`

On MoltenVK the likely blockers are the descriptor counts (Metal argument-buffer limits),
`nullDescriptor`/`robustBufferAccess2`, and possibly 1.3 itself. metalsharp's VKD3D-Proton-MacOS fork exists
but its claims are unverified.

**Wine's vkd3d (upstream, 1.18)** is more lenient: it targets Vulkan 1.0 plus extensions and scales the D3D12
resource-binding tier to what the driver offers. That makes it the most likely path to get *something* running
on MoltenVK today, at a performance cost.

**KosmicKrisp** (Mesa's Vulkan-on-Metal driver) passed the Vulkan 1.4 conformance tests (Phoronix, 3 Oct 2026)
and is the most promising base for vkd3d-proton. Sikarugir publishes automated builds
(`Sikarugir-App/mesa-kosmickrisp` releases, e.g. `20261029`: `kosmickrisp-x86_64.zip` and
`kosmickrisp-arm64.zip`, ~2 MB each). Template 1.0.14 added KosmicKrisp v26.2.2, 1.0.15 updated it to
v20260903; Templates now go up to 1.0.24 (release notes stop at 1.0.15). How the Template switches between
MoltenVK and KosmicKrisp is not documented. Mesa drivers normally export only the loader interface
(`vk_icdGetInstanceProcAddr`), not `vkGetInstanceProcAddr`, so a plain swap under the name `libMoltenVK.dylib`
probably needs a Vulkan loader or a small shim; this is the first thing to check.

## KosmicKrisp, inspected (2026-10-31)

`kosmickrisp-x86_64.zip` from Sikarugir's `20261029` release (SHA-256 `5c55c95b…0fc93b`, matches GitHub's digest)
holds `libvulkan_kosmickrisp.dylib` (x86_64, needs macOS 26+, links only system frameworks: Metal, QuartzCore,
Foundation) and `kosmickrisp_mesa_icd.json` (`api_version` **1.4.366**). It exports only the three loader-interface
functions: `vk_icdGetInstanceProcAddr`, `vk_icdGetPhysicalDeviceProcAddr`, `vk_icdNegotiateLoaderICDInterfaceVersion`.

So it cannot replace `libMoltenVK.dylib` as is. GamePort now has a 60-line shim (`Tools/kosmickrisp-shim/`) that
exports `vkGetInstanceProcAddr`/`vkGetDeviceProcAddr`, negotiates the ICD interface and forwards to KosmicKrisp. It is
selected per profile by putting its folder first on `DYLD_LIBRARY_PATH`, so other games keep MoltenVK. The shim
builds and exports the right symbols; it has **not been run yet** (running the downloaded driver needs the user:
`Tools/kosmickrisp-shim/try.sh team-fortress-2 dxvk 150`, which tests it under DXVK's D3D9 before any D3D12 work).

**First run (user, 2026-10-31 16:48, TF2, DXVK renderer, 150 s):** the shim loaded
(`kosmickrisp-shim: using …`) and KosmicKrisp created a Vulkan instance. But Steam itself inherits the profile's
library path, and its web helper (D3D11 through DXVK, adapter matched by LUID through Wine's dxgi) never got a
device: it restarted 6 times, Steam's window stayed black and TF2 did not really start. Also, GStreamer's
`applemedia` plugin links against MoltenVK's private `mvkMTLPixelFormatFromVkFormat`, so it fails to load with the
shim (video playback in games). Next: keep Steam on MoltenVK and put only the game on KosmicKrisp (Steam launches
the game as a child, so this needs a per-process choice, e.g. the shim falling back to MoltenVK for
`steamwebhelper.exe`), and find why DXVK finds no adapter (likely the LUID match).

**Second run (user, 2026-11-01 00:29, TF2, DXVK renderer):** Steam's processes were sent to MoltenVK as planned,
but two other processes (the shim did not log names yet; most likely explorer.exe and another Wine helper) still
went to KosmicKrisp. Steam's web helper then stopped right after launching its GPU process (cef_log.txt ends at
00:29:52), so Steam never launched TF2 (lab: "the game process never started"). In the 16:48 run the GPU process
had crashed three times with exit code 541541187 = 0x20474343, the code of an uncaught MinGW C++ exception: DXVK
throwing because it found no Vulkan device.

The DXVK renderer was a poor first test anyway: it puts Steam's own Chromium UI on DXVK D3D11 → Vulkan, and
TF2 on DXVK had never passed a lab run, even on MoltenVK. Changes (2026-11-01):
- The shim now sends **only the game** to KosmicKrisp (an .exe under `steamapps\common\`); everything else gets
  MoltenVK. It logs every process by name, and it refuses to forward to itself (both dylibs share the install
  name `@rpath/libMoltenVK.dylib`). The MoltenVK path was checked with a test program posing as `steam.exe`.
- `try.sh` defaults to the **DXMT renderer**: Steam draws through DXMT on Metal, and TF2's D3D9 goes through
  DXVK's d3d9 to Vulkan, so TF2 is the only Vulkan user. The same setup measured 245.8 FPS on MoltenVK
  (2026-10-31 12:49), which is the baseline to compare with.
- The lab reads Steam's `cef_log.txt` for the run, and reports "Steam's GPU process crashed N times" (≥ 2).
- Side finding: MoltenVK 1.4.2's `vkEnumerateInstanceVersion` returns **1.4.357**, so the 1.1 that DXVK printed
  was only the version DXVK 1.10 asked for. vkd3d-proton's Vulkan 1.3 requirement is met by the API version; its
  feature requirements remain the question.

**Third run (user, 2026-11-01 00:39, TF2, DXMT renderer):** the only driver line was
`explorer.exe on MoltenVK (not found)`, and Steam never started at all: none of its logs were touched. Root cause
of this run and the second one: the profile finds the shim through `DYLD_LIBRARY_PATH`, and dyld applies that to
the **leaf name of every load, full paths included**. So the shim's `dlopen("…/frameworks/libMoltenVK.dylib")`
returned the shim itself. In the second run the shim then forwarded Steam's web helper to itself and recursed
(the web helper hung right after starting its GPU process). In the third, the new self-check caught it, but
explorer.exe (Wine's desktop process) was left with no Vulkan at all, and Steam, which waits for the desktop, never
came up (a likely reading; not proven).

Fix: `build.sh` puts a link `libMoltenVK-engine.dylib → ../../frameworks/libMoltenVK.dylib` next to the shim,
and the shim opens that leaf name. A test program loading the shim exactly as Wine does (leaf name, with
`DYLD_LIBRARY_PATH` set) shows the old shim failing ("not found") and the new one reaching MoltenVK
(Vulkan 1.4.357). The lab now also says "Steam itself never started" when bootstrap_log.txt gets no new
`Startup` line. **No run has reached the game on KosmicKrisp yet.**

**Fourth run (user, 2026-11-01 00:46, TF2, DXMT renderer): first game on KosmicKrisp.** Every process went where
intended: Steam, its web helper, explorer, conhost and Steam's `vulkandriverquery` helpers on MoltenVK, and
`tf_win64.exe` on KosmicKrisp. TF2's d3d9 (DXVK-Kegworks 1.10.4-async) created a Vulkan instance on KosmicKrisp
(`Enabled instance extensions: VK_KHR_get_surface_capabilities2, VK_KHR_surface, VK_KHR_win32_surface`), then
three seconds later died with `Unhandled exception 0x20474343` (an uncaught DXVK C++ exception) and winedbg
started. DXVK printed nothing about adapters before throwing, so it most likely failed while listing or
initialising the GPU: no device, or a device without something DXVK 1.10 requires. (Two `winevulkan/loader.c:665`
asserts in the same log come from Steam's driver-query helpers on MoltenVK, not from TF2.)

The lab called this run "works, 16.7 FPS": it measured the busiest Metal HUD process, which was **Steam's own
window** (DXMT draws it through Metal, ~108 MB), still rendering after TF2 had crashed. Fixed: the lab now counts
only the HUD samples of the game's own processes (pids of `.exe`s under `steamapps\common\` from `ps`), and
reports "the game exited before the end". The earlier 245.8 FPS DXMT baseline came from a ~430 MB process, so it
was most likely TF2 itself, but it should be re-measured with the fixed lab. The four KosmicKrisp runs were moved to
`profiles/team-fortress-2/lab/kosmickrisp/` so they do not count as TF2's evidence.

Next run logs what KosmicKrisp returns for instance creation, device enumeration and device creation, plus the
device's extension list (compare with `moltenvk-1.4.2-m1-device-extensions.txt`), and DXVK's debug log.

**Fifth run (user, 2026-11-01 00:53, TF2, DXMT renderer).** Same crash; this time the lab reported it correctly
("no frames": unhandled exception, the game exited before the end). Wine's crash report, decoded against the
d9vk `d3d9.dll`'s COFF symbols: `Direct3DCreate9Ex` → `D3D9InterfaceEx::D3D9InterfaceEx` →
`DxvkInstance::DxvkInstance` → `DxvkInstance::createInstance` throws **"DxvkInstance::createInstance: Failed to
create Vulkan 1.1 instance"** (the return address sits right after that `__cxa_throw`), called from TF2's
`shaderapidx9` through Steam's overlay. The shim never logged a host `vkCreateInstance`, so Wine's Vulkan layer gave
up before reaching KosmicKrisp.

What Wine's `win32u` does, from its disassembly (CrossOver 26.3): `vulkan_init_once` picks the library
(`libMoltenVK.dylib`, or `CX_LIBVULKAN` when `CX_ACTIVE_GRAPHICS_BACKEND=wined3d`), dlsyms `vkGetDeviceProcAddr` and
`vkGetInstanceProcAddr`, resolves `vkCreateInstance` and `vkEnumerateInstanceExtensionProperties`, lists the host
instance extensions (warning "Extension %s is not supported." for ones it does not know), records which surface
extensions exist (win32, headless, metal, wayland, xlib, MVK macos) and creates its own host instance. With
MoltenVK through the shim (Notepad test, `CX_LIBVULKAN`, `GAMEPORT_VK_TRACE=1`) all of that succeeds. The next run logs
KosmicKrisp's instance extensions and Wine's `warn+vulkan` messages, which should name the missing piece.

`try.sh` now selects the shim with `CX_LIBVULKAN` instead of `DYLD_LIBRARY_PATH`, and the shim's install name is
`@rpath/libgameport_vulkan_shim.dylib`, so it can no longer be mistaken for MoltenVK by anything that links it.
MoltenVK's instance extensions are in `moltenvk-1.4.2-instance-extensions.txt`.

**Sixth run (user, 2026-11-01, TF2, DXMT renderer, shim through `CX_LIBVULKAN`, `warn+vulkan`).** KosmicKrisp's
14 instance extensions were logged (`lab/kosmickrisp/instance-extensions.txt`): the same as MoltenVK's minus
`VK_EXT_headless_surface`, `VK_EXT_layer_settings`, `VK_MVK_macos_surface` and `VK_MVK_moltenvk`, and it **does**
have `VK_EXT_metal_surface`. The `is_instance_extension_supported … "VK_EXT_metal_surface" is not supported` lines are
Wine hiding Mac-only extensions from the Windows program (Steam's helpers on MoltenVK print the same), not the failure.
Wine's game instance enables every Mac surface extension the driver has. TF2's sequence: Wine loads the shim,
KosmicKrisp lists its extensions, DXVK asks for an instance, and the host `vkCreateInstance` never reaches the shim.

Found and fixed on the way, reproduced without KosmicKrisp: Steam's `vulkandriverquery64.exe` asserts at
`winevulkan/loader.c:665` through the shim on MoltenVK but not on plain MoltenVK. Wine dlsyms `vkGetDeviceProcAddr`
from the library, and the shim answered it with `vkGetInstanceProcAddr(NULL, "vkGetDeviceProcAddr")`, which MoltenVK
does not answer, so Wine got no device functions. The shim now takes it from the library (MoltenVK) or from the
first real instance (KosmicKrisp); the assert is gone. In trace mode the shim also logs any **global** function the
driver does not return, and the instance version, which is what the next KosmicKrisp run needs to show.

**Seventh run (user, 2026-11-01 02:44).** No global function missing, still no host `vkCreateInstance`. Following
the call in the disassembly: winevulkan's `thunk64_vkCreateInstance` → `wine_vkCreateInstance` (wraps debug
callbacks only) → entry `+0x40` of the table `win32u` hands out (`0x19d8e8`, fixup → `0x130e90`). That function
(it contains `convert_instance_create_info`) has exactly two exits before it calls the driver's `vkCreateInstance`
at `0x13132f`: out of memory, and **`enabledLayerCount != 0` → FIXME "Loading explicit layers is not supported!" →
`VK_ERROR_LAYER_NOT_PRESENT`**. GamePort runs with `WINEDEBUG=fixme-all`, so that message never showed. Likely reading:
something in TF2's process asks for an explicit layer (Steam's overlay hooks exactly this call), so this is not
KosmicKrisp-specific; not proven yet. `try.sh` now runs with `fixme-all,+vulkan` and prints the crashing thread's
last Vulkan calls.

**Eighth run (user, 2026-11-01 02:53, `fixme-all,+vulkan`): root cause found.** No layer FIXME, so the layer
theory was wrong. TF2's own trace shows the **client** instance extensions Wine offers it: no
`VK_KHR_win32_surface`. DXVK asks for `VK_KHR_get_surface_capabilities2`, `VK_KHR_surface`,
`VK_KHR_win32_surface`; Wine enabled the first two and refused the instance at the third, before calling the driver.

Why: winemac's `VulkanInit` (`winemac.so` `0x3c220`) does `dlsym(vulkan_library, "vkCreateMetalSurfaceEXT")` and
keeps only whether it was found. Its surface hook (`0x3c530`) then offers `VK_KHR_win32_surface` on top of
`VK_EXT_metal_surface` if it was found, otherwise only on top of MoltenVK's own `VK_MVK_macos_surface`. The real
MoltenVK exports `vkCreateMetalSurfaceEXT`; the shim did not, so Wine fell back to `VK_MVK_macos_surface`, which
works on MoltenVK and does not exist on KosmicKrisp. Fix: the shim exports `vkCreateMetalSurfaceEXT` and forwards it
to the driver. Checked with `vulkandriverquery64.exe` on MoltenVK through the shim: the program gets
`VK_KHR_win32_surface`, Wine enables host `VK_EXT_metal_surface`, instance and device are created.

Lesson for the shim: Wine looks up three symbols directly in the Vulkan library (`vkGetInstanceProcAddr`,
`vkGetDeviceProcAddr` in win32u, `vkCreateMetalSurfaceEXT` in winemac); a stand-in must export all three.

**Ninth run (user, 2026-11-01, after the `vkCreateMetalSurfaceEXT` export): the instance works.** TF2's instance
is created on KosmicKrisp (`vkCreateInstance = 0`; Wine enables host `VK_EXT_metal_surface`), DXVK sees "Apple M1",
driver 26.99.99, Vulkan 1.4.366, one 12 GB memory heap, and reports `robustBufferAccess2` and `nullDescriptor` (both
missing on MoltenVK). Next failure: `vkCreateDevice` = **-8, `VK_ERROR_FEATURE_NOT_PRESENT`**, twice; DXVK's
18 device extensions all pass through Wine unchanged. The shim now reports, on -8, every feature bit the request
asks for that the driver does not report (core features by name, extension structures by field index; tested
on MoltenVK with a crafted request, which named `Robustness2 field 0` = `robustBufferAccess2`).

**Tenth run (user, 2026-11-01): the missing feature is `fillModeNonSolid`** (wireframe/point fill), requested by
DXVK's D3D9 and not reported by KosmicKrisp; the request also carries `VkPhysicalDeviceShaderDrawParametersFeatures`
(sType 1000063000). The shim now retries a device refused with -8 once with the unreported bits switched off,
logs each as "(dropped)" and restores the caller's request afterwards (`GAMEPORT_VK_KEEP_FEATURES=1` disables this).
Tested on MoltenVK with a crafted request (-8 → 0, request restored). Cost: wireframe draws are undefined on
KosmicKrisp; TF2 does not use them in normal play.

**Eleventh run (user, 2026-11-01 13:40): TF2 renders on KosmicKrisp.** `fillModeNonSolid` was dropped, the device
was created on the retry, and TF2 (D3D9 → DXVK 1.10.4 d3d9 → Wine → shim → KosmicKrisp → Metal) drew 2,987 frames:
typical **182 FPS**, average 42.5 FPS over the 69.5 s after warm-up because of one 45 s stall (loading; probably first-time
shader compilation). The measured process used 1.4 GB, so it was TF2, not Steam's window. The window was in front
only 40% of the time. For comparison, MoltenVK measured 245.8 FPS average in the menu (2026-10-31, before the lab
fixes); a fair comparison needs both runs with the window in front and a second KosmicKrisp run (warm shader cache).
DXVK logged two unhandled D3D9 render states (136, 161), unrelated to the driver.

What it took (all in the shim): pick it with `CX_LIBVULKAN` instead of `DYLD_LIBRARY_PATH`; reach MoltenVK through a
link with its own leaf name; export `vkGetDeviceProcAddr` and `vkCreateMetalSurfaceEXT` like MoltenVK does; retry a
device without features the driver lacks.

**GamePort option (2026-11-01).** KosmicKrisp is now a per-profile setting (`Profile.vulkanDriver`, `gameport vulkan <profile>
kosmickrisp`, picker in the app's Lab box). `WineRunner` sets `CX_LIBVULKAN`/`CX_ACTIVE_GRAPHICS_BACKEND` and refuses to
start if the shim is missing; lab results record the driver ("dxmt + KosmicKrisp"). `Tools/kosmickrisp-shim/install.sh`
installs the pinned driver and builds the shim.

## Recommended next experiment

Goal: one D3D12 title rendering on the open path, measured by `gameport lab`, with no D3DMetal involved.

1. **Baseline on today's engine (no downloads by GamePort).** A free D3D12 test: **3DMark Demo** on Steam
   (includes Time Spy, D3D12) or **Path of Exile** (free, has a DX12 renderer option). Create a profile, install
   it through Steam, then run the lab with the DXMT renderer, which leaves `d3d12` to Wine's vkd3d on MoltenVK:
   ```bash
   cd ~/Downloads/gameport && .build/debug/gameport lab <profile> dxmt 180
   ```
   The game log (`profiles/<profile>/logs/game.log`) shows vkd3d's messages (`vkd3d:`), including which
   features it found missing.
2. **Inspect KosmicKrisp without running it.** Download the x86_64 build and list its exports and files
   (inspection only):
   ```bash
   mkdir -p ~/Downloads/gameport-build/kk && cd ~/Downloads/gameport-build/kk && curl -fLO https://github.com/Sikarugir-App/mesa-kosmickrisp/releases/download/20261029/kosmickrisp-x86_64.zip && unzip -o kosmickrisp-x86_64.zip && find . -type f && nm -gU $(find . -name '*.dylib' | head -1) | grep -i GetInstanceProcAddr
   ```
   If it exports `vkGetInstanceProcAddr`, it can stand in for `libMoltenVK.dylib` directly; if it only exports
   `vk_icdGetInstanceProcAddr`, it needs the Khronos Vulkan loader in between.
3. **Then add it to GamePort** as an optional engine component pinned by SHA-256, with a profile switch that puts
   KosmicKrisp first on the library path for that game only, and rerun step 1 to compare MoltenVK and
   KosmicKrisp under Wine's vkd3d. vkd3d-proton (built like DXVK, through `Scripts/build-dxvk.sh`'s toolchain) comes
   after that.

## Open questions

- ~~Does MoltenVK 1.4.2 expose Vulkan 1.3 when asked?~~ Yes: the instance reports 1.4.357.
- How does Sikarugir's Template select KosmicKrisp: loader, shim or rename?
- How far does Wine's vkd3d 1.18 get on MoltenVK's descriptor limits (resource binding tier)?
