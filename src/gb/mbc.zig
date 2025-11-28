//! Memory Bank Controllers
//! Handles ROM/RAM banking for cartridges.

const std = @import("std");

/// MBC save state data
pub const MBCSaveState = extern struct {
    rom_bank: u8,
    ram_bank: u8,
    ram_enabled: u8,
    mode: u8,
};

pub const MBC = union(enum) {
    none: void,
    mbc1: MBC1,
    mbc3: MBC3,

    pub fn readRom(self: *MBC, rom: []const u8, addr: u16) u8 {
        const bank: usize = switch (self.*) {
            .none => 1,
            .mbc1 => |m| @max(1, m.rom_bank & 0x1F),
            .mbc3 => |m| @max(1, m.rom_bank & 0x7F),
        };

        const rom_addr = (bank * 0x4000) + (addr - 0x4000);
        return if (rom_addr < rom.len) rom[rom_addr] else 0xFF;
    }

    pub fn readRam(self: *MBC, eram: *[8192]u8, addr: u16) u8 {
        return switch (self.*) {
            .none => 0xFF,
            .mbc1 => |m| blk: {
                if (!m.ram_enabled) break :blk 0xFF;
                const bank: usize = if (m.mode) m.ram_bank else 0;
                const ram_addr = (bank * 0x2000) + (addr - 0xA000);
                break :blk if (ram_addr < eram.len) eram[ram_addr] else 0xFF;
            },
            .mbc3 => |m| blk: {
                if (!m.ram_enabled) break :blk 0xFF;
                if (m.ram_bank >= 0x08) break :blk 0x00; // RTC registers (stubbed)
                const bank: usize = m.ram_bank & 0x03;
                const ram_addr = (bank * 0x2000) + (addr - 0xA000);
                break :blk if (ram_addr < eram.len) eram[ram_addr] else 0xFF;
            },
        };
    }

    pub fn writeRam(self: *MBC, eram: *[8192]u8, addr: u16, val: u8) void {
        switch (self.*) {
            .none => {},
            .mbc1 => |m| {
                if (!m.ram_enabled) return;
                const bank: usize = if (m.mode) m.ram_bank else 0;
                const ram_addr = (bank * 0x2000) + (addr - 0xA000);
                if (ram_addr < eram.len) eram[ram_addr] = val;
            },
            .mbc3 => |m| {
                if (!m.ram_enabled) return;
                if (m.ram_bank >= 0x08) return; // RTC registers (stubbed)
                const bank: usize = m.ram_bank & 0x03;
                const ram_addr = (bank * 0x2000) + (addr - 0xA000);
                if (ram_addr < eram.len) eram[ram_addr] = val;
            },
        }
    }

    pub fn writeRegister(self: *MBC, addr: u16, val: u8) void {
        switch (self.*) {
            .none => {},
            .mbc1 => |*m| {
                switch (addr) {
                    0x0000...0x1FFF => m.ram_enabled = (val & 0x0F) == 0x0A,
                    0x2000...0x3FFF => m.rom_bank = (m.rom_bank & 0x60) | (val & 0x1F),
                    0x4000...0x5FFF => {
                        if (m.mode) {
                            m.ram_bank = val & 0x03;
                        } else {
                            m.rom_bank = (m.rom_bank & 0x1F) | ((val & 0x03) << 5);
                        }
                    },
                    0x6000...0x7FFF => m.mode = (val & 0x01) != 0,
                    else => {},
                }
            },
            .mbc3 => |*m| {
                switch (addr) {
                    0x0000...0x1FFF => m.ram_enabled = (val & 0x0F) == 0x0A,
                    0x2000...0x3FFF => m.rom_bank = val & 0x7F,
                    0x4000...0x5FFF => m.ram_bank = val,
                    0x6000...0x7FFF => {}, // RTC latch (stubbed)
                    else => {},
                }
            },
        }
    }

    /// Export MBC state for save states
    pub fn toSaveState(self: *const MBC) MBCSaveState {
        return switch (self.*) {
            .none => .{ .rom_bank = 1, .ram_bank = 0, .ram_enabled = 0, .mode = 0 },
            .mbc1 => |m| .{
                .rom_bank = m.rom_bank,
                .ram_bank = m.ram_bank,
                .ram_enabled = @intFromBool(m.ram_enabled),
                .mode = @intFromBool(m.mode),
            },
            .mbc3 => |m| .{
                .rom_bank = m.rom_bank,
                .ram_bank = m.ram_bank,
                .ram_enabled = @intFromBool(m.ram_enabled),
                .mode = 0,
            },
        };
    }

    /// Restore MBC state from save state
    pub fn fromSaveState(self: *MBC, state: MBCSaveState) void {
        switch (self.*) {
            .none => {},
            .mbc1 => |*m| {
                m.rom_bank = state.rom_bank;
                m.ram_bank = state.ram_bank;
                m.ram_enabled = state.ram_enabled != 0;
                m.mode = state.mode != 0;
            },
            .mbc3 => |*m| {
                m.rom_bank = state.rom_bank;
                m.ram_bank = state.ram_bank;
                m.ram_enabled = state.ram_enabled != 0;
            },
        }
    }
};

pub const MBC1 = struct {
    rom_bank: u8 = 1,
    ram_bank: u8 = 0,
    ram_enabled: bool = false,
    mode: bool = false, // false = 16Mbit ROM/8KB RAM, true = 4Mbit ROM/32KB RAM
};

pub const MBC3 = struct {
    rom_bank: u8 = 1,
    ram_bank: u8 = 0,
    ram_enabled: bool = false,
    // RTC registers (stubbed for now)
};
