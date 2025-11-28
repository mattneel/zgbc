//! Top-level Game Boy state

const std = @import("std");
const CPU = @import("cpu.zig").CPU;
const MMU = @import("mmu.zig").MMU;
const Timer = @import("timer.zig").Timer;
const PPU = @import("ppu.zig").PPU;
const APU = @import("apu.zig").APU;

/// Cycles per frame (154 scanlines * 456 cycles)
pub const CYCLES_PER_FRAME: u32 = 70224;

pub const GB = struct {
    cpu: CPU = .{},
    mmu: MMU = .{},
    ppu: PPU = .{},
    apu: APU = .{},

    cycles: u64 = 0, // Total cycles elapsed

    /// Execute one instruction, return cycles consumed
    pub fn step(self: *GB) u8 {
        // Wire APU to MMU on first call
        if (self.mmu.apu == null) {
            self.mmu.apu = &self.apu;
        }

        const cycles = self.cpu.step(&self.mmu);

        // Update timer
        Timer.tick(
            &self.mmu.div_counter,
            &self.mmu.tima,
            self.mmu.tma,
            self.mmu.tac,
            &self.mmu.if_,
            cycles,
        );

        // Update APU
        self.apu.tick(cycles);

        // Update PPU (LY counter, interrupts)
        const prev_ly = self.mmu.ly;
        self.mmu.tickPpu(cycles);

        // Render scanline when LY changes
        if (self.mmu.ly != prev_ly) {
            if (self.mmu.ly == 0) {
                self.ppu.resetWindowLine();
            }
            if (prev_ly < 144) {
                self.ppu.renderScanline(&self.mmu);
            }
        }

        self.cycles += cycles;
        return cycles;
    }

    /// Execute one frame (~70224 cycles)
    pub fn frame(self: *GB) void {
        const target = self.cycles + CYCLES_PER_FRAME;
        while (self.cycles < target) {
            _ = self.step();
        }
    }

    /// Set joypad input state
    pub fn setInput(self: *GB, buttons: u8) void {
        // Buttons are active low
        self.mmu.joypad_state = ~buttons;
    }

    /// Get WRAM for observations
    pub fn getRam(self: *GB) []const u8 {
        return &self.mmu.wram;
    }

    /// Get frame buffer (160x144 2-bit color indices)
    pub fn getFrameBuffer(self: *GB) *const [160 * 144]u8 {
        return &self.ppu.frame_buffer;
    }

    /// Get audio samples (stereo i16, 44100 Hz)
    pub fn getAudioSamples(self: *GB, out: []i16) usize {
        return self.apu.readSamples(out);
    }

    /// Load a ROM
    pub fn loadRom(self: *GB, rom: []const u8) !void {
        try self.mmu.loadRom(rom);
    }

    /// Skip boot ROM - set up post-boot state
    pub fn skipBootRom(self: *GB) void {
        // Values after boot ROM completes (DMG)
        self.cpu.a = 0x01;
        self.cpu.f = .{ .z = true, .h = true, .c = true };
        self.cpu.b = 0x00;
        self.cpu.c = 0x13;
        self.cpu.d = 0x00;
        self.cpu.e = 0xD8;
        self.cpu.h = 0x01;
        self.cpu.l = 0x4D;
        self.cpu.sp = 0xFFFE;
        self.cpu.pc = 0x0100;

        // I/O register initial values
        self.mmu.div_counter = 0xAB << 8;
        self.mmu.tima = 0x00;
        self.mmu.tma = 0x00;
        self.mmu.tac = 0x00;
        self.mmu.if_ = 0x01; // VBlank interrupt pending
        self.mmu.ie = 0x00;

        // LCD registers after boot
        self.mmu.lcdc = 0x91; // LCD enabled, BG enabled
        self.mmu.stat = 0x85;
        self.mmu.scy = 0x00;
        self.mmu.scx = 0x00;
        self.mmu.ly = 0x00;
        self.mmu.lyc = 0x00;
        self.mmu.bgp = 0xFC;
        self.mmu.obp0 = 0x00;
        self.mmu.obp1 = 0x00;
        self.mmu.wy = 0x00;
        self.mmu.wx = 0x00;
    }
};

test "gb step" {
    var gb = GB{};
    // Without a ROM, this will just execute undefined opcodes
    _ = gb.step();
}
