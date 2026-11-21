# Contributing to GamePort

Contributions are very welcome — whether it's verifying game recipes, improving the Lab, fixing bugs, polishing the macOS app, or helping push the open DirectX 12 and ARM64 engine paths forward!

See [ROADMAP.md](ROADMAP.md) for current priorities and [AGENTS.md](AGENTS.md) for codebase architecture and build commands.

## Licensing & Contribution Terms

GamePort is free for personal and non-commercial use under the **PolyForm Noncommercial License 1.0.0** ([LICENSE](LICENSE)).

To keep GamePort sustainable and easy to maintain long-term, submitting a pull request or patch means you confirm that your contribution is your own work (or that you have permission to submit it) and that while you retain copyright in your contribution, you grant the `akinware/gameport` project maintainer a perpetual, worldwide, non-exclusive, royalty-free, irrevocable copyright and patent license to use, distribute, sublicense, commercialize, and relicense your contribution as part of GamePort under any terms.

## Third-party code & clean-room rules

- Wine, DXMT, winetricks, and highball-engine are LGPL; GamePort downloads and runs them as separate processes and does not link to them. Do not copy code from these projects.
- Do not copy code from Highball (GPL-3.0) or closed-source launchers.
- Game recipes may only be adapted from the CC0 parts of `highball-db`; credit the source in the `source` field.
- Never add, host, or patch Apple's D3DMetal or the Windows Steam client in this repository.
- Patches under `Patches/` remain under the license of the project they patch (DXVK: zlib).

## Language

English is the source language for code, UI text, recipes, and commit messages.
