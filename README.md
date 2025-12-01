# zgbc

High-performance Game Boy emulator in pure Zig. Full graphics, audio, save states, and multiple integration paths: Zig library, C FFI, or 137KB WASM for browsers.

## Performance

Pokemon Red benchmark (Intel Core i9-13980HX):

```
Single-thread performance:
  Full (PPU+APU):        4,571 FPS (76x realtime)
  PPU-only (no APU):    12,123 FPS (202x realtime)  <-- RL-relevant
  Headless:             22,881 FPS (381x realtime)

Headless multi-threaded scaling:
Threads |    FPS    | Per-thread |  Scaling
--------|-----------|------------|----------
      1 |    22,818 |     22,818 |    1.00x
      2 |    45,340 |     22,670 |    1.98x
      4 |    84,773 |     21,193 |    3.70x
      8 |   147,777 |     18,472 |    6.46x
     16 |   185,249 |     11,578 |    8.10x
     32 |   290,683 |      9,084 |   12.70x
```

**290,683 FPS headless** at 32 threads — 4,845x realtime.

### RL Training Performance

For reinforcement learning (PPU-only mode: graphics enabled for pixel observations, audio disabled):

```
PyBoy:     5,521 FPS
zgbc:     10,589 FPS  (1.92x faster)
```

zgbc exceeds the ~6,000 FPS target for [PufferLib](https://github.com/PufferAI/PufferLib) integration.

## Features

- **Full PPU** — Background, window, sprites, all 4 colors
- **Full APU** — 2 pulse channels, wave channel, noise channel
- **Save states** — Full 25KB snapshots, instant save/load
- **Battery saves** — 8KB SRAM persistence for Pokemon etc.
- **Headless mode** — Disable rendering for 5x speedup in training
- **C FFI** — `libzgbc.so` / `libzgbc.a` with stable ABI
- **WASM build** — 137KB, runs in browser at 60 FPS with audio
- **All Blargg CPU tests pass** — Correct LR35902 implementation
- **MBC1/MBC3 support** — Pokemon Red/Blue/Yellow compatible
- **Zero dependencies** — Pure Zig, no libc required
- **~3,500 lines** — Auditable, hackable

## Building

```bash
# Native CLI
zig build -Doptimize=ReleaseFast

# C library (libzgbc.so + libzgbc.a + zgbc.h)
zig build lib -Doptimize=ReleaseFast

# WASM (zig-out/bin/zgbc.wasm)
zig build wasm

# Tests
zig build test
zig build test-blargg

# Benchmark
zig build bench
```

## Native CLI

`zig build run -- <rom>` launches a desktop window backed by raylib with the same controls as the WASM build (Z/X for the primary buttons, Shift/Enter for Select/Start, arrow keys for the D-pad, C for Genesis C, etc.).

```
zig build run -- roms/pokered.gb
zig build run -- --system genesis roms/sonic2.md
zig build run -- --headless --no-audio roms/battletoads.nes
```

Available flags:

- `--system <auto|gb|nes|sms|genesis>`: override automatic ROM detection.
- `--scale <N>`: integer window scale factor (default `3`).
- `--no-audio`: keep the emulator running but mute playback.
- `--headless`: skip the raylib surface entirely and print the achieved FPS in the terminal.
- `--skip-boot`: start Game Boy titles directly at `0x0100`.

raylib is built from source in `third_party/raylib`, so no external SDKs are required beyond your platform OpenGL/X11/CoreAudio libraries.

## Python bindings

A thin ctypes wrapper ships in `bindings/python/zgbc.py`. Point `PYTHONPATH` at `bindings/python/`, make sure `libzgbc` has been built (`zig build lib`), and use it like this:

```python
from pathlib import Path
from zgbc import GameBoy, Buttons

gb = GameBoy()
gb.load_rom(Path("roms/pokered.gb").read_bytes())
gb.skip_boot()

while True:
    gb.set_input(Buttons.A | Buttons.START)
    gb.frame()
    frame = gb.get_frame_rgba()  # memoryview of 160x144 RGBA pixels
    audio = gb.get_audio_samples()
    # ... feed into your renderer/audio device ...
```

The wrapper takes care of loading the shared library (or respect `ZGBC_LIB` if you want to point it somewhere explicit) and exposes the most common APIs for headless integrations.

## As a Dependency

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zgbc = .{
        .url = "https://github.com/yourusername/zgbc/archive/refs/heads/master.tar.gz",
        .hash = "...",  // zig build will tell you the hash
    },
},
```

Then in your `build.zig`:

```zig
const zgbc_dep = b.dependency("zgbc", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zgbc", zgbc_dep.module("zgbc"));
```

Or for a local path dependency:

```zig
.dependencies = .{
    .zgbc = .{ .path = "../zgbc" },
},
```

## Usage

### Native (Zig)

```zig
const zgbc = @import("zgbc");

var gb = zgbc.GB{};
try gb.loadRom(rom_data);
gb.skipBootRom();

// Headless mode for training (5x faster)
gb.render_graphics = false;
gb.render_audio = false;

// Run one frame (~70224 cycles)
gb.frame();

// Set joypad input
gb.mmu.joypad_state = ~@as(u8, 0x09); // A + Start

// Read RAM for observations
const player_x = gb.mmu.read(0xD362);

// Get frame buffer (160x144, 2-bit color indices)
const pixels = gb.getFrameBuffer();

// Get audio samples (stereo i16, 44100 Hz)
var audio: [2048]i16 = undefined;
const count = gb.getAudioSamples(&audio);

// Save states
const state = gb.saveState();
// ... later ...
gb.loadState(&state);

// Battery saves (SRAM)
const sram = gb.getSaveData();
// ... persist to disk ...
gb.loadSaveData(saved_sram);
```

### C (libzgbc)

```c
#include <zgbc.h>

zgbc_t* gb = zgbc_new();
zgbc_load_rom(gb, rom_data, rom_len);

// Headless mode for training
zgbc_set_render_graphics(gb, false);
zgbc_set_render_audio(gb, false);

// Run one frame
zgbc_frame(gb);

// Set joypad (bits: A,B,Sel,Start,R,L,U,D)
zgbc_set_input(gb, ZGBC_BTN_A | ZGBC_BTN_START);

// Read RAM
uint8_t player_x = zgbc_read(gb, 0xD362);

// Get frame buffer (160x144 RGBA)
uint32_t pixels[160*144];
zgbc_get_frame_rgba(gb, pixels);

// Get audio
int16_t audio[4096];
size_t count = zgbc_get_audio_samples(gb, audio, 4096);

// Save states (25KB)
uint8_t state[ZGBC_SAVE_STATE_SIZE];
zgbc_save_state(gb, state);
zgbc_load_state(gb, state);

// Battery saves
const uint8_t* sram = zgbc_get_save_data(gb);
size_t sram_size = zgbc_get_save_size(gb);
// ... persist to disk, reload with zgbc_load_save_data() ...

zgbc_free(gb);
```

Link with: `gcc -lzgbc -L/path/to/zig-out/lib -I/path/to/zig-out/include`

### WASM (Browser)

```javascript
const { instance } = await WebAssembly.instantiate(wasmBytes, {});
const wasm = instance.exports;

wasm.init();

// Load ROM
const romPtr = wasm.getRomBuffer();
new Uint8Array(wasm.memory.buffer).set(romData, romPtr);
wasm.loadRom(romData.length);

// Headless mode (optional)
wasm.setRenderGraphics(false);
wasm.setRenderAudio(false);

// Game loop
function frame() {
    wasm.setInput(buttonState);  // bits: A,B,Sel,Start,R,L,U,D
    wasm.frame();

    // Get pixels (160x144 RGBA)
    const framePtr = wasm.getFrame();
    const pixels = new Uint32Array(wasm.memory.buffer, framePtr, 160*144);

    // Get audio
    const audioCount = wasm.getAudioSamples();
    const audioPtr = wasm.getAudioBuffer();
    const samples = new Int16Array(wasm.memory.buffer, audioPtr, audioCount);

    // Save states
    const stateSize = wasm.saveStateSize();
    const statePtr = wasm.saveState();
    const state = new Uint8Array(wasm.memory.buffer, statePtr, stateSize);
    // ... store state, later: wasm.loadState(ptr) ...
}
```

See `web/index.html` for a complete browser demo.

## Web Demo

```bash
zig build wasm
cd web
python -m http.server 8000
# Open http://localhost:8000
```

Controls: Arrow keys (D-pad), Z (A), X (B), Enter (Start), Shift (Select)

## Tests

All 12 Blargg CPU instruction tests pass:

```
01-special         PASS    07-jr,jp,call,ret  PASS
02-interrupts      PASS    08-misc instrs     PASS
03-op sp,hl        PASS    09-op r,r          PASS
04-op r,imm        PASS    10-bit ops         PASS
05-op rp           PASS    11-op a,(hl)       PASS
06-ld r,r          PASS    cpu_instrs         PASS
```

## Architecture

```
src/
├── cpu.zig       # LR35902 CPU, comptime opcode tables
├── mmu.zig       # Memory mapping, I/O registers
├── mbc.zig       # MBC1/MBC3 cartridge banking
├── timer.zig     # DIV/TIMA timer
├── ppu.zig       # Pixel Processing Unit, scanline renderer
├── apu.zig       # Audio Processing Unit, 4 channels
├── gb.zig        # Top-level Game Boy state, save states
├── c_api.zig     # C FFI bindings (libzgbc)
├── wasm.zig      # WASM bindings
├── bench.zig     # Performance benchmark
└── root.zig      # Public Zig API

include/
└── zgbc.h        # C header

web/
├── index.html    # Browser demo
└── zgbc.wasm     # 137KB WASM binary
```

## Pokemon Red RAM Map

| Address | Description |
|---------|-------------|
| 0xD356  | Badges      |
| 0xD359  | Game state  |
| 0xD35E  | Map ID      |
| 0xD361  | Player Y    |
| 0xD362  | Player X    |
| 0xD16B  | Party count |

Full map: [pokered RAM](https://datacrystal.romhacking.net/wiki/Pok%C3%A9mon_Red/Blue:RAM_map)

## License

MIT
