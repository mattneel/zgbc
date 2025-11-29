//! SMS Bus (Memory and I/O)
//! Handles memory mapping and I/O ports.

const VDP = @import("vdp.zig").VDP;
const PSG = @import("psg.zig").PSG;

pub const Bus = struct {
    // RAM
    ram: [8192]u8 = [_]u8{0} ** 8192,

    // ROM
    rom: []const u8 = &.{},

    // Cartridge RAM (for battery saves)
    cart_ram: [32768]u8 = [_]u8{0} ** 32768,
    cart_ram_enabled: bool = false,

    // Peripherals
    vdp: *VDP = undefined,
    psg: *PSG = undefined,

    // Memory mapping (SEGA mapper)
    mapper: [4]u8 = .{ 0, 0, 1, 2 },
    mapper_ctrl: u8 = 0,

    // Controller state (directly active low)
    joypad1: u8 = 0xFF,
    joypad2: u8 = 0xFF,

    // I/O control
    io_ctrl: u8 = 0,

    pub fn read(self: *Bus, addr: u16) u8 {
        return switch (addr) {
            0x0000...0x03FF => {
                // First 1KB is always from ROM page 0
                return if (addr < self.rom.len) self.rom[addr] else 0xFF;
            },
            0x0400...0x3FFF => self.readMapped(0, addr),
            0x4000...0x7FFF => self.readMapped(1, addr - 0x4000),
            0x8000...0xBFFF => {
                // Slot 2 can be cart RAM
                if (self.cart_ram_enabled and self.mapper_ctrl & 0x08 != 0) {
                    return self.cart_ram[(addr - 0x8000) + @as(u16, self.mapper_ctrl & 0x04) * 0x1000];
                }
                return self.readMapped(2, addr - 0x8000);
            },
            0xC000...0xDFFF => self.ram[addr - 0xC000],
            0xE000...0xFFFF => self.ram[addr - 0xE000], // Mirror
        };
    }

    pub fn write(self: *Bus, addr: u16, val: u8) void {
        switch (addr) {
            0x0000...0x7FFF => {
                // ROM area - writes go to mapper if cart RAM enabled
                if (self.cart_ram_enabled and addr >= 0x8000) {
                    // Would be slot 2
                }
            },
            0x8000...0xBFFF => {
                if (self.cart_ram_enabled and self.mapper_ctrl & 0x08 != 0) {
                    self.cart_ram[(addr - 0x8000) + @as(u16, self.mapper_ctrl & 0x04) * 0x1000] = val;
                }
            },
            0xC000...0xDFFF => self.ram[addr - 0xC000] = val,
            0xE000...0xFFFF => {
                self.ram[addr - 0xE000] = val;
                // Mapper registers at top of RAM mirror
                switch (addr) {
                    0xFFFC => self.mapper_ctrl = val,
                    0xFFFD => self.mapper[1] = val,
                    0xFFFE => self.mapper[2] = val,
                    0xFFFF => self.mapper[3] = val,
                    else => {},
                }
            },
        }
    }

    fn readMapped(self: *Bus, slot: u2, offset: u16) u8 {
        const bank: u32 = self.mapper[@as(usize, slot) + 1];
        const rom_addr = bank * 0x4000 + offset;
        if (rom_addr < self.rom.len) {
            return self.rom[rom_addr];
        }
        return 0xFF;
    }

    pub fn ioRead(self: *Bus, port: u8) u8 {
        // SMS I/O ports are active on A0 and A6-A7
        return switch (port & 0xC1) {
            0x00 => 0xFF, // Unused
            0x40 => self.vdp.v_counter, // V counter
            0x41 => self.vdp.h_counter, // H counter
            0x80 => self.vdp.readData(), // VDP data
            0x81 => self.vdp.readStatus(), // VDP status
            0xC0 => self.readJoypad1(), // Joypad 1
            0xC1 => self.readJoypad2(), // Joypad 2 + misc
            else => 0xFF,
        };
    }

    pub fn ioWrite(self: *Bus, port: u8, val: u8) void {
        switch (port & 0xC1) {
            0x00 => {}, // Memory control (ignore)
            0x01 => self.io_ctrl = val, // I/O control
            0x40, 0x41 => self.psg.write(val), // PSG
            0x80 => self.vdp.writeData(val), // VDP data
            0x81 => self.vdp.writeControl(val), // VDP control
            else => {},
        }
    }

    fn readJoypad1(self: *Bus) u8 {
        // Bits: Up, Down, Left, Right, B1, B2 (active low)
        return self.joypad1;
    }

    fn readJoypad2(self: *Bus) u8 {
        // Bits 0-5: Joypad 2
        // Bit 6: Reset button
        // Bit 7: Cartridge slot select (active low)
        return (self.joypad2 & 0x3F) | 0xC0;
    }

    pub fn loadRom(self: *Bus, data: []const u8) void {
        self.rom = data;

        // Reset mapper
        self.mapper = .{ 0, 0, 1, 2 };
        self.mapper_ctrl = 0;

        // Check for ROM header and cart RAM
        if (data.len >= 0x8000) {
            // Check TMR SEGA header
            const header_offset: usize = if (data.len > 0x8000) 0x7FF0 else 0x3FF0;
            if (header_offset + 16 <= data.len) {
                // Could check "TMR SEGA" signature here
                // For now, assume cart RAM might be used
                self.cart_ram_enabled = true;
            }
        }
    }
};
