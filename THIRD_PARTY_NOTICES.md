# Third-party components

GamePort does not bundle these components. It downloads them to the user's Mac from their official release
addresses, verifies each against a pinned SHA-256, and runs them as separate programs.

| Component | Licence | Source |
| --- | --- | --- |
| Wine 11.0 (CodeWeavers CrossOver 26.3 source) | LGPL-2.1-or-later | https://media.codeweavers.com/pub/crossover/source/ |
| highball-engine Wine build and patch series | LGPL-2.1 | https://github.com/gauthierpiarrette/highball-engine |
| Sikarugir Template 1.0.11 (runtime libraries) | mixed (GStreamer LGPL, gnutls LGPL, MoltenVK Apache-2.0, DXVK zlib, …) | https://github.com/Sikarugir-App/Wrapper |
| DXMT (Highball branch, gauthierpiarrette/dxmt@highball-20260930) | LGPL-2.1-or-later (after v0.80; older releases MIT) | https://github.com/gauthierpiarrette/dxmt |
| MoltenVK 1.4.2 (patched) | Apache-2.0 | https://github.com/KhronosGroup/MoltenVK |
| winetricks | LGPL-2.1-or-later | https://github.com/Winetricks/winetricks |
| D3DMetal 3.0 (Apple Game Porting Toolkit), comes inside the Sikarugir Template | Apple licence: non-commercial use, no modification | https://developer.apple.com/games/game-porting-toolkit/ |

**Where D3DMetal comes from.** GamePort does not host D3DMetal and does not put it inside the app. D3DMetal comes
inside the Template archive that is downloaded from Sikarugir's GitHub release when the engine is installed (not
from Apple's site). The D3DMetal renderer is used only after the user accepts Apple's licence in the app.
Highball and Sikarugir follow the same path. This is a grey area chosen deliberately for the user experience:
Apple's licence does not clearly allow third-party distribution, and it is not clear that it forbids it.

A lawyer should be consulted before any paid version. D3DMetal is never put inside GamePort's own app or servers and
is never offered as a paid feature; the DXMT/DXVK paths are not affected by this restriction.

Some game recipes are adapted from highball-db data (CC0-1.0, https://github.com/gauthierpiarrette/highball-db);
each recipe's `source` field names its source.

The anti-cheat list (`Data/anticheat/`) is taken from highball-db and derives from Are We Anti-Cheat Yet? data
(MIT, Copyright © 2021 Starz0r, Curve; https://github.com/AreWeAntiCheatYet/AreWeAntiCheatYet). The licence text is
in `Data/anticheat/LICENSE`. The Mac interpretations ("blocked"/"warning") are Highball's. GamePort uses this list only
to inform; it never works around anti-cheat.

If we publish a Wine patch (LGPL), we publish its source too.

**Patched DXVK (local build only).** `Scripts/build-dxvk.sh` builds Gcenx/DXVK-macOS (zlib licence,
https://github.com/Gcenx/DXVK-macOS, commit 8f1e28d) with the patches in `Patches/dxvk/` on the user's own Mac.
GamePort does not distribute this build today; if it does, the zlib licence text goes with the DLLs.
