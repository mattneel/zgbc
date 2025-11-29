//! NES PPU (2C02)
//! Picture Processing Unit - handles all graphics rendering.

const std = @import("std");

pub const PPU = struct {
    // Registers
    ctrl: u8 = 0, // $2000 PPUCTRL
    mask: u8 = 0, // $2001 PPUMASK
    status: u8 = 0, // $2002 PPUSTATUS
    oam_addr: u8 = 0, // $2003 OAMADDR

    // Internal registers
    v: u15 = 0, // Current VRAM address
    t: u15 = 0, // Temporary VRAM address
    x: u3 = 0, // Fine X scroll
    w: bool = false, // Write toggle

    // Data buffer for $2007 reads
    data_buffer: u8 = 0,

    // Memory
    vram: [2048]u8 = [_]u8{0} ** 2048, // 2 nametables
    palette: [32]u8 = [_]u8{0} ** 32,
    oam: [256]u8 = [_]u8{0} ** 256,

    // Secondary OAM for sprite evaluation
    secondary_oam: [32]u8 = [_]u8{0xFF} ** 32,
    sprite_count: u8 = 0,
    sprite_zero_on_line: bool = false,

    // CHR ROM/RAM reference
    chr: []const u8 = &.{},
    chr_ram: [8192]u8 = [_]u8{0} ** 8192,
    use_chr_ram: bool = false,

    // Mirroring mode
    mirroring: Mirroring = .horizontal,

    // Timing
    scanline: i16 = 0,
    cycle: u16 = 0,
    frame: u64 = 0,
    odd_frame: bool = false,

    // Captured scroll state at start of each scanline (for rendering)
    scanline_coarse_x: u5 = 0,
    scanline_fine_y: u3 = 0,
    scanline_coarse_y: u5 = 0,
    scanline_nt: u2 = 0,

    // Output
    frame_buffer: [256 * 240]u32 = [_]u32{0} ** (256 * 240),

    // Flags
    nmi_pending: bool = false,
    suppress_nmi: bool = false,

    pub const Mirroring = enum { horizontal, vertical, single0, single1, four_screen };

    pub fn tick(self: *PPU) void {
        // Pre-render scanline
        if (self.scanline == -1) {
            if (self.cycle == 1) {
                self.status &= 0x1F; // Clear VBlank, sprite 0, overflow
                self.nmi_pending = false;
            }
            if (self.cycle >= 280 and self.cycle <= 304 and self.renderingEnabled()) {
                self.copyVertical();
            }
        }

        // Visible scanlines
        if (self.scanline >= 0 and self.scanline < 240) {
            // Capture scroll state at start of visible portion
            if (self.cycle == 0) {
                self.captureScrollState();
            }
            if (self.cycle >= 1 and self.cycle <= 256) {
                self.renderPixel();
            }
            if (self.cycle == 256 and self.renderingEnabled()) {
                self.incrementY();
            }
            if (self.cycle == 257 and self.renderingEnabled()) {
                self.copyHorizontal();
            }
        }

        // VBlank start
        if (self.scanline == 241 and self.cycle == 1) {
            self.status |= 0x80;
            if (self.ctrl & 0x80 != 0 and !self.suppress_nmi) {
                self.nmi_pending = true;
            }
        }

        // Advance timing
        self.cycle += 1;
        if (self.cycle > 340) {
            self.cycle = 0;
            self.scanline += 1;
            if (self.scanline > 260) {
                self.scanline = -1;
                self.frame += 1;
                self.odd_frame = !self.odd_frame;
                // Skip cycle 0 on odd frames when rendering enabled
                if (self.odd_frame and self.renderingEnabled()) {
                    self.cycle = 1;
                }
            }
        }
        self.suppress_nmi = false;
    }

    fn renderingEnabled(self: *PPU) bool {
        return self.mask & 0x18 != 0;
    }

    fn captureScrollState(self: *PPU) void {
        // Capture scroll position from v register at start of scanline
        self.scanline_coarse_x = @truncate(self.v & 0x1F);
        self.scanline_coarse_y = @truncate((self.v >> 5) & 0x1F);
        self.scanline_nt = @truncate((self.v >> 10) & 0x03);
        self.scanline_fine_y = @truncate(self.v >> 12);
    }

    fn renderPixel(self: *PPU) void {
        const px = self.cycle - 1;
        const py: u16 = @intCast(self.scanline);

        var bg_color: u8 = 0;
        var bg_opaque = false;

        // Background
        if (self.mask & 0x08 != 0 and (self.mask & 0x02 != 0 or px >= 8)) {
            // Calculate total X position: base scroll + pixel position
            // fine_x (3 bits) + coarse_x*8 (8 bits) + px gives total X
            const total_x: u16 = @as(u16, self.x) + @as(u16, self.scanline_coarse_x) * 8 + px;

            // Fine X is the low 3 bits of total position
            const fine_x: u3 = @truncate(total_x);
            // Coarse X is bits 3-7 (0-31), wrapping within nametable pair
            const coarse_x: u5 = @truncate(total_x >> 3);
            // Nametable X bit flips when coarse_x overflows from 31 to 0
            const nt_x: u1 = @truncate((total_x >> 8) & 1);
            const nt_select = (self.scanline_nt & 0x02) | (((self.scanline_nt & 1) ^ nt_x));

            const fine_y = self.scanline_fine_y;
            const coarse_y = self.scanline_coarse_y;

            const nt_addr = 0x2000 | (@as(u16, nt_select) << 10) | (@as(u16, coarse_y) << 5) | coarse_x;
            const tile_idx = self.readVram(nt_addr);

            const pattern_base: u16 = if (self.ctrl & 0x10 != 0) 0x1000 else 0;
            const pattern_addr = pattern_base + @as(u16, tile_idx) * 16 + fine_y;

            const lo = self.readChr(pattern_addr);
            const hi = self.readChr(pattern_addr + 8);

            const bit: u3 = 7 - fine_x;
            const color_idx = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);

            if (color_idx != 0) {
                const attr_addr = 0x23C0 | (@as(u16, nt_select) << 10) | ((@as(u16, coarse_y) >> 2) << 3) | (@as(u16, coarse_x) >> 2);
                const attr = self.readVram(attr_addr);
                const shift: u3 = @truncate(((coarse_y & 2) << 1) | (coarse_x & 2));
                const palette_idx = (attr >> shift) & 0x03;

                bg_color = self.palette[@as(usize, palette_idx) * 4 + color_idx];
                bg_opaque = true;
            }
        }

        // Sprites
        var sprite_color: u8 = 0;
        var sprite_priority = false;
        var sprite_zero = false;

        if (self.mask & 0x10 != 0 and (self.mask & 0x04 != 0 or px >= 8)) {
            const sprite_height: u8 = if (self.ctrl & 0x20 != 0) 16 else 8;

            for (0..self.sprite_count) |i| {
                const base = i * 4;
                const sprite_x = self.secondary_oam[base + 3];
                if (px < sprite_x or px >= sprite_x + 8) continue;

                const sprite_y = self.secondary_oam[base];
                const tile = self.secondary_oam[base + 1];
                const attr = self.secondary_oam[base + 2];

                var row: u8 = @intCast(py -| sprite_y -| 1);
                if (attr & 0x80 != 0) row = sprite_height - 1 - row; // Flip V

                var col: u8 = @intCast(px - sprite_x);
                if (attr & 0x40 != 0) col = 7 - col; // Flip H

                const pattern_base: u16 = if (sprite_height == 16)
                    (@as(u16, tile & 1) << 12) | (@as(u16, tile & 0xFE) << 4)
                else if (self.ctrl & 0x08 != 0)
                    0x1000
                else
                    0;

                const actual_tile: u16 = if (sprite_height == 16)
                    if (row >= 8) (tile | 1) else (tile & 0xFE)
                else
                    tile;

                const pattern_addr = pattern_base + actual_tile * 16 + (row & 7);
                const lo = self.readChr(pattern_addr);
                const hi = self.readChr(pattern_addr + 8);

                const bit: u3 = @intCast(7 - col);
                const color_idx = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);

                if (color_idx != 0) {
                    sprite_color = self.palette[16 + @as(usize, attr & 3) * 4 + color_idx];
                    sprite_priority = attr & 0x20 != 0;
                    sprite_zero = i == 0 and self.sprite_zero_on_line;
                    break;
                }
            }
        }

        // Sprite 0 hit
        if (sprite_zero and bg_opaque and px < 255) {
            self.status |= 0x40;
        }

        // Priority
        var final_color: u8 = self.palette[0];
        if (sprite_color != 0 and (!sprite_priority or !bg_opaque)) {
            final_color = sprite_color;
        } else if (bg_opaque) {
            final_color = bg_color;
        }

        self.frame_buffer[py * 256 + px] = NES_PALETTE[final_color & 0x3F];
    }

    fn readChr(self: *PPU, addr: u16) u8 {
        if (self.use_chr_ram) {
            return self.chr_ram[addr & 0x1FFF];
        }
        return if (addr < self.chr.len) self.chr[addr] else 0;
    }

    fn readVram(self: *PPU, addr: u16) u8 {
        const mirrored = self.mirrorVramAddr(addr);
        return self.vram[mirrored];
    }

    fn writeVram(self: *PPU, addr: u16, val: u8) void {
        const mirrored = self.mirrorVramAddr(addr);
        self.vram[mirrored] = val;
    }

    fn mirrorVramAddr(self: *PPU, addr: u16) u16 {
        const a = addr & 0x0FFF;
        return switch (self.mirroring) {
            .horizontal => (a & 0x3FF) | (if (a >= 0x800) @as(u16, 0x400) else 0),
            .vertical => a & 0x7FF,
            .single0 => a & 0x3FF,
            .single1 => (a & 0x3FF) | 0x400,
            .four_screen => a,
        };
    }

    fn incrementX(self: *PPU) void {
        // Increment coarse X, wrapping and switching nametable
        if ((self.v & 0x001F) == 31) {
            self.v &= ~@as(u15, 0x001F); // Clear coarse X
            self.v ^= 0x0400; // Switch horizontal nametable
        } else {
            self.v += 1;
        }
    }

    fn incrementY(self: *PPU) void {
        if ((self.v & 0x7000) != 0x7000) {
            self.v += 0x1000;
        } else {
            self.v &= 0x0FFF;
            var y = (self.v & 0x03E0) >> 5;
            if (y == 29) {
                y = 0;
                self.v ^= 0x0800;
            } else if (y == 31) {
                y = 0;
            } else {
                y += 1;
            }
            self.v = (self.v & 0x7C1F) | @as(u15, @intCast(y << 5));
        }
    }

    fn copyHorizontal(self: *PPU) void {
        self.v = (self.v & 0x7BE0) | (self.t & 0x041F);
    }

    fn copyVertical(self: *PPU) void {
        self.v = (self.v & 0x041F) | (self.t & 0x7BE0);
    }

    /// Evaluate sprites for next scanline
    pub fn evaluateSprites(self: *PPU) void {
        self.sprite_count = 0;
        @memset(&self.secondary_oam, 0xFF);
        self.sprite_zero_on_line = false;

        const sprite_height: i16 = if (self.ctrl & 0x20 != 0) 16 else 8;
        const next_scanline = self.scanline + 1;

        for (0..64) |i| {
            const y: i16 = self.oam[i * 4];
            if (next_scanline >= y + 1 and next_scanline < y + 1 + sprite_height) {
                if (self.sprite_count < 8) {
                    const dst = self.sprite_count * 4;
                    self.secondary_oam[dst] = self.oam[i * 4];
                    self.secondary_oam[dst + 1] = self.oam[i * 4 + 1];
                    self.secondary_oam[dst + 2] = self.oam[i * 4 + 2];
                    self.secondary_oam[dst + 3] = self.oam[i * 4 + 3];
                    if (i == 0) self.sprite_zero_on_line = true;
                    self.sprite_count += 1;
                } else {
                    self.status |= 0x20; // Sprite overflow
                    break;
                }
            }
        }
    }

    pub fn readRegister(self: *PPU, reg: u3) u8 {
        return switch (reg) {
            2 => { // PPUSTATUS
                const val = self.status;
                self.status &= 0x7F;
                self.w = false;
                if (self.scanline == 241 and self.cycle < 3) {
                    self.suppress_nmi = true;
                }
                return val;
            },
            4 => self.oam[self.oam_addr], // OAMDATA
            7 => { // PPUDATA
                var val = self.data_buffer;
                const addr = self.v & 0x3FFF;
                if (addr >= 0x3F00) {
                    val = self.palette[addr & 0x1F];
                    self.data_buffer = self.readVram(addr - 0x1000);
                } else {
                    self.data_buffer = if (addr < 0x2000) self.readChr(addr) else self.readVram(addr);
                }
                self.v +%= if (self.ctrl & 0x04 != 0) 32 else 1;
                return val;
            },
            else => 0,
        };
    }

    pub fn writeRegister(self: *PPU, reg: u3, val: u8) void {
        switch (reg) {
            0 => { // PPUCTRL
                const was_nmi = self.ctrl & 0x80 != 0;
                self.ctrl = val;
                self.t = (self.t & 0x73FF) | (@as(u15, val & 3) << 10);
                if (!was_nmi and val & 0x80 != 0 and self.status & 0x80 != 0) {
                    self.nmi_pending = true;
                }
            },
            1 => self.mask = val,
            3 => self.oam_addr = val,
            4 => {
                self.oam[self.oam_addr] = val;
                self.oam_addr +%= 1;
            },
            5 => { // PPUSCROLL
                if (!self.w) {
                    self.t = (self.t & 0x7FE0) | (val >> 3);
                    self.x = @truncate(val);
                } else {
                    self.t = (self.t & 0x0C1F) | (@as(u15, val & 0x07) << 12) | (@as(u15, val >> 3) << 5);
                }
                self.w = !self.w;
            },
            6 => { // PPUADDR
                if (!self.w) {
                    self.t = (self.t & 0x00FF) | (@as(u15, val & 0x3F) << 8);
                } else {
                    self.t = (self.t & 0x7F00) | val;
                    self.v = self.t;
                }
                self.w = !self.w;
            },
            7 => { // PPUDATA
                const addr = self.v & 0x3FFF;
                if (addr >= 0x3F00) {
                    var idx = addr & 0x1F;
                    if (idx & 3 == 0) idx &= 0x0F; // Mirror $3F10/$3F14/$3F18/$3F1C
                    self.palette[idx] = val;
                } else if (addr < 0x2000) {
                    if (self.use_chr_ram) self.chr_ram[addr] = val;
                } else {
                    self.writeVram(addr, val);
                }
                self.v +%= if (self.ctrl & 0x04 != 0) 32 else 1;
            },
            else => {},
        }
    }
};

// NES RGB palette (2C02) - ABGR format for little-endian browser ImageData
const NES_PALETTE = [64]u32{
    0xFF666666, 0xFF882A00, 0xFFA71214, 0xFFA4003B, 0xFF7E005C, 0xFF40006E, 0xFF00066C, 0xFF001D56,
    0xFF003533, 0xFF00480B, 0xFF005200, 0xFF084F00, 0xFF4D4000, 0xFF000000, 0xFF000000, 0xFF000000,
    0xFFADADAD, 0xFFD95F15, 0xFFFF4042, 0xFFFE2775, 0xFFCC1AA0, 0xFF7B1EB7, 0xFF2031B5, 0xFF004E99,
    0xFF006D6B, 0xFF008738, 0xFF00930C, 0xFF328F00, 0xFF8D7C00, 0xFF000000, 0xFF000000, 0xFF000000,
    0xFFFFFEFF, 0xFFFFB064, 0xFFFF9092, 0xFFFF76C6, 0xFFFF6AF3, 0xFFCC6EFE, 0xFF7081FE, 0xFF229EEA,
    0xFF00BEBC, 0xFF00D888, 0xFF30E45C, 0xFF82E045, 0xFFDECD48, 0xFF4F4F4F, 0xFF000000, 0xFF000000,
    0xFFFFFEFF, 0xFFFFDFC0, 0xFFFFD2D3, 0xFFFFC8E8, 0xFFFFC2FB, 0xFFEAC4FE, 0xFFC5CCFE, 0xFFA5D8F7,
    0xFF94E5E4, 0xFF96EFCF, 0xFFABF4BD, 0xFFCCF3B3, 0xFFF2EBB5, 0xFFB8B8B8, 0xFF000000, 0xFF000000,
};
