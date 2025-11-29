//! NES Cartridge Mappers
//! Handles ROM banking and other cartridge hardware.

const std = @import("std");
const PPU = @import("ppu.zig").PPU;

pub const Mapper = union(enum) {
    nrom: NROM,
    mmc1: MMC1,
    uxrom: UxROM,
    axrom: AxROM,
    mmc3: MMC3,

    pub fn readPrg(self: *Mapper, prg: []const u8, addr: u16) u8 {
        return switch (self.*) {
            .nrom => |*m| m.readPrg(prg, addr),
            .mmc1 => |*m| m.readPrg(prg, addr),
            .uxrom => |*m| m.readPrg(prg, addr),
            .axrom => |*m| m.readPrg(prg, addr),
            .mmc3 => |*m| m.readPrg(prg, addr),
        };
    }

    pub fn write(self: *Mapper, addr: u16, val: u8) void {
        switch (self.*) {
            .nrom => {},
            .mmc1 => |*m| m.write(addr, val),
            .uxrom => |*m| m.write(addr, val),
            .axrom => |*m| m.write(addr, val),
            .mmc3 => |*m| m.write(addr, val),
        }
    }

    pub fn readChr(self: *Mapper, chr: []const u8, addr: u16) u8 {
        return switch (self.*) {
            .nrom => |*m| m.readChr(chr, addr),
            .mmc1 => |*m| m.readChr(chr, addr),
            .uxrom => |*m| m.readChr(chr, addr),
            .axrom => |*m| m.readChr(chr, addr),
            .mmc3 => |*m| m.readChr(chr, addr),
        };
    }

    /// Get mirroring mode (for mappers that control it)
    pub fn getMirroring(self: *Mapper) ?PPU.Mirroring {
        return switch (self.*) {
            .axrom => |m| if (m.mirroring == 0) .single0 else .single1,
            .mmc3 => |m| if (m.mirroring == 0) .vertical else .horizontal,
            else => null,
        };
    }

    /// Clock scanline counter (for MMC3 IRQ)
    pub fn clockScanline(self: *Mapper) void {
        switch (self.*) {
            .mmc3 => |*m| m.scanline(),
            else => {},
        }
    }

    /// Check if mapper has pending IRQ
    pub fn pollIrq(self: *Mapper) bool {
        return switch (self.*) {
            .mmc3 => |m| m.irq_pending,
            else => false,
        };
    }

    /// Acknowledge mapper IRQ
    pub fn acknowledgeIrq(self: *Mapper) void {
        switch (self.*) {
            .mmc3 => |*m| m.irq_pending = false,
            else => {},
        }
    }
};

/// NROM (Mapper 0) - No banking
/// Used by: Super Mario Bros, Donkey Kong, etc.
pub const NROM = struct {
    pub fn readPrg(self: *NROM, prg: []const u8, addr: u16) u8 {
        _ = self;
        if (prg.len == 0) return 0;
        const offset = addr - 0x8000;
        // Mirror 16KB to 32KB space if needed
        const actual = if (prg.len <= 0x4000)
            offset & 0x3FFF
        else
            offset;
        return if (actual < prg.len) prg[actual] else 0;
    }

    pub fn readChr(self: *NROM, chr: []const u8, addr: u16) u8 {
        _ = self;
        if (addr < chr.len) return chr[addr] else return 0;
    }
};

/// MMC1 (Mapper 1) - Nintendo's most common mapper
/// Used by: Zelda, Metroid, Final Fantasy, etc.
pub const MMC1 = struct {
    shift: u8 = 0x10,
    control: u8 = 0x0C,
    chr_bank0: u8 = 0,
    chr_bank1: u8 = 0,
    prg_bank: u8 = 0,

    pub fn readPrg(self: *MMC1, prg: []const u8, addr: u16) u8 {
        if (prg.len == 0) return 0;

        const prg_mode = (self.control >> 2) & 3;
        const bank_count = prg.len / 0x4000;

        var bank: usize = undefined;
        var offset: usize = undefined;

        switch (addr) {
            0x8000...0xBFFF => {
                offset = addr - 0x8000;
                bank = switch (prg_mode) {
                    0, 1 => (self.prg_bank & 0xFE), // 32KB mode
                    2 => 0, // Fixed first bank
                    3 => self.prg_bank & 0x0F, // Switchable
                    else => unreachable,
                };
            },
            0xC000...0xFFFF => {
                offset = addr - 0xC000;
                bank = switch (prg_mode) {
                    0, 1 => (self.prg_bank & 0xFE) | 1, // 32KB mode
                    2 => self.prg_bank & 0x0F, // Switchable
                    3 => bank_count - 1, // Fixed last bank
                    else => unreachable,
                };
            },
            else => return 0,
        }

        if (bank >= bank_count) bank = bank_count - 1;
        const final_addr = bank * 0x4000 + offset;
        return if (final_addr < prg.len) prg[final_addr] else 0;
    }

    pub fn readChr(self: *MMC1, chr: []const u8, addr: u16) u8 {
        if (chr.len == 0) return 0;
        const chr_mode = (self.control >> 4) & 1;

        var bank: usize = undefined;
        var offset: usize = undefined;

        if (chr_mode == 0) {
            // 8KB mode
            bank = (self.chr_bank0 & 0x1E);
            offset = addr;
        } else {
            // 4KB mode
            if (addr < 0x1000) {
                bank = self.chr_bank0;
                offset = addr;
            } else {
                bank = self.chr_bank1;
                offset = addr - 0x1000;
            }
        }

        const final_addr = @as(usize, bank) * 0x1000 + offset;
        return if (final_addr < chr.len) chr[final_addr] else 0;
    }

    pub fn write(self: *MMC1, addr: u16, val: u8) void {
        if (val & 0x80 != 0) {
            self.shift = 0x10;
            self.control |= 0x0C;
            return;
        }

        const complete = self.shift & 1 != 0;
        self.shift = (self.shift >> 1) | ((val & 1) << 4);

        if (complete) {
            const data = self.shift;
            self.shift = 0x10;

            switch (addr) {
                0x8000...0x9FFF => self.control = data,
                0xA000...0xBFFF => self.chr_bank0 = data,
                0xC000...0xDFFF => self.chr_bank1 = data,
                0xE000...0xFFFF => self.prg_bank = data,
                else => {},
            }
        }
    }
};

/// UxROM (Mapper 2) - Simple PRG switching
/// Used by: Mega Man, Castlevania, Contra, etc.
pub const UxROM = struct {
    bank: u8 = 0,

    pub fn readPrg(self: *UxROM, prg: []const u8, addr: u16) u8 {
        if (prg.len == 0) return 0;
        const bank_count = prg.len / 0x4000;

        const bank: usize = switch (addr) {
            0x8000...0xBFFF => self.bank,
            0xC000...0xFFFF => bank_count - 1, // Fixed last bank
            else => return 0,
        };

        const offset = addr & 0x3FFF;
        const final_addr = bank * 0x4000 + offset;
        return if (final_addr < prg.len) prg[final_addr] else 0;
    }

    pub fn readChr(self: *UxROM, chr: []const u8, addr: u16) u8 {
        _ = self;
        if (addr < chr.len) return chr[addr] else return 0;
    }

    pub fn write(self: *UxROM, addr: u16, val: u8) void {
        _ = addr;
        self.bank = val & 0x0F;
    }
};

/// AxROM (Mapper 7) - 32KB PRG switching + single-screen mirroring
/// Used by: Battletoads, Marble Madness, etc.
pub const AxROM = struct {
    bank: u8 = 0,
    mirroring: u1 = 0, // 0 = single-screen lower, 1 = single-screen upper

    pub fn readPrg(self: *AxROM, prg: []const u8, addr: u16) u8 {
        if (prg.len == 0) return 0;
        const bank_count = prg.len / 0x8000;

        // 32KB bank switching
        const bank: usize = self.bank & 0x07;
        const actual_bank = if (bank_count > 0) bank % bank_count else 0;
        const offset = addr - 0x8000;
        const final_addr = actual_bank * 0x8000 + offset;
        return if (final_addr < prg.len) prg[final_addr] else 0;
    }

    pub fn readChr(self: *AxROM, chr: []const u8, addr: u16) u8 {
        _ = self;
        // AxROM uses CHR RAM
        if (addr < chr.len) return chr[addr] else return 0;
    }

    pub fn write(self: *AxROM, addr: u16, val: u8) void {
        _ = addr;
        self.bank = val & 0x07;
        self.mirroring = @truncate((val >> 4) & 1);
    }
};

/// MMC3 (Mapper 4) - Complex mapper with IRQ
/// Used by: SMB3, Kirby's Adventure, etc.
pub const MMC3 = struct {
    bank_select: u8 = 0,
    banks: [8]u8 = [_]u8{0} ** 8,
    mirroring: u8 = 0,
    prg_ram_protect: u8 = 0,
    irq_latch: u8 = 0,
    irq_counter: u8 = 0,
    irq_reload: bool = false,
    irq_enabled: bool = false,
    irq_pending: bool = false,

    pub fn readPrg(self: *MMC3, prg: []const u8, addr: u16) u8 {
        if (prg.len == 0) return 0;
        const bank_count = prg.len / 0x2000;
        const prg_mode = (self.bank_select >> 6) & 1;

        const bank: usize = switch (addr) {
            0x8000...0x9FFF => if (prg_mode == 0) self.banks[6] else bank_count - 2,
            0xA000...0xBFFF => self.banks[7],
            0xC000...0xDFFF => if (prg_mode == 0) bank_count - 2 else self.banks[6],
            0xE000...0xFFFF => bank_count - 1,
            else => return 0,
        };

        const offset = addr & 0x1FFF;
        const actual_bank = bank % bank_count;
        const final_addr = actual_bank * 0x2000 + offset;
        return if (final_addr < prg.len) prg[final_addr] else 0;
    }

    pub fn readChr(self: *MMC3, chr: []const u8, addr: u16) u8 {
        if (chr.len == 0) return 0;
        const chr_mode = (self.bank_select >> 7) & 1;

        const bank: usize = if (chr_mode == 0) {
            switch (addr) {
                0x0000...0x03FF => self.banks[0] & 0xFE,
                0x0400...0x07FF => self.banks[0] | 1,
                0x0800...0x0BFF => self.banks[1] & 0xFE,
                0x0C00...0x0FFF => self.banks[1] | 1,
                0x1000...0x13FF => self.banks[2],
                0x1400...0x17FF => self.banks[3],
                0x1800...0x1BFF => self.banks[4],
                0x1C00...0x1FFF => self.banks[5],
                else => 0,
            }
        } else {
            switch (addr) {
                0x0000...0x03FF => self.banks[2],
                0x0400...0x07FF => self.banks[3],
                0x0800...0x0BFF => self.banks[4],
                0x0C00...0x0FFF => self.banks[5],
                0x1000...0x13FF => self.banks[0] & 0xFE,
                0x1400...0x17FF => self.banks[0] | 1,
                0x1800...0x1BFF => self.banks[1] & 0xFE,
                0x1C00...0x1FFF => self.banks[1] | 1,
                else => 0,
            }
        };

        const offset = addr & 0x03FF;
        const final_addr = @as(usize, bank) * 0x0400 + offset;
        return if (final_addr < chr.len) chr[final_addr] else 0;
    }

    pub fn write(self: *MMC3, addr: u16, val: u8) void {
        switch (addr) {
            0x8000...0x9FFF => {
                if (addr & 1 == 0) {
                    self.bank_select = val;
                } else {
                    const reg = self.bank_select & 7;
                    self.banks[reg] = val;
                }
            },
            0xA000...0xBFFF => {
                if (addr & 1 == 0) {
                    self.mirroring = val & 1;
                } else {
                    self.prg_ram_protect = val;
                }
            },
            0xC000...0xDFFF => {
                if (addr & 1 == 0) {
                    self.irq_latch = val;
                } else {
                    self.irq_reload = true;
                }
            },
            0xE000...0xFFFF => {
                if (addr & 1 == 0) {
                    self.irq_enabled = false;
                    self.irq_pending = false;
                } else {
                    self.irq_enabled = true;
                }
            },
            else => {},
        }
    }

    pub fn scanline(self: *MMC3) void {
        if (self.irq_counter == 0 or self.irq_reload) {
            self.irq_counter = self.irq_latch;
            self.irq_reload = false;
        } else {
            self.irq_counter -= 1;
        }

        if (self.irq_counter == 0 and self.irq_enabled) {
            self.irq_pending = true;
        }
    }
};
