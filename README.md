# GamePort

A macOS app that runs Windows games on Apple Silicon Macs.

Every game runs in its own isolated Windows environment: its own Wine prefix, its own Steam install and
its own HOME folder. The engine is read-only and shared, so a fix for one game can never break another.
Wine's Z: drive, which shows the whole Mac, is removed. Known gap: while a game runs, Wine shows mounted
removable volumes (USB disks, open DMGs) again as D:, E:, …; closing that needs a Wine patch.

## Quick start (Xcode)

1. Open `Package.swift` in Xcode.
2. Pick **GamePortApp** in the scheme menu and press ▶ Run.
3. In the app: **Setup → Install engine**. For games that use D3DMetal, read and accept Apple's licence.
4. Pick a game in the list: **Create the Windows environment → Install Windows Steam → Open Steam**
   (sign in, download the game) **→ Play**.

## Command line

```sh
swift build -c release
.build/release/gameport doctor
.build/release/gameport engine install
.build/release/gameport recipes
.build/release/gameport base build              # optional, once: the Steam base
.build/release/gameport profile create elden-ring
.build/release/gameport steam install elden-ring  # not needed with a Steam base
.build/release/gameport steam open elden-ring
.build/release/gameport play elden-ring
```

**Steam base.** Every profile installs Windows Steam and downloads its first update (~240 MB).
`gameport base build` does that once; every later profile is created as an APFS copy of the base in seconds,
using almost no disk. Profiles stay isolated: the copies split on first write. Nobody ever signs in to the
base; you sign in separately in each profile.

**Snapshots.** Before a Steam, game or engine update, `gameport snapshot <profile>` saves the profile's state;
if something breaks, `gameport snapshot restore <profile> <name>` rolls it back. An automatic snapshot is taken
before Steam's first start each day (the newest two are kept; turn it off with
`gameport snapshot auto <profile> off`). Snapshots are APFS copies: a 34 GB profile is copied in 0.6 seconds
using a few MB.

**Lab.** `gameport lab <profile> [dxmt,dxvk,…] [seconds]` starts the game through Steam, measures FPS from
the Metal HUD log, decides whether it works and writes the result, with the Mac, macOS version and engine,
to `profiles/<profile>/lab/`. The profile is put back as it was afterwards. A run with the game window covered
counts as "not measured", unless the game process never started or the log shows a crash.
`gameport lab <profile> auto` ("Find the best renderer" in the app) tries DXMT, D3DMetal (once Apple's licence
is accepted) and DXVK in turn, and sets the profile to the one with the highest average FPS after warm-up
among those that worked to the end.

**Anti-cheat.** `gameport anticheat <game name|Steam id>` tells you before downloading whether a game's
anti-cheat blocks it on a Mac (1,166 games, highball-db / Are We Anti-Cheat Yet?, MIT). The app shows the same
information on the game's badge: kernel anti-cheat is "Will not run", anti-cheat that rejects Wine is
"Online play will most likely fail".

**Patched DXVK.** The engine's DXVK crashes in D3D11 games that use pipeline-statistics queries, which MoltenVK
does not support. `Scripts/build-dxvk.sh` builds DXVK with the patches in `Patches/dxvk/` on this Mac and installs
it for the DXVK renderer only (`--revert` undoes it). The build tools are downloaded to `~/Downloads/gameport-build`.

**KosmicKrisp (experimental).** Games that reach Metal through Vulkan (DXVK, vkd3d) can use KosmicKrisp, Mesa's
open Vulkan 1.4 driver on Metal, instead of MoltenVK. `Tools/kosmickrisp-shim/install.sh` downloads Sikarugir's
build (pinned by SHA-256) and builds GamePort's shim into the engine; then `gameport vulkan <profile> kosmickrisp` (or the
picker in the app's Lab box) switches one game. Only the game uses it; Steam and Wine's own programs stay on MoltenVK.
Team Fortress 2 (D3D9 through DXVK) renders on it. Needs macOS 26 or later.

`Scripts/make-app.sh` builds a double-clickable `GamePort.app`.

## Languages

English is the source language. UI strings are SwiftUI string literals, ready to be extracted into a String
Catalog (`Localizable.xcstrings`) when other languages are added. The catalog is not in the package yet:
SwiftPM would put it in a resource bundle that SwiftUI does not read by default and that `make-app.sh` does not
copy, so it comes with the move to an Xcode app target.

## Roadmap & Contributing

Contributions, verified game recipes, and bug fixes are welcome! See [ROADMAP.md](ROADMAP.md) for current status and next milestones, [AGENTS.md](AGENTS.md) for codebase orientation, and [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Layout

| Folder | Contents |
| --- | --- |
| `Sources/GamePortKit` | Core: engine manager, profiles, renderer choice, recipes, Steam, lab |
| `Sources/gameport` | Command-line tool |
| `Sources/GamePortApp` | SwiftUI app |
| `Data/engines` | Engine manifests (every component: URL + SHA-256) |
| `Data/recipes` | Game recipes. After editing: `python3 Scripts/embed-data.py` |
| `Data/anticheat` | Anti-cheat map (MIT), imported by `Scripts/import-anticheat.py` |
| `Patches/dxvk` | GamePort's DXVK patches |
| `Tests` | Unit tests (`swift test`) |

Data: `~/Library/Application Support/GamePort` (override with `GAMEPORT_HOME`). Deleting this folder is a full uninstall.

## Licences

GamePort is free for personal and non-commercial use under the **PolyForm Noncommercial License 1.0.0** (`LICENSE`); contribution guidelines are in `CONTRIBUTING.md`.
The app downloads third-party components and runs them as separate programs; their own licences apply
(LGPL for Wine and DXMT, Apple's licence for D3DMetal): details in `THIRD_PARTY_NOTICES.md`.
