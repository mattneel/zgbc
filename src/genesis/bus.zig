//! Sega Genesis Bus
//! Handles memory mapping for both 68000 and Z80.

const VDP = @import("vdp.zig").VDP;
const YM2612 = @import("ym2612.zig").YM2612;
const PSG = @import("psg.zig").PSG;
const Z80 = @import("z80.zig").CPU;

const Controller = struct {
    buttons: u8 = 0,
    ctrl: u8 = 0,
    th_latch: bool = true,

    fn init() Controller {
        return .{};
    }

    fn isPressed(self: *const Controller, bit: u3) bool {
        return (self.buttons & (@as(u8, 1) << bit)) != 0;
    }

    pub fn readData(self: *Controller) u8 {
        var data: u8 = 0x3F;

        if (self.th_latch) {
            if (self.isPressed(6)) data &= ~@as(u8, 0x20); // C
            if (self.isPressed(5)) data &= ~@as(u8, 0x10); // B
            if (self.isPressed(3)) data &= ~@as(u8, 0x08); // Right
            if (self.isPressed(2)) data &= ~@as(u8, 0x04); // Left
            if (self.isPressed(1)) data &= ~@as(u8, 0x02); // Down
            if (self.isPressed(0)) data &= ~@as(u8, 0x01); // Up
        } else {
            if (self.isPressed(7)) data &= ~@as(u8, 0x20); // Start
            if (self.isPressed(4)) data &= ~@as(u8, 0x10); // A
            if (self.isPressed(1)) data &= ~@as(u8, 0x02); // Down
            if (self.isPressed(0)) data &= ~@as(u8, 0x01); // Up
        }

        var result: u8 = 0x80; // TR high
        if (self.th_latch) result |= 0x40;
        result |= data;
        return result;
    }

    pub fn readCtrl(self: *const Controller) u8 {
        return self.ctrl;
    }

    pub fn writeData(self: *Controller, val: u8) void {
        if (self.ctrl & 0x40 != 0) {
            self.th_latch = val & 0x40 != 0;
        }
    }

    pub fn writeCtrl(self: *Controller, val: u8) void {
        self.ctrl = val;
        if (self.ctrl & 0x40 == 0) {
            // When TH configured as input, force latch high
            self.th_latch = true;
        }
    }

    pub fn setButtons(self: *Controller, mask: u8) void {
        self.buttons = mask;
    }
};

pub const Bus = struct {
    // 68K RAM (64KB)
    ram: [65536]u8 = [_]u8{0} ** 65536,

    // Z80 RAM (8KB)
    z80_ram: [8192]u8 = [_]u8{0} ** 8192,

    // ROM
    rom: []const u8 = &.{},

    // SRAM (battery backup)
    sram: [65536]u8 = [_]u8{0} ** 65536,
    sram_enabled: bool = false,

    // Hardware
    vdp: *VDP = undefined,
    ym2612: *YM2612 = undefined,
    psg: *PSG = undefined,
    z80: *Z80 = undefined,

    // Z80 bus control
    z80_busreq: bool = false,
    z80_reset: bool = true,
    z80_bank: u16 = 0,

    // Controller state
    controllers: [2]Controller = .{ Controller.init(), Controller.init() },

    // Debug
    debug_traced_stack: bool = false,

    // =========================================================================
    // 68000 Bus Interface (active address lines A23-A1)
    // =========================================================================

    pub fn read8(self: *Bus, addr: u32) u8 {
        const a = addr & 0xFFFFFF;

        return switch (a >> 16) {
            0x00...0x3F => self.readRom8(a), // ROM
            0x40...0x7F => if (self.sram_enabled) self.sram[a & 0xFFFF] else self.readRom8(a),
            0xA0...0xA0 => self.readZ80Space(a),
            0xA1 => self.readIO(a),
            0xC0...0xDF => self.readVDP(a),
            0xE0...0xFF => self.ram[a & 0xFFFF],
            else => 0xFF,
        };
    }

    pub fn read16(self: *Bus, addr: u32) u16 {
        const a = addr & 0xFFFFFE;
        return (@as(u16, self.read8(a)) << 8) | self.read8(a + 1);
    }

    pub fn read32(self: *Bus, addr: u32) u32 {
        const hi = self.read16(addr);
        const lo = self.read16(addr + 2);
        return (@as(u32, hi) << 16) | lo;
    }

    pub fn write8(self: *Bus, addr: u32, val: u8) void {
        const a = addr & 0xFFFFFF;
        switch (a >> 16) {
            0x00...0x3F => {}, // ROM (ignore)
            0x40...0x7F => if (self.sram_enabled) {
                self.sram[a & 0xFFFF] = val;
            },
            0xA0...0xA0 => self.writeZ80Space(a, val),
            0xA1 => self.writeIO(a, val),
            0xC0...0xDF => self.writeVDP(a, val),
            0xE0...0xFF => self.ram[a & 0xFFFF] = val,
            else => {},
        }
    }

    pub fn write16(self: *Bus, addr: u32, val: u16) void {
        const a = addr & 0xFFFFFE;

        // VDP data/control are word-oriented
        if ((a >= 0xC00000 and a < 0xE00000)) {
            self.writeVDP16(a, val);
            return;
        }

        self.write8(a, @truncate(val >> 8));
        self.write8(a + 1, @truncate(val));
    }

    pub fn write32(self: *Bus, addr: u32, val: u32) void {
        self.write16(addr, @truncate(val >> 16));
        self.write16(addr + 2, @truncate(val));
    }

    fn readRom8(self: *Bus, addr: u32) u8 {
        if (addr < self.rom.len) return self.rom[addr];
        return 0xFF;
    }

    fn readZ80Space(self: *Bus, addr: u32) u8 {
        const a = addr & 0xFFFF;
        if (a < 0x2000) {
            return self.z80_ram[a];
        }
        if (a >= 0x4000 and a < 0x4004) {
            return self.ym2612.readStatus();
        }
        return 0xFF;
    }

    fn writeZ80Space(self: *Bus, addr: u32, val: u8) void {
        const a = addr & 0xFFFF;
        if (a < 0x2000) {
            self.z80_ram[a] = val;
        } else if (a >= 0x4000 and a < 0x4004) {
            const port: u1 = @truncate((a >> 1) & 1);
            if (a & 1 == 0) {
                self.ym2612.writeAddr(port, val);
            } else {
                self.ym2612.writeData(port, val);
            }
        } else if (a >= 0x6000 and a < 0x6100) {
            self.z80_bank = @as(u16, val) & 0x01FF;
        } else if (a >= 0x7F00 and a < 0x7F20) {
            self.psg.write(val);
        }
    }

    fn readIO(self: *Bus, addr: u32) u8 {
        const a = addr & 0xFF;

        return switch (a) {
            0x00 => 0xA0, // Version (overseas, NTSC, no expansion)
            0x01 => self.controllers[0].readData(),
            0x02 => self.controllers[1].readData(),
            0x04 => self.controllers[0].readCtrl(),
            0x05 => self.controllers[1].readCtrl(),
            0x03, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F => 0xFF,
            else => 0xFF,
        };
    }

    fn writeIO(self: *Bus, addr: u32, val: u8) void {
        const a = addr & 0xFF;

        switch (a) {
            0x01 => self.controllers[0].writeData(val),
            0x02 => self.controllers[1].writeData(val),
            0x04 => self.controllers[0].writeCtrl(val),
            0x05 => self.controllers[1].writeCtrl(val),
            0x00 => {
                // Z80 bus request
                if (val & 0x01 != 0) {
                    self.z80_busreq = true;
                } else {
                    self.z80_busreq = false;
                }
            },
            0x10...0x12 => {
                // PSG
                self.psg.write(val);
            },
            0x20 => {
                // Z80 reset
                self.z80_reset = val & 0x01 == 0;
                if (val & 0x01 != 0) {
                    self.z80.pc = 0;
                    self.z80.halted = false;
                }
            },
            else => {},
        }
    }

    fn readVDP(self: *Bus, addr: u32) u8 {
        const a = addr & 0x1F;

        return switch (a) {
            0x00...0x03 => @truncate(self.vdp.readData() >> (@as(u4, @truncate(1 - (a & 1))) * 8)),
            0x04...0x07 => @truncate(self.vdp.readStatus() >> (@as(u4, @truncate(1 - (a & 1))) * 8)),
            0x08...0x0F => @truncate(self.vdp.readHV() >> (@as(u4, @truncate(1 - (a & 1))) * 8)),
            0x10...0x17 => 0xFF, // PSG (write only)
            else => 0xFF,
        };
    }

    fn writeVDP(self: *Bus, addr: u32, val: u8) void {
        const a = addr & 0x1F;

        switch (a) {
            0x11, 0x13, 0x15, 0x17 => self.psg.write(val),
            else => {},
        }
    }

    fn writeVDP16(self: *Bus, addr: u32, val: u16) void {
        const a = addr & 0x1E;

        switch (a) {
            0x00, 0x02 => self.vdp.writeData(val),
            0x04, 0x06 => self.vdp.writeControl(val),
            0x10, 0x12, 0x14, 0x16 => self.psg.write(@truncate(val)),
            else => {},
        }
    }

    // =========================================================================
    // Z80 Bus Interface
    // =========================================================================

    pub fn z80Read(self: *Bus, addr: u16) u8 {
        return switch (addr) {
            0x0000...0x1FFF => self.z80_ram[addr],
            0x2000...0x3FFF => self.z80_ram[addr & 0x1FFF], // Mirror
            0x4000...0x4003 => self.ym2612.readStatus(),
            0x6000...0x60FF => 0xFF, // Bank register (write only)
            0x7F00...0x7F1F => 0xFF, // VDP/PSG
            0x8000...0xFFFF => blk: {
                // 68K ROM/RAM access via bank register
                const bank_addr = (@as(u32, self.z80_bank) << 15) | (addr & 0x7FFF);
                break :blk self.read8(bank_addr);
            },
            else => 0xFF,
        };
    }

    pub fn z80Write(self: *Bus, addr: u16, val: u8) void {
        switch (addr) {
            0x0000...0x1FFF => self.z80_ram[addr] = val,
            0x2000...0x3FFF => self.z80_ram[addr & 0x1FFF] = val,
            0x4000 => self.ym2612.writeAddr(0, val),
            0x4001 => self.ym2612.writeData(0, val),
            0x4002 => self.ym2612.writeAddr(1, val),
            0x4003 => self.ym2612.writeData(1, val),
            0x6000...0x60FF => {
                self.z80_bank = @as(u16, val) & 0x01FF;
            },
            0x7F00...0x7F1F => self.psg.write(val),
            0x8000...0xFFFF => {
                const bank_addr = (@as(u32, self.z80_bank) << 15) | (addr & 0x7FFF);
                self.write8(bank_addr, val);
            },
            else => {},
        }
    }

    pub fn z80IoRead(self: *Bus, port: u8) u8 {
        _ = self;
        _ = port;
        return 0xFF;
    }

    pub fn z80IoWrite(self: *Bus, port: u8, val: u8) void {
        _ = self;
        _ = port;
        _ = val;
    }

    // Z80 bus interface wrapper (for compatibility with SMS Z80)
    pub fn read(self: *Bus, addr: u16) u8 {
        return self.z80Read(addr);
    }

    pub fn write(self: *Bus, addr: u16, val: u8) void {
        self.z80Write(addr, val);
    }

    pub fn ioRead(self: *Bus, port: u8) u8 {
        return self.z80IoRead(port);
    }

    pub fn ioWrite(self: *Bus, port: u8, val: u8) void {
        self.z80IoWrite(port, val);
    }

    // =========================================================================
    // ROM Loading
    // =========================================================================

    pub fn loadRom(self: *Bus, rom: []const u8) void {
        self.rom = rom;

        // Check for SRAM in ROM header
        if (rom.len >= 0x1B2) {
            // Check for "RA" SRAM flag at $1B0
            if (rom[0x1B0] == 'R' and rom[0x1B1] == 'A') {
                self.sram_enabled = true;
            }
        }
    }

    pub fn setControllerButtons(self: *Bus, port: usize, mask: u8) void {
        if (port < self.controllers.len) {
            self.controllers[port].setButtons(mask);
        }
    }
};
