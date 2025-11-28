//! Top-level Game Boy state

const std = @import("std");
const CPU = @import("cpu.zig").CPU;
const Flags = @import("cpu.zig").Flags;
const MMU = @import("mmu.zig").MMU;
const Timer = @import("timer.zig").Timer;
const PPU = @import("ppu.zig").PPU;
const APU = @import("apu.zig").APU;
const MBC = @import("mbc.zig").MBC;
const MBCSaveState = @import("mbc.zig").MBCSaveState;

/// Save state structure (~25KB)
pub const SaveState = extern struct {
    cpu: extern struct {
        a: u8,
        f: u8,
        b: u8,
        c: u8,
        d: u8,
        e: u8,
        h: u8,
        l: u8,
        sp: u16,
        pc: u16,
        ime: u8,
        halted: u8,
        _pad: u16 = 0,
    },
    mbc: MBCSaveState,
    io: extern struct {
        div: u16,
        tima: u8,
        tma: u8,
        tac: u8,
        if_: u8,
        ie: u8,
        lcdc: u8,
        stat: u8,
        scy: u8,
        scx: u8,
        ly: u8,
        lyc: u8,
        bgp: u8,
        obp0: u8,
        obp1: u8,
        wy: u8,
        wx: u8,
        nr50: u8,
        nr51: u8,
        nr52: u8,
        _pad: [10]u8 = [_]u8{0} ** 10,
    },
    wram: [8192]u8,
    hram: [127]u8,
    _hram_pad: u8 = 0,
    vram: [8192]u8,
    oam: [160]u8,
    eram: [8192]u8,
};

/// Cycles per frame (154 scanlines * 456 cycles)
pub const CYCLES_PER_FRAME: u32 = 70224;

pub const GB = struct {
    cpu: CPU = .{},
    mmu: MMU = .{},
    ppu: PPU = .{},
    apu: APU = .{},

    cycles: u64 = 0, // Total cycles elapsed

    // Feature flags for headless/training mode
    render_graphics: bool = true, // Set false to skip PPU rendering
    render_audio: bool = true, // Set false to skip APU sample generation

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

        // Update APU (skip sample generation if disabled)
        if (self.render_audio) {
            self.apu.tick(cycles);
        }

        // Update PPU timing (LY counter, interrupts) - always runs for game logic
        const prev_ly = self.mmu.ly;
        self.mmu.tickPpu(cycles);

        // Render scanline when LY changes (skip if graphics disabled)
        if (self.render_graphics and self.mmu.ly != prev_ly) {
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

    // =========================================================
    // Battery saves (SRAM) - persists between sessions
    // =========================================================

    /// Get save data (external RAM, 8KB for Pokemon)
    pub fn getSaveData(self: *GB) []const u8 {
        return &self.mmu.eram;
    }

    /// Load save data into external RAM
    pub fn loadSaveData(self: *GB, data: []const u8) void {
        const len = @min(data.len, self.mmu.eram.len);
        @memcpy(self.mmu.eram[0..len], data[0..len]);
    }

    // =========================================================
    // Save states (full snapshot)
    // =========================================================

    /// Create a save state snapshot
    pub fn saveState(self: *GB) SaveState {
        return SaveState{
            .cpu = .{
                .a = self.cpu.a,
                .f = self.cpu.f.toU8(),
                .b = self.cpu.b,
                .c = self.cpu.c,
                .d = self.cpu.d,
                .e = self.cpu.e,
                .h = self.cpu.h,
                .l = self.cpu.l,
                .sp = self.cpu.sp,
                .pc = self.cpu.pc,
                .ime = @intFromBool(self.cpu.ime),
                .halted = @intFromBool(self.cpu.halted),
            },
            .mbc = self.mmu.mbc.toSaveState(),
            .io = .{
                .div = self.mmu.div_counter,
                .tima = self.mmu.tima,
                .tma = self.mmu.tma,
                .tac = self.mmu.tac,
                .if_ = self.mmu.if_,
                .ie = self.mmu.ie,
                .lcdc = self.mmu.lcdc,
                .stat = self.mmu.stat,
                .scy = self.mmu.scy,
                .scx = self.mmu.scx,
                .ly = self.mmu.ly,
                .lyc = self.mmu.lyc,
                .bgp = self.mmu.bgp,
                .obp0 = self.mmu.obp0,
                .obp1 = self.mmu.obp1,
                .wy = self.mmu.wy,
                .wx = self.mmu.wx,
                .nr50 = self.apu.nr50,
                .nr51 = self.apu.nr51,
                .nr52 = self.apu.nr52,
            },
            .wram = self.mmu.wram,
            .hram = self.mmu.hram,
            .vram = self.mmu.vram,
            .oam = self.mmu.oam,
            .eram = self.mmu.eram,
        };
    }

    /// Restore from a save state snapshot
    pub fn loadState(self: *GB, state: *const SaveState) void {
        // CPU
        self.cpu.a = state.cpu.a;
        self.cpu.f = Flags.fromU8(state.cpu.f);
        self.cpu.b = state.cpu.b;
        self.cpu.c = state.cpu.c;
        self.cpu.d = state.cpu.d;
        self.cpu.e = state.cpu.e;
        self.cpu.h = state.cpu.h;
        self.cpu.l = state.cpu.l;
        self.cpu.sp = state.cpu.sp;
        self.cpu.pc = state.cpu.pc;
        self.cpu.ime = state.cpu.ime != 0;
        self.cpu.halted = state.cpu.halted != 0;

        // MBC
        self.mmu.mbc.fromSaveState(state.mbc);

        // I/O
        self.mmu.div_counter = state.io.div;
        self.mmu.tima = state.io.tima;
        self.mmu.tma = state.io.tma;
        self.mmu.tac = state.io.tac;
        self.mmu.if_ = state.io.if_;
        self.mmu.ie = state.io.ie;
        self.mmu.lcdc = state.io.lcdc;
        self.mmu.stat = state.io.stat;
        self.mmu.scy = state.io.scy;
        self.mmu.scx = state.io.scx;
        self.mmu.ly = state.io.ly;
        self.mmu.lyc = state.io.lyc;
        self.mmu.bgp = state.io.bgp;
        self.mmu.obp0 = state.io.obp0;
        self.mmu.obp1 = state.io.obp1;
        self.mmu.wy = state.io.wy;
        self.mmu.wx = state.io.wx;
        self.apu.nr50 = state.io.nr50;
        self.apu.nr51 = state.io.nr51;
        self.apu.nr52 = state.io.nr52;

        // Memory
        self.mmu.wram = state.wram;
        self.mmu.hram = state.hram;
        self.mmu.vram = state.vram;
        self.mmu.oam = state.oam;
        self.mmu.eram = state.eram;
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
