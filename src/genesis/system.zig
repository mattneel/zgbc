//! Sega Genesis System
//! Top-level Genesis emulator state.

const std = @import("std");
const M68K = @import("cpu.zig").M68K;
const Z80 = @import("z80.zig").CPU;
const VDP = @import("vdp.zig").VDP;
const YM2612 = @import("ym2612.zig").YM2612;
const PSG = @import("psg.zig").PSG;
const Bus = @import("bus.zig").Bus;

pub const SCREEN_WIDTH = 320;
pub const SCREEN_HEIGHT = 224;

pub const Genesis = struct {
    m68k: M68K = .{},
    z80: Z80 = .{},
    vdp: VDP = .{},
    ym2612: YM2612 = .{},
    psg: PSG = .{},
    bus: Bus = .{},

    cycles: u64 = 0,

    pub fn init(self: *Genesis) void {
        self.bus.vdp = &self.vdp;
        self.bus.ym2612 = &self.ym2612;
        self.bus.psg = &self.psg;
        self.bus.z80 = &self.z80;
    }

    pub fn loadRom(self: *Genesis, rom: []const u8) void {
        self.init();
        self.bus.loadRom(rom);

        // Give VDP access to ROM and RAM for DMA
        self.vdp.dma_source = rom;
        self.vdp.dma_ram = &self.bus.ram;

        // Reset 68000
        self.m68k.reset(&self.bus);

        // Keep Z80 in reset initially
        self.bus.z80_reset = true;
        self.z80.pc = 0;
    }

    pub fn step(self: *Genesis) u32 {
        // Check VDP interrupts BEFORE CPU step so interrupt can be taken immediately
        if (self.vdp.vint_pending) {
            self.m68k.irq_level = 6; // V-Int is level 6
        } else if (self.vdp.hint_pending) {
            self.m68k.irq_level = 4; // H-Int is level 4
        } else {
            self.m68k.irq_level = 0;
        }

        // Run 68000
        const m68k_cycles = self.m68k.step(&self.bus);

        // Clear vint_pending if the interrupt was just taken
        // (CPU sets sr.i = 6 when taking level 6 interrupt, and cycles = 44)
        if (self.vdp.vint_pending and self.m68k.sr.i == 6 and m68k_cycles == 44) {
            self.vdp.vint_pending = false;
        }

        // Z80 runs at ~3.58 MHz (roughly half 68K speed)
        if (!self.bus.z80_busreq and !self.bus.z80_reset) {
            // Run Z80 for ~half the cycles
            var z80_cycles: u32 = m68k_cycles / 2;
            while (z80_cycles > 0) {
                const c = self.z80.step(&self.bus);
                if (c > z80_cycles) break;
                z80_cycles -= c;
            }
        }

        // VDP
        self.vdp.tick(m68k_cycles);

        // Audio
        self.ym2612.tick(m68k_cycles);
        self.psg.tick(@truncate(m68k_cycles));

        self.cycles += m68k_cycles;
        return m68k_cycles;
    }

    pub fn frame(self: *Genesis) void {
        const start_frame = self.vdp.frame;
        while (self.vdp.frame == start_frame) {
            _ = self.step();
        }
    }

    pub fn setInput(self: *Genesis, buttons: u8) void {
        // Genesis 3-button pad:
        // D-pad + A/B/C + Start
        self.bus.setControllerButtons(0, buttons);
    }

    pub fn getFrameBuffer(self: *Genesis) *const [SCREEN_WIDTH * SCREEN_HEIGHT]u32 {
        return self.vdp.frame_buffer[0 .. SCREEN_WIDTH * SCREEN_HEIGHT];
    }

    pub fn getAudioSamples(self: *Genesis, out: []i16) usize {
        // Mix YM2612 and PSG
        var ym_samples: [2048]i16 = undefined;
        var psg_samples: [2048]i16 = undefined;

        const ym_count = self.ym2612.readSamples(&ym_samples);
        const psg_count = self.psg.readSamples(&psg_samples);

        const count = @min(@min(ym_count, psg_count), out.len);

        for (0..count) |i| {
            // Mix with PSG at lower volume
            const mixed = @as(i32, ym_samples[i]) + @divTrunc(@as(i32, psg_samples[i]), 2);
            out[i] = @truncate(std.math.clamp(mixed, -32768, 32767));
        }

        return count;
    }

    pub fn getRam(self: *Genesis) []const u8 {
        return &self.bus.ram;
    }

    pub fn read(self: *Genesis, addr: u32) u8 {
        return self.bus.read8(addr);
    }

    pub fn write(self: *Genesis, addr: u32, val: u8) void {
        self.bus.write8(addr, val);
    }
};
