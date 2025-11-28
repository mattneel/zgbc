//! Memory Management Unit
//! Handles memory mapping and I/O registers.

const std = @import("std");
const MBC = @import("mbc.zig").MBC;

pub const MMU = struct {
    rom: []const u8 = &.{},
    wram: [8192]u8 = [_]u8{0} ** 8192, // C000-DFFF
    hram: [127]u8 = [_]u8{0} ** 127, // FF80-FFFE
    eram: [8192]u8 = [_]u8{0} ** 8192, // External RAM (8KB, enough for Pokemon)
    vram: [8192]u8 = [_]u8{0} ** 8192, // 8000-9FFF
    oam: [160]u8 = [_]u8{0} ** 160, // FE00-FE9F

    // I/O registers
    ie: u8 = 0, // FFFF - Interrupt Enable
    if_: u8 = 0, // FF0F - Interrupt Flags
    joypad_select: u8 = 0, // FF00 - Joypad register
    joypad_state: u8 = 0xFF, // Current button state (active low)

    // Serial (for Blargg test output)
    serial_data: u8 = 0, // FF01 - SB
    serial_control: u8 = 0, // FF02 - SC
    serial_pending: bool = false,

    // Timer registers
    div_counter: u16 = 0, // Internal counter, upper 8 bits = DIV
    tima: u8 = 0, // FF05
    tma: u8 = 0, // FF06
    tac: u8 = 0, // FF07

    // LCD registers
    lcdc: u8 = 0x91, // FF40 - LCD Control (enabled after boot)
    stat: u8 = 0x85, // FF41 - LCD Status
    scy: u8 = 0, // FF42 - Scroll Y
    scx: u8 = 0, // FF43 - Scroll X
    ly: u8 = 0, // FF44 - Current scanline (0-153)
    lyc: u8 = 0, // FF45 - LY Compare
    dma: u8 = 0xFF, // FF46 - DMA Transfer
    bgp: u8 = 0xFC, // FF47 - BG Palette
    obp0: u8 = 0, // FF48 - OBJ Palette 0
    obp1: u8 = 0, // FF49 - OBJ Palette 1
    wy: u8 = 0, // FF4A - Window Y
    wx: u8 = 0, // FF4B - Window X

    // PPU timing
    scanline_counter: u16 = 0, // Cycles within current scanline

    mbc: MBC = .none,

    pub fn read(self: *MMU, addr: u16) u8 {
        return switch (addr) {
            // ROM Bank 0 (fixed)
            0x0000...0x3FFF => if (addr < self.rom.len) self.rom[addr] else 0xFF,

            // ROM Bank 1-N (switchable)
            0x4000...0x7FFF => self.mbc.readRom(self.rom, addr),

            // VRAM
            0x8000...0x9FFF => self.vram[addr - 0x8000],

            // External RAM
            0xA000...0xBFFF => self.mbc.readRam(&self.eram, addr),

            // WRAM Bank 0
            0xC000...0xCFFF => self.wram[addr - 0xC000],

            // WRAM Bank 1
            0xD000...0xDFFF => self.wram[addr - 0xC000],

            // Echo RAM (mirror of C000-DDFF)
            0xE000...0xFDFF => self.wram[addr - 0xE000],

            // OAM
            0xFE00...0xFE9F => self.oam[addr - 0xFE00],

            // Unusable
            0xFEA0...0xFEFF => 0xFF,

            // I/O Registers
            0xFF00 => self.readJoypad(),
            0xFF01 => self.serial_data,
            0xFF02 => self.serial_control,
            0xFF04 => @truncate(self.div_counter >> 8), // DIV
            0xFF05 => self.tima,
            0xFF06 => self.tma,
            0xFF07 => self.tac,
            0xFF0F => self.if_,

            // Audio registers - not emulated
            0xFF10...0xFF3F => 0xFF,

            // LCD registers
            0xFF40 => self.lcdc,
            0xFF41 => self.stat | 0x80, // Bit 7 always reads 1
            0xFF42 => self.scy,
            0xFF43 => self.scx,
            0xFF44 => self.ly,
            0xFF45 => self.lyc,
            0xFF46 => self.dma,
            0xFF47 => self.bgp,
            0xFF48 => self.obp0,
            0xFF49 => self.obp1,
            0xFF4A => self.wy,
            0xFF4B => self.wx,

            // Other I/O
            0xFF03, 0xFF08...0xFF0E, 0xFF4C...0xFF7F => 0xFF,

            // HRAM
            0xFF80...0xFFFE => self.hram[addr - 0xFF80],

            // IE
            0xFFFF => self.ie,
        };
    }

    pub fn write(self: *MMU, addr: u16, val: u8) void {
        switch (addr) {
            // ROM area - MBC register writes
            0x0000...0x7FFF => self.mbc.writeRegister(addr, val),

            // VRAM
            0x8000...0x9FFF => self.vram[addr - 0x8000] = val,

            // External RAM
            0xA000...0xBFFF => self.mbc.writeRam(&self.eram, addr, val),

            // WRAM Bank 0
            0xC000...0xCFFF => self.wram[addr - 0xC000] = val,

            // WRAM Bank 1
            0xD000...0xDFFF => self.wram[addr - 0xC000] = val,

            // Echo RAM
            0xE000...0xFDFF => self.wram[addr - 0xE000] = val,

            // OAM
            0xFE00...0xFE9F => self.oam[addr - 0xFE00] = val,

            // Unusable
            0xFEA0...0xFEFF => {},

            // I/O Registers
            0xFF00 => self.joypad_select = val & 0x30,
            0xFF01 => self.serial_data = val,
            0xFF02 => {
                self.serial_control = val;
                // Transfer requested (bit 7 set)
                if (val & 0x80 != 0) {
                    self.serial_pending = true;
                }
            },
            0xFF04 => self.div_counter = 0, // Writing to DIV resets it
            0xFF05 => self.tima = val,
            0xFF06 => self.tma = val,
            0xFF07 => self.tac = val,
            0xFF0F => self.if_ = val,

            // Audio registers - not emulated
            0xFF10...0xFF3F => {},

            // LCD registers
            0xFF40 => self.lcdc = val,
            0xFF41 => self.stat = (self.stat & 0x07) | (val & 0x78), // Bits 0-2 read-only
            0xFF42 => self.scy = val,
            0xFF43 => self.scx = val,
            0xFF44 => {}, // LY is read-only
            0xFF45 => self.lyc = val,
            0xFF46 => {
                self.dma = val;
                // OAM DMA transfer (instant for simplicity)
                const src_base: u16 = @as(u16, val) << 8;
                for (0..160) |i| {
                    const src = src_base + @as(u16, @intCast(i));
                    self.oam[i] = self.read(src);
                }
            },
            0xFF47 => self.bgp = val,
            0xFF48 => self.obp0 = val,
            0xFF49 => self.obp1 = val,
            0xFF4A => self.wy = val,
            0xFF4B => self.wx = val,

            // Other I/O
            0xFF03, 0xFF08...0xFF0E, 0xFF4C...0xFF7F => {},

            // HRAM
            0xFF80...0xFFFE => self.hram[addr - 0xFF80] = val,

            // IE
            0xFFFF => self.ie = val,
        }
    }

    fn readJoypad(self: *MMU) u8 {
        var result: u8 = 0x0F; // Bits 0-3 high (no button pressed)

        if (self.joypad_select & 0x10 == 0) {
            // Direction buttons selected
            result &= (self.joypad_state >> 4) | 0xF0;
        }
        if (self.joypad_select & 0x20 == 0) {
            // Action buttons selected
            result &= self.joypad_state | 0xF0;
        }

        return (self.joypad_select & 0x30) | result;
    }

    /// Tick PPU by given cycles, update LY and trigger interrupts
    pub fn tickPpu(self: *MMU, cycles: u8) void {
        // Skip if LCD disabled
        if (self.lcdc & 0x80 == 0) return;

        self.scanline_counter += cycles;

        // 456 cycles per scanline
        if (self.scanline_counter >= 456) {
            self.scanline_counter -= 456;
            self.ly +%= 1;

            if (self.ly == 154) {
                self.ly = 0;
            }

            // V-blank interrupt at line 144
            if (self.ly == 144) {
                self.if_ |= 0x01; // V-blank interrupt
            }

            // LYC=LY check
            if (self.ly == self.lyc) {
                self.stat |= 0x04; // Set coincidence flag
                if (self.stat & 0x40 != 0) {
                    self.if_ |= 0x02; // STAT interrupt
                }
            } else {
                self.stat &= ~@as(u8, 0x04);
            }
        }

        // Update STAT mode bits (simplified)
        if (self.ly >= 144) {
            self.stat = (self.stat & 0xFC) | 1; // Mode 1: V-blank
        } else if (self.scanline_counter < 80) {
            self.stat = (self.stat & 0xFC) | 2; // Mode 2: OAM scan
        } else if (self.scanline_counter < 252) {
            self.stat = (self.stat & 0xFC) | 3; // Mode 3: Drawing
        } else {
            self.stat = (self.stat & 0xFC) | 0; // Mode 0: H-blank
        }
    }

    /// Load a ROM and detect MBC type
    pub fn loadRom(self: *MMU, rom: []const u8) !void {
        if (rom.len < 0x150) {
            return error.RomTooSmall;
        }

        self.rom = rom;

        // Detect MBC type from cartridge header (0x0147)
        const cart_type = rom[0x0147];
        self.mbc = switch (cart_type) {
            0x00 => .none,
            0x01, 0x02, 0x03 => .{ .mbc1 = .{} },
            0x0F, 0x10, 0x11, 0x12, 0x13 => .{ .mbc3 = .{} },
            else => {
                std.debug.print("Unknown cartridge type: 0x{X:0>2}\n", .{cart_type});
                return error.UnsupportedMBC;
            },
        };
    }
};

test "wram read/write" {
    var mmu = MMU{};
    mmu.write(0xC000, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), mmu.read(0xC000));
}

test "hram read/write" {
    var mmu = MMU{};
    mmu.write(0xFF80, 0x12);
    try std.testing.expectEqual(@as(u8, 0x12), mmu.read(0xFF80));
}
