# Repository Guidelines

## Project Structure & Module Organization
`src/root.zig` re-exports every console core housed in `src/<system>/`, with shared helpers (SIMD batches, `wasm.zig`, `c_api.zig`) beside it. The public C header lives in `include/zgbc.h`, browser glue in `web/`, and build outputs in `zig-out/`. Tests plus ROM fixtures remain in `test/` (e.g., `test/battletoads_test.zig`, `test/m68k_test.zig`), while redistributable sample ROMs belong in `roms/`.

## Build, Test, and Development Commands
Run everything through the Zig build runner so caching and options stay consistent:

```bash
zig build -Doptimize=ReleaseFast     # native CLI
zig build lib -Doptimize=ReleaseFast # libzgbc + headers
zig build wasm                       # web-ready WASM
zig build test                       # unit + integration
zig build test-blargg                # GB CPU conformance
zig build bench                      # headless benchmark
```

## Coding Style & Naming Conventions
Stick to idiomatic Zig: four-space indentation, braces on the same line, and `zig fmt src test include` before submitting. Types stay `UpperCamelCase` (`GB`, `SaveState`), identifiers stay `lowerCamelCase`, and files remain `snake_case.zig` (`sms/system.zig`, `genesis/vdp.zig`). Keep hot paths allocation-free, rely on explicit `std.mem` helpers, and mirror the directory structure with focused structs per subsystem (CPU, PPU, MMU, VDP, PSG).

## Testing Guidelines
Each console has targeted suites (e.g., `test/blargg_test.zig`, `test/sms_visual_test.zig`) that are driven through `zig build test`. New ROM fixtures belong in their console-specific folder with a harness that documents the ROM source and asserts pixel/audio expectations via `std.testing`. Before opening a PR, run `zig build test` plus the relevant focused test (`zig test test/m68k_test.zig` when touching the 68k core).

## Commit & Pull Request Guidelines
Recent history shows compact, imperative summaries that name the subsystem (`Add Sega Master System emulator core`, `Fix NES PPU scrolling`). Follow that `<Verb> <scope>` pattern, keep the subject ≤72 characters, and list verification commands in the body when the change is non-trivial. PRs should include a short narrative, linked issue when available, command output snippets (`zig build test`, `zig build wasm`), and screenshots or audio notes when touching rendering or sound, while explicitly calling out new ROMs or licenses.

## Security & Configuration Tips
Do not check in commercial ROMs, user saves, or secrets; describe how to obtain required files instead. `web/index.html` expects a ReleaseFast WASM (`zig build wasm -Doptimize=ReleaseFast`) to keep the bundle small, so double-check size before publishing. Configuration flows through CLI flags or host integrations, so document any new environment variables in README.md and this guide.
