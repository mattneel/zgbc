//! C FFI bindings for libzetro
//! Exposes all emulator features with stable C ABI.

const std = @import("std");
const gb_mod = @import("gb/system.zig");
const GB = gb_mod.GB;
const SaveState = gb_mod.SaveState;
const ppu = @import("gb/ppu.zig");

/// Opaque handle to a Game Boy instance
pub const zgbc_t = opaque {};

/// Convert opaque handle to GB pointer
inline fn toGB(handle: *zgbc_t) *GB {
    return @ptrCast(@alignCast(handle));
}

inline fn fromGB(gb: *GB) *zgbc_t {
    return @ptrCast(gb);
}

// =========================================================
// Lifecycle
// =========================================================

/// Create a new Game Boy instance
export fn zgbc_new() callconv(.c) ?*zgbc_t {
    const gb = std.heap.c_allocator.create(GB) catch return null;
    gb.* = .{};
    return fromGB(gb);
}

/// Destroy a Game Boy instance
export fn zgbc_free(handle: ?*zgbc_t) callconv(.c) void {
    if (handle) |h| {
        std.heap.c_allocator.destroy(toGB(h));
    }
}

/// Load ROM data (copies internally)
export fn zgbc_load_rom(handle: *zgbc_t, data: [*]const u8, len: usize) callconv(.c) bool {
    const gb = toGB(handle);
    gb.loadRom(data[0..len]) catch return false;
    gb.skipBootRom();
    return true;
}

// =========================================================
// Emulation
// =========================================================

/// Run one frame (~70224 cycles)
export fn zgbc_frame(handle: *zgbc_t) callconv(.c) void {
    toGB(handle).frame();
}

/// Run one CPU step, returns cycles consumed
export fn zgbc_step(handle: *zgbc_t) callconv(.c) u8 {
    return toGB(handle).step();
}

/// Set joypad input state
/// Bits: 0=A, 1=B, 2=Select, 3=Start, 4=Right, 5=Left, 6=Up, 7=Down
export fn zgbc_set_input(handle: *zgbc_t, buttons: u8) callconv(.c) void {
    toGB(handle).mmu.joypad_state = ~buttons;
}

// =========================================================
// Rendering control
// =========================================================

/// Enable/disable graphics rendering (for headless mode)
export fn zgbc_set_render_graphics(handle: *zgbc_t, enabled: bool) callconv(.c) void {
    toGB(handle).render_graphics = enabled;
}

/// Enable/disable audio rendering (for headless mode)
export fn zgbc_set_render_audio(handle: *zgbc_t, enabled: bool) callconv(.c) void {
    toGB(handle).render_audio = enabled;
}

// =========================================================
// Video output
// =========================================================

/// Get pointer to frame buffer (160x144 2-bit color indices)
export fn zgbc_get_frame_buffer(handle: *zgbc_t) callconv(.c) [*]const u8 {
    return toGB(handle).getFrameBuffer();
}

/// Get RGBA frame buffer (converts 2-bit to RGBA)
export fn zgbc_get_frame_rgba(handle: *zgbc_t, out: [*]u32) callconv(.c) void {
    const gb = toGB(handle);
    const indices = gb.getFrameBuffer();
    for (indices, 0..) |color_idx, i| {
        out[i] = ppu.PALETTE[color_idx];
    }
}

/// Get current scanline (0-153)
export fn zgbc_get_ly(handle: *zgbc_t) callconv(.c) u8 {
    return toGB(handle).mmu.ly;
}

// =========================================================
// Audio output
// =========================================================

/// Read audio samples (stereo i16, 44100 Hz)
/// Returns number of samples read
export fn zgbc_get_audio_samples(handle: *zgbc_t, out: [*]i16, max_samples: usize) callconv(.c) usize {
    return toGB(handle).getAudioSamples(out[0..max_samples]);
}

// =========================================================
// Memory access
// =========================================================

/// Read a byte from memory
export fn zgbc_read(handle: *zgbc_t, addr: u16) callconv(.c) u8 {
    return toGB(handle).mmu.read(addr);
}

/// Write a byte to memory
export fn zgbc_write(handle: *zgbc_t, addr: u16, val: u8) callconv(.c) void {
    toGB(handle).mmu.write(addr, val);
}

/// Get pointer to WRAM (8KB)
export fn zgbc_get_wram(handle: *zgbc_t) callconv(.c) [*]const u8 {
    return &toGB(handle).mmu.wram;
}

/// Get WRAM size
export fn zgbc_get_wram_size() callconv(.c) usize {
    return 8192;
}

// =========================================================
// Battery saves (SRAM)
// =========================================================

/// Get pointer to save RAM
export fn zgbc_get_save_data(handle: *zgbc_t) callconv(.c) [*]const u8 {
    return toGB(handle).getSaveData().ptr;
}

/// Get save RAM size
export fn zgbc_get_save_size(handle: *zgbc_t) callconv(.c) usize {
    return toGB(handle).getSaveData().len;
}

/// Load save data
export fn zgbc_load_save_data(handle: *zgbc_t, data: [*]const u8, len: usize) callconv(.c) void {
    toGB(handle).loadSaveData(data[0..len]);
}

// =========================================================
// Save states
// =========================================================

/// Get save state size
export fn zgbc_save_state_size() callconv(.c) usize {
    return @sizeOf(SaveState);
}

/// Create save state (caller provides buffer)
export fn zgbc_save_state(handle: *zgbc_t, out: [*]u8) callconv(.c) usize {
    const state = toGB(handle).saveState();
    const bytes: *const [@sizeOf(SaveState)]u8 = @ptrCast(&state);
    @memcpy(out[0..@sizeOf(SaveState)], bytes);
    return @sizeOf(SaveState);
}

/// Load save state
export fn zgbc_load_state(handle: *zgbc_t, data: [*]const u8) callconv(.c) void {
    const state: *const SaveState = @ptrCast(@alignCast(data));
    toGB(handle).loadState(state);
}

// =========================================================
// State queries
// =========================================================

/// Get total cycles elapsed
export fn zgbc_get_cycles(handle: *zgbc_t) callconv(.c) u64 {
    return toGB(handle).cycles;
}

/// Check if CPU is halted
export fn zgbc_is_halted(handle: *zgbc_t) callconv(.c) bool {
    return toGB(handle).cpu.halted;
}
