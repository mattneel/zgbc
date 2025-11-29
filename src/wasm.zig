//! WASM bindings for browser deployment
//! Multi-system emulator: Game Boy, NES, and SMS

const gb_mod = @import("gb/system.zig");
const GB = gb_mod.GB;
const GBSaveState = gb_mod.SaveState;
const gb_ppu = @import("gb/ppu.zig");

const nes_mod = @import("nes/system.zig");
const NES = nes_mod.NES;
const NESSaveState = nes_mod.SaveState;

const sms_mod = @import("sms/system.zig");
const SMS = sms_mod.SMS;
const SMSSaveState = sms_mod.SaveState;

const genesis_mod = @import("genesis/system.zig");
const Genesis = genesis_mod.Genesis;

// =============================================================================
// Shared resources
// =============================================================================

var rom_storage: [4 * 1024 * 1024]u8 = undefined; // 4MB max ROM
var audio_buffer: [4096]i16 = undefined;

/// Get ROM buffer pointer (shared across systems)
export fn getRomBuffer() [*]u8 {
    return &rom_storage;
}

/// Get audio buffer pointer (shared across systems)
export fn getAudioBuffer() [*]i16 {
    return &audio_buffer;
}

// =============================================================================
// Game Boy
// =============================================================================

var gb: GB = .{};
var gb_rgba: [160 * 144]u32 = undefined;
var gb_save_state: GBSaveState = undefined;

export fn gb_init() void {
    gb = .{};
}

export fn gb_loadRom(len: usize) bool {
    if (len > rom_storage.len) return false;
    gb.loadRom(rom_storage[0..len]) catch return false;
    gb.skipBootRom();
    return true;
}

export fn gb_frame() void {
    gb.frame();
}

export fn gb_step() u8 {
    return gb.step();
}

export fn gb_setInput(buttons: u8) void {
    gb.mmu.joypad_state = ~buttons;
}

export fn gb_getFrame() [*]u32 {
    const indices = &gb.ppu.frame_buffer;
    for (indices, 0..) |color_idx, i| {
        gb_rgba[i] = gb_ppu.PALETTE[color_idx];
    }
    return &gb_rgba;
}

export fn gb_getFrameWidth() u32 {
    return 160;
}

export fn gb_getFrameHeight() u32 {
    return 144;
}

export fn gb_getLY() u8 {
    return gb.mmu.ly;
}

export fn gb_isVBlank() bool {
    return gb.mmu.ly >= 144;
}

export fn gb_getAudioSamples() usize {
    return gb.getAudioSamples(&audio_buffer);
}

export fn gb_setRenderGraphics(enabled: bool) void {
    gb.render_graphics = enabled;
}

export fn gb_setRenderAudio(enabled: bool) void {
    gb.render_audio = enabled;
}

export fn gb_read(addr: u16) u8 {
    return gb.mmu.read(addr);
}

export fn gb_write(addr: u16, val: u8) void {
    gb.mmu.write(addr, val);
}

// Battery saves
export fn gb_getSavePtr() [*]u8 {
    return &gb.mmu.eram;
}

export fn gb_getSaveSize() usize {
    return gb.mmu.eram.len;
}

// Save states
export fn gb_saveStateSize() usize {
    return @sizeOf(GBSaveState);
}

export fn gb_saveState() [*]u8 {
    gb_save_state = gb.saveState();
    return @ptrCast(&gb_save_state);
}

export fn gb_loadState(ptr: [*]const u8) void {
    const state: *const GBSaveState = @ptrCast(@alignCast(ptr));
    gb.loadState(state);
}

// RAM access for RL
export fn gb_getRamPtr() [*]const u8 {
    return gb.getRam().ptr;
}

export fn gb_getRamSize() usize {
    return gb.getRam().len;
}

// =============================================================================
// NES
// =============================================================================

var nes: NES = .{};
var nes_save_state: NESSaveState = undefined;

export fn nes_init() void {
    nes = .{};
}

export fn nes_loadRom(len: usize) bool {
    if (len > rom_storage.len) return false;
    nes.loadRom(rom_storage[0..len]);
    return true;
}

export fn nes_frame() void {
    nes.frame();
}

export fn nes_step() u8 {
    return nes.step();
}

export fn nes_setInput(buttons: u8) void {
    nes.setInput(buttons);
}

export fn nes_getFrame() [*]u32 {
    return @constCast(nes.getFrameBuffer());
}

export fn nes_getFrameWidth() u32 {
    return 256;
}

export fn nes_getFrameHeight() u32 {
    return 240;
}

export fn nes_getScanline() u16 {
    return @intCast(@as(i32, nes.ppu.scanline) & 0xFFFF);
}

export fn nes_isVBlank() bool {
    return nes.ppu.scanline >= 241;
}

export fn nes_getAudioSamples() usize {
    return nes.getAudioSamples(&audio_buffer);
}

export fn nes_setRenderGraphics(enabled: bool) void {
    nes.render_graphics = enabled;
}

export fn nes_setRenderAudio(enabled: bool) void {
    nes.render_audio = enabled;
}

export fn nes_read(addr: u16) u8 {
    return nes.read(addr);
}

export fn nes_write(addr: u16, val: u8) void {
    nes.write(addr, val);
}

// Battery saves
export fn nes_getSavePtr() [*]u8 {
    return &nes.mmu.prg_ram;
}

export fn nes_getSaveSize() usize {
    return nes.mmu.prg_ram.len;
}

// Save states
export fn nes_saveStateSize() usize {
    return @sizeOf(NESSaveState);
}

export fn nes_saveState() [*]u8 {
    nes_save_state = nes.saveState();
    return @ptrCast(&nes_save_state);
}

export fn nes_loadState(ptr: [*]const u8) void {
    const state: *const NESSaveState = @ptrCast(@alignCast(ptr));
    nes.loadState(state.*);
}

// RAM access for RL
export fn nes_getRamPtr() [*]const u8 {
    return nes.getRam().ptr;
}

export fn nes_getRamSize() usize {
    return nes.getRam().len;
}

// =============================================================================
// SMS (Sega Master System)
// =============================================================================

var sms: SMS = .{};
var sms_save_state: SMSSaveState = undefined;

export fn sms_init() void {
    sms = .{};
}

export fn sms_loadRom(len: usize) bool {
    if (len > rom_storage.len) return false;
    sms.loadRom(rom_storage[0..len]);
    return true;
}

export fn sms_frame() void {
    sms.frame();
}

export fn sms_step() u8 {
    return sms.step();
}

export fn sms_setInput(buttons: u8) void {
    sms.setInput(buttons);
}

export fn sms_getFrame() [*]u32 {
    return @constCast(sms.getFrameBuffer());
}

export fn sms_getFrameWidth() u32 {
    return 256;
}

export fn sms_getFrameHeight() u32 {
    return sms.getScreenHeight();
}

export fn sms_getScanline() u16 {
    return sms.vdp.scanline;
}

export fn sms_isVBlank() bool {
    return sms.vdp.scanline >= sms.vdp.screen_height;
}

export fn sms_getAudioSamples() usize {
    return sms.getAudioSamples(&audio_buffer);
}

export fn sms_setRenderGraphics(enabled: bool) void {
    sms.render_graphics = enabled;
}

export fn sms_setRenderAudio(enabled: bool) void {
    sms.render_audio = enabled;
}

export fn sms_read(addr: u16) u8 {
    return sms.read(addr);
}

export fn sms_write(addr: u16, val: u8) void {
    sms.write(addr, val);
}

// Battery saves
export fn sms_getSavePtr() [*]u8 {
    return &sms.bus.cart_ram;
}

export fn sms_getSaveSize() usize {
    return sms.bus.cart_ram.len;
}

// Save states
export fn sms_saveStateSize() usize {
    return @sizeOf(SMSSaveState);
}

export fn sms_saveState() [*]u8 {
    sms_save_state = sms.saveState();
    return @ptrCast(&sms_save_state);
}

export fn sms_loadState(ptr: [*]const u8) void {
    const state: *const SMSSaveState = @ptrCast(@alignCast(ptr));
    sms.loadState(state.*);
}

// RAM access for RL
export fn sms_getRamPtr() [*]const u8 {
    return sms.getRam().ptr;
}

export fn sms_getRamSize() usize {
    return sms.getRam().len;
}

// =============================================================================
// Genesis (Sega Mega Drive)
// =============================================================================

var gen: Genesis = .{};

export fn gen_init() void {
    gen = .{};
}

export fn gen_loadRom(len: usize) bool {
    if (len > rom_storage.len) return false;
    gen.loadRom(rom_storage[0..len]);
    return true;
}

export fn gen_frame() void {
    gen.frame();
}

export fn gen_step() u32 {
    return gen.step();
}

export fn gen_setInput(buttons: u8) void {
    gen.setInput(buttons);
}

export fn gen_getFrame() [*]u32 {
    return @constCast(gen.getFrameBuffer());
}

export fn gen_getFrameWidth() u32 {
    return 320;
}

export fn gen_getFrameHeight() u32 {
    return 224;
}

export fn gen_getScanline() u16 {
    return gen.vdp.scanline;
}

export fn gen_isVBlank() bool {
    return gen.vdp.scanline >= 224;
}

export fn gen_getAudioSamples() usize {
    return gen.getAudioSamples(&audio_buffer);
}

export fn gen_read(addr: u32) u8 {
    return gen.read(addr);
}

export fn gen_write(addr: u32, val: u8) void {
    gen.write(addr, val);
}

// Battery saves (SRAM)
export fn gen_getSavePtr() [*]u8 {
    return &gen.bus.sram;
}

export fn gen_getSaveSize() usize {
    return gen.bus.sram.len;
}

// RAM access for RL
export fn gen_getRamPtr() [*]const u8 {
    return gen.getRam().ptr;
}

export fn gen_getRamSize() usize {
    return gen.getRam().len;
}
