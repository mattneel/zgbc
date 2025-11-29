//! NES Memory Management Unit
//! Handles CPU memory map and cartridge interface.

const std = @import("std");
const PPU = @import("ppu.zig").PPU;
const APU = @import("apu.zig").APU;
const Mapper = @import("mapper.zig").Mapper;

pub const MMU = struct {
    // Internal RAM (2KB, mirrored 4x to fill 0x0000-0x1FFF)
    ram: [2048]u8 = [_]u8{0} ** 2048,

    // Cartridge RAM (8KB, battery-backed on some carts)
    prg_ram: [8192]u8 = [_]u8{0} ** 8192,

    // ROM data (set by loadRom)
    prg_rom: []const u8 = &.{},
    chr_rom: []const u8 = &.{},

    // Mapper
    mapper: Mapper = .{ .nrom = .{} },

    // Component references (set during init)
    ppu: ?*PPU = null,
    apu: ?*APU = null,

    // Controller state
    controller1: u8 = 0,
    controller2: u8 = 0,
    controller1_shift: u8 = 0,
    controller2_shift: u8 = 0,
    strobe: bool = false,

    // DMA
    dma_page: u8 = 0,
    dma_pending: bool = false,

    /// CPU read
    pub fn read(self: *MMU, addr: u16) u8 {
        return switch (addr) {
            0x0000...0x1FFF => self.ram[addr & 0x07FF],
            0x2000...0x3FFF => if (self.ppu) |ppu| ppu.readRegister(@truncate(addr & 7)) else 0,
            0x4000...0x4013 => 0, // APU registers (write-only mostly)
            0x4014 => 0, // OAM DMA (write-only)
            0x4015 => if (self.apu) |apu| apu.readStatus() else 0,
            0x4016 => self.readController1(),
            0x4017 => self.readController2(),
            0x4018...0x401F => 0, // Test mode registers
            0x4020...0x5FFF => 0, // Expansion ROM
            0x6000...0x7FFF => self.prg_ram[addr - 0x6000],
            0x8000...0xFFFF => self.mapper.readPrg(self.prg_rom, addr),
        };
    }

    /// CPU write
    pub fn write(self: *MMU, addr: u16, val: u8) void {
        switch (addr) {
            0x0000...0x1FFF => self.ram[addr & 0x07FF] = val,
            0x2000...0x3FFF => if (self.ppu) |ppu| ppu.writeRegister(@truncate(addr & 7), val),
            0x4000...0x4013 => if (self.apu) |apu| apu.writeRegister(addr, val),
            0x4014 => {
                self.dma_page = val;
                self.dma_pending = true;
            },
            0x4015 => if (self.apu) |apu| apu.writeStatus(val),
            0x4016 => self.writeController(val),
            0x4017 => if (self.apu) |apu| apu.writeFrameCounter(val),
            0x4018...0x401F => {}, // Test mode registers
            0x4020...0x5FFF => {}, // Expansion ROM
            0x6000...0x7FFF => self.prg_ram[addr - 0x6000] = val,
            0x8000...0xFFFF => self.mapper.write(addr, val),
        }
    }

    fn readController1(self: *MMU) u8 {
        if (self.strobe) {
            return self.controller1 & 1;
        }
        const bit = self.controller1_shift & 1;
        self.controller1_shift >>= 1;
        self.controller1_shift |= 0x80; // Open bus
        return bit;
    }

    fn readController2(self: *MMU) u8 {
        if (self.strobe) {
            return self.controller2 & 1;
        }
        const bit = self.controller2_shift & 1;
        self.controller2_shift >>= 1;
        self.controller2_shift |= 0x80;
        return bit;
    }

    fn writeController(self: *MMU, val: u8) void {
        self.strobe = val & 1 != 0;
        if (self.strobe) {
            self.controller1_shift = self.controller1;
            self.controller2_shift = self.controller2;
        }
    }

    /// Perform OAM DMA transfer
    pub fn performDma(self: *MMU, ppu: *PPU) void {
        const base: u16 = @as(u16, self.dma_page) << 8;
        for (0..256) |i| {
            const addr = base + @as(u16, @intCast(i));
            const val = self.read(addr);
            ppu.oam[i] = val;
        }
        self.dma_pending = false;
    }

    /// Load iNES ROM
    pub fn loadRom(self: *MMU, data: []const u8) void {
        if (data.len < 16) return;

        // Parse iNES header
        if (data[0] != 'N' or data[1] != 'E' or data[2] != 'S' or data[3] != 0x1A) {
            return;
        }

        const prg_banks = data[4];
        const chr_banks = data[5];
        const flags6 = data[6];
        const flags7 = data[7];

        const mapper_num = (flags7 & 0xF0) | (flags6 >> 4);
        const has_trainer = flags6 & 0x04 != 0;

        var offset: usize = 16;
        if (has_trainer) offset += 512;

        const prg_size = @as(usize, prg_banks) * 16384;
        const chr_size = @as(usize, chr_banks) * 8192;

        if (offset + prg_size <= data.len) {
            self.prg_rom = data[offset .. offset + prg_size];
        }

        offset += prg_size;
        if (chr_size > 0 and offset + chr_size <= data.len) {
            self.chr_rom = data[offset .. offset + chr_size];
        }

        // Select mapper
        self.mapper = switch (mapper_num) {
            0 => .{ .nrom = .{} },
            1 => .{ .mmc1 = .{} },
            2 => .{ .uxrom = .{} },
            4 => .{ .mmc3 = .{} },
            7 => .{ .axrom = .{} },
            else => .{ .nrom = .{} },
        };

        // Set mirroring
        if (self.ppu) |ppu| {
            ppu.mirroring = if (flags6 & 1 != 0) .vertical else .horizontal;
        }
    }
};
