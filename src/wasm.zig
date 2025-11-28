//! WASM bindings for browser deployment
//! Exports a minimal API for running Game Boy games in the browser.

const GB = @import("gb.zig").GB;
const ppu = @import("ppu.zig");
const PALETTE = ppu.PALETTE;

var gb: GB = .{};
var rgba_buffer: [160 * 144]u32 = undefined;
var rom_storage: [4 * 1024 * 1024]u8 = undefined; // 4MB max ROM
var audio_buffer: [4096]i16 = undefined; // Audio sample buffer

/// Initialize emulator state
export fn init() void {
    gb = .{};
}

/// Allocate space for ROM and return pointer
/// Call this before loadRom to get a buffer to write ROM data into
export fn getRomBuffer() [*]u8 {
    return &rom_storage;
}

/// Load ROM from the pre-allocated buffer
export fn loadRom(len: usize) bool {
    if (len > rom_storage.len) return false;
    gb.loadRom(rom_storage[0..len]) catch return false;
    gb.skipBootRom();
    return true;
}

/// Run one frame (~70224 cycles)
export fn frame() void {
    gb.frame();
}

/// Set joypad input state
/// Bits: 0=A, 1=B, 2=Select, 3=Start, 4=Right, 5=Left, 6=Up, 7=Down
export fn setInput(buttons: u8) void {
    gb.mmu.joypad_state = ~buttons;
}

/// Get pointer to RGBA frame buffer (160x144x4 bytes)
/// Call after frame() to get the rendered image
export fn getFrame() [*]u32 {
    const indices = &gb.ppu.frame_buffer;
    for (indices, 0..) |color_idx, i| {
        rgba_buffer[i] = PALETTE[color_idx];
    }
    return &rgba_buffer;
}

/// Get current scanline (0-153)
export fn getLY() u8 {
    return gb.mmu.ly;
}

/// Check if in VBlank (LY >= 144)
export fn isVBlank() bool {
    return gb.mmu.ly >= 144;
}

/// Get pointer to audio sample buffer
export fn getAudioBuffer() [*]i16 {
    return &audio_buffer;
}

/// Read audio samples into the buffer, return count
/// Samples are stereo i16 at 44100 Hz
export fn getAudioSamples() usize {
    return gb.getAudioSamples(&audio_buffer);
}
