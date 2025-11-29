//! NES System
//! Top-level NES emulator state.

const std = @import("std");
const CPU = @import("cpu.zig").CPU;
const MMU = @import("mmu.zig").MMU;
const PPU = @import("ppu.zig").PPU;
const APU = @import("apu.zig").APU;

pub const SCREEN_WIDTH = 256;
pub const SCREEN_HEIGHT = 240;
pub const FRAME_CYCLES = 29780; // NTSC

/// Save state structure
pub const SaveState = extern struct {
    cpu: extern struct {
        a: u8,
        x: u8,
        y: u8,
        sp: u8,
        pc: u16,
        status: u8,
        _pad: u8 = 0,
    },
    ppu: extern struct {
        ctrl: u8,
        mask: u8,
        status: u8,
        oam_addr: u8,
        v: u16,
        t: u16,
        x: u8,
        w: u8,
        scanline: i16,
        cycle: u16,
    },
    ram: [2048]u8,
    vram: [2048]u8,
    palette: [32]u8,
    oam: [256]u8,
    prg_ram: [8192]u8,
};

pub const NES = struct {
    cpu: CPU = .{},
    mmu: MMU = .{},
    ppu: PPU = .{},
    apu: APU = .{},

    cycles: u64 = 0,
    frame_cycles: u32 = 0,

    // Feature flags
    render_graphics: bool = true,
    render_audio: bool = true,

    /// Initialize and wire components
    pub fn init(self: *NES) void {
        self.mmu.ppu = &self.ppu;
        self.mmu.apu = &self.apu;
    }

    /// Load ROM
    pub fn loadRom(self: *NES, data: []const u8) void {
        self.init();
        self.mmu.loadRom(data);
        self.ppu.chr = self.mmu.chr_rom;
        if (self.mmu.chr_rom.len == 0) {
            self.ppu.use_chr_ram = true;
        }
        self.cpu.reset(&self.mmu);
    }

    /// Execute one instruction
    pub fn step(self: *NES) u8 {
        // Wire components if needed
        if (self.mmu.ppu == null) self.init();

        // Handle DMA
        if (self.mmu.dma_pending) {
            self.mmu.performDma(&self.ppu);
            self.cpu.stall = 513;
            if (self.cycles & 1 != 0) self.cpu.stall += 1;
        }

        // Check for NMI from PPU
        if (self.ppu.nmi_pending) {
            self.ppu.nmi_pending = false;
            self.cpu.nmi_pending = true;
        }

        // Check for mapper IRQ (MMC3, etc.)
        if (self.mmu.mapper.pollIrq()) {
            self.cpu.irq_pending = true;
        }

        const cpu_cycles = self.cpu.step(&self.mmu);

        // Update PPU mirroring from mapper (AxROM, MMC3 control it dynamically)
        if (self.mmu.mapper.getMirroring()) |m| {
            self.ppu.mirroring = m;
        }

        // PPU runs 3x faster than CPU
        const ppu_cycles = @as(u32, cpu_cycles) * 3;
        for (0..ppu_cycles) |_| {
            self.ppu.tick();
            // Sprite evaluation at end of visible scanline
            if (self.ppu.cycle == 257 and self.ppu.scanline >= 0 and self.ppu.scanline < 240) {
                self.ppu.evaluateSprites();
            }
            // Clock mapper scanline counter (MMC3) at cycle 260 during visible scanlines
            // This is when A12 rises during sprite fetches if using $1xxx for sprites
            if (self.ppu.cycle == 260 and self.ppu.scanline >= 0 and self.ppu.scanline < 240) {
                if (self.ppu.mask & 0x18 != 0) { // Rendering enabled
                    self.mmu.mapper.clockScanline();
                }
            }
        }

        // APU
        if (self.render_audio) {
            self.apu.tick(cpu_cycles);
        }

        // Frame counter (approximate)
        self.frame_cycles += cpu_cycles;
        if (self.frame_cycles >= 7457) {
            self.frame_cycles -= 7457;
            self.apu.tickFrameCounter();
        }

        self.cycles += cpu_cycles;
        return cpu_cycles;
    }

    /// Execute one frame
    pub fn frame(self: *NES) void {
        const start_frame = self.ppu.frame;
        while (self.ppu.frame == start_frame) {
            _ = self.step();
        }
    }

    /// Set controller input
    pub fn setInput(self: *NES, buttons: u8) void {
        // NES button order: A, B, Select, Start, Up, Down, Left, Right
        self.mmu.controller1 = buttons;
    }

    /// Get RAM for observations
    pub fn getRam(self: *NES) []const u8 {
        return &self.mmu.ram;
    }

    /// Get frame buffer
    pub fn getFrameBuffer(self: *NES) *const [SCREEN_WIDTH * SCREEN_HEIGHT]u32 {
        return &self.ppu.frame_buffer;
    }

    /// Read memory
    pub fn read(self: *NES, addr: u16) u8 {
        return self.mmu.read(addr);
    }

    /// Write memory
    pub fn write(self: *NES, addr: u16, val: u8) void {
        self.mmu.write(addr, val);
    }

    /// Get audio samples
    pub fn getAudioSamples(self: *NES, out: []i16) usize {
        return self.apu.readSamples(out);
    }

    /// Get save data (PRG RAM)
    pub fn getSaveData(self: *NES) []const u8 {
        return &self.mmu.prg_ram;
    }

    /// Load save data
    pub fn loadSaveData(self: *NES, data: []const u8) void {
        const len = @min(data.len, self.mmu.prg_ram.len);
        @memcpy(self.mmu.prg_ram[0..len], data[0..len]);
    }

    /// Save state
    pub fn saveState(self: *NES) SaveState {
        return SaveState{
            .cpu = .{
                .a = self.cpu.a,
                .x = self.cpu.x,
                .y = self.cpu.y,
                .sp = self.cpu.sp,
                .pc = self.cpu.pc,
                .status = @bitCast(self.cpu.status),
            },
            .ppu = .{
                .ctrl = self.ppu.ctrl,
                .mask = self.ppu.mask,
                .status = self.ppu.status,
                .oam_addr = self.ppu.oam_addr,
                .v = self.ppu.v,
                .t = self.ppu.t,
                .x = self.ppu.x,
                .w = @intFromBool(self.ppu.w),
                .scanline = self.ppu.scanline,
                .cycle = self.ppu.cycle,
            },
            .ram = self.mmu.ram,
            .vram = self.ppu.vram,
            .palette = self.ppu.palette,
            .oam = self.ppu.oam,
            .prg_ram = self.mmu.prg_ram,
        };
    }

    /// Load state
    pub fn loadState(self: *NES, state: SaveState) void {
        self.cpu.a = state.cpu.a;
        self.cpu.x = state.cpu.x;
        self.cpu.y = state.cpu.y;
        self.cpu.sp = state.cpu.sp;
        self.cpu.pc = state.cpu.pc;
        self.cpu.status = @bitCast(state.cpu.status);

        self.ppu.ctrl = state.ppu.ctrl;
        self.ppu.mask = state.ppu.mask;
        self.ppu.status = state.ppu.status;
        self.ppu.oam_addr = state.ppu.oam_addr;
        self.ppu.v = @truncate(state.ppu.v);
        self.ppu.t = @truncate(state.ppu.t);
        self.ppu.x = @truncate(state.ppu.x);
        self.ppu.w = state.ppu.w != 0;
        self.ppu.scanline = state.ppu.scanline;
        self.ppu.cycle = state.ppu.cycle;

        self.mmu.ram = state.ram;
        self.ppu.vram = state.vram;
        self.ppu.palette = state.palette;
        self.ppu.oam = state.oam;
        self.mmu.prg_ram = state.prg_ram;
    }
};
