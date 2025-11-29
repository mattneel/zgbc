//! SMS VDP (Video Display Processor)
//! TMS9918-derivative, 256x192 or 256x224 resolution.

pub const VDP = struct {
    // Registers
    regs: [11]u8 = [_]u8{0} ** 11,

    // Memory
    vram: [16384]u8 = [_]u8{0} ** 16384,
    cram: [32]u8 = [_]u8{0} ** 32, // Color RAM (palette)

    // Internal state
    addr: u14 = 0,
    code: u2 = 0,
    read_buffer: u8 = 0,
    latch: bool = false,
    latch_byte: u8 = 0,

    // Counters
    scanline: u16 = 0,
    cycle: u16 = 0,
    v_counter: u8 = 0,
    h_counter: u8 = 0,
    line_counter: u8 = 0,

    // Status
    status: u8 = 0,
    irq_pending: bool = false,
    frame: u64 = 0,

    // Output
    frame_buffer: [256 * 240]u32 = [_]u32{0} ** (256 * 240),

    // Screen dimensions (SMS: 256x192 or 256x224)
    screen_height: u16 = 192,

    pub const SCREEN_WIDTH = 256;

    pub fn tick(self: *VDP, cycles: u8) void {
        // VDP runs at master clock (3x CPU rate)
        // 228 CPU cycles = 684 master cycles = 1 scanline
        const vdp_cycles = @as(u16, cycles) * 3;
        for (0..vdp_cycles) |_| {
            self.tickCycle();
        }
    }

    fn tickCycle(self: *VDP) void {
        // SMS VDP timing: 684 master cycles per line, 262 lines per frame (NTSC)
        self.cycle += 1;
        if (self.cycle >= 684) {
            self.cycle = 0;
            self.scanline += 1;

            if (self.scanline < self.screen_height) {
                self.renderLine(@intCast(self.scanline));
            }

            // V counter (NTSC 192-line mode)
            // Scanlines 0-218: V = scanline
            // Scanlines 219-261: V = scanline - 6 (jumps from 0xDA to 0xD5)
            if (self.scanline < 0xDB) {
                self.v_counter = @intCast(self.scanline);
            } else if (self.scanline < 262) {
                self.v_counter = @intCast(self.scanline - 6);
            } else {
                self.v_counter = 0; // About to wrap
            }

            // Line interrupt
            if (self.scanline <= self.screen_height) {
                if (self.line_counter == 0) {
                    self.line_counter = self.regs[10];
                    if (self.regs[0] & 0x10 != 0) {
                        self.irq_pending = true;
                    }
                } else {
                    self.line_counter -%= 1;
                }
            } else {
                self.line_counter = self.regs[10];
            }

            // Frame interrupt
            if (self.scanline == self.screen_height + 1) {
                self.status |= 0x80; // VBlank flag
                if (self.regs[1] & 0x20 != 0) {
                    self.irq_pending = true;
                }
            }

            if (self.scanline >= 262) {
                self.scanline = 0;
                self.frame += 1;
            }
        }

        // H counter (approximate)
        self.h_counter = @intCast((self.cycle >> 1) & 0xFF);
    }

    fn renderLine(self: *VDP, y: u16) void {
        if (y >= self.screen_height) return;

        // Display enable check
        if (self.regs[1] & 0x40 == 0) {
            const backdrop = self.cramToRgb(self.cram[16 + (self.regs[7] & 0x0F)]);
            for (0..256) |x| {
                self.frame_buffer[y * 256 + x] = backdrop;
            }
            return;
        }

        // Render background
        const scroll_x = self.regs[8];
        const scroll_y = self.regs[9];
        const disable_x_scroll_top = self.regs[0] & 0x40 != 0 and y < 16;
        const disable_y_scroll_right = self.regs[0] & 0x80 != 0;

        for (0..256) |px| {
            const x: u16 = @intCast(px);

            // Apply scroll (SMS subtracts scroll from position)
            var tx = x;
            var ty = y;
            if (!disable_x_scroll_top) {
                tx = (x -% scroll_x) & 0xFF;
            }
            if (!(disable_y_scroll_right and x >= 192)) {
                ty = (y +% scroll_y) % 224;
            }

            const color = self.getBgPixel(tx, ty);
            self.frame_buffer[y * 256 + x] = self.cramToRgb(self.cram[color]);
        }

        // Render sprites over background
        self.renderSprites(y);

        // Left column blank
        if (self.regs[0] & 0x20 != 0) {
            const backdrop = self.cramToRgb(self.cram[16 + (self.regs[7] & 0x0F)]);
            for (0..8) |x| {
                self.frame_buffer[y * 256 + x] = backdrop;
            }
        }
    }

    fn getBgPixel(self: *VDP, x: u16, y: u16) u8 {
        const tile_x = x / 8;
        const tile_y = y / 8;
        const fine_x: u3 = @intCast(x % 8);
        const fine_y: u3 = @intCast(y % 8);

        // Name table base (mode 4: 0x3800 for 192 lines, 0x3700 for 224)
        const nt_base: u14 = if (self.screen_height == 224) 0x3700 else 0x3800;
        const nt_addr = nt_base + @as(u14, @intCast(tile_y)) * 64 + @as(u14, @intCast(tile_x)) * 2;

        const entry_lo = self.vram[nt_addr];
        const entry_hi = self.vram[nt_addr + 1];

        const tile_idx: u16 = @as(u16, entry_lo) | (@as(u16, entry_hi & 0x01) << 8);
        const palette: u1 = @intCast((entry_hi >> 3) & 1);
        const flip_h = entry_hi & 0x02 != 0;
        const flip_v = entry_hi & 0x04 != 0;
        const priority = entry_hi & 0x10 != 0;
        _ = priority; // TODO: sprite priority

        const fy: u3 = if (flip_v) 7 - fine_y else fine_y;
        const fx: u3 = if (flip_h) fine_x else 7 - fine_x;

        // Tiles are 32 bytes each (4 bitplanes interleaved)
        const tile_addr: u14 = @intCast(tile_idx * 32 + @as(u16, fy) * 4);

        const b0 = self.vram[tile_addr];
        const b1 = self.vram[tile_addr + 1];
        const b2 = self.vram[tile_addr + 2];
        const b3 = self.vram[tile_addr + 3];

        const color_idx: u4 = @truncate(((b0 >> fx) & 1) |
            (((b1 >> fx) & 1) << 1) |
            (((b2 >> fx) & 1) << 2) |
            (((b3 >> fx) & 1) << 3));

        return @as(u8, palette) * 16 + color_idx;
    }

    fn renderSprites(self: *VDP, y: u16) void {
        const sprite_height: u8 = if (self.regs[1] & 0x02 != 0) 16 else 8;
        const double = self.regs[1] & 0x01 != 0;
        const sat_base: u14 = @as(u14, self.regs[5] & 0x7E) << 7;
        var sprites_on_line: u8 = 0;

        for (0..64) |i| {
            const sprite_y = self.vram[sat_base + i];
            if (sprite_y == 0xD0 and self.screen_height == 192) break; // End marker

            const sy: i16 = @as(i16, sprite_y) + 1;
            if (y < sy or y >= sy + sprite_height) continue;

            sprites_on_line += 1;
            if (sprites_on_line > 8) {
                self.status |= 0x40; // Overflow
                break;
            }

            const sprite_x = self.vram[sat_base + 128 + i * 2];
            const tile_idx = self.vram[sat_base + 128 + i * 2 + 1];

            var row: u8 = @intCast(y - @as(u16, @intCast(sy)));
            if (double) row >>= 1;

            const actual_tile: u8 = if (sprite_height == 16)
                (tile_idx & 0xFE) + (if (row >= 8) @as(u8, 1) else 0)
            else
                tile_idx;

            const pattern_base: u14 = if (self.regs[6] & 0x04 != 0) 0x2000 else 0;
            const tile_addr = pattern_base + @as(u14, actual_tile) * 32 + @as(u14, row & 7) * 4;

            const b0 = self.vram[tile_addr];
            const b1 = self.vram[tile_addr + 1];
            const b2 = self.vram[tile_addr + 2];
            const b3 = self.vram[tile_addr + 3];

            var sx: i16 = sprite_x;
            if (self.regs[0] & 0x08 != 0) sx -= 8; // Shift left

            for (0..8) |px| {
                const screen_x = sx + @as(i16, @intCast(px));
                if (screen_x < 0 or screen_x >= 256) continue;

                const bit: u3 = @intCast(7 - px);
                const color_idx: u4 = @truncate(((b0 >> bit) & 1) |
                    (((b1 >> bit) & 1) << 1) |
                    (((b2 >> bit) & 1) << 2) |
                    (((b3 >> bit) & 1) << 3));

                if (color_idx != 0) {
                    // Check collision with existing sprite pixel
                    // (simplified - not tracking previous sprite pixels)
                    const color: u8 = 16 + @as(u8, color_idx); // Sprite palette
                    self.frame_buffer[y * 256 + @as(usize, @intCast(screen_x))] = self.cramToRgb(self.cram[color]);
                }
            }
        }
    }

    // Control port write (I/O port $BF)
    pub fn writeControl(self: *VDP, val: u8) void {
        if (!self.latch) {
            self.latch_byte = val;
            self.latch = true;
        } else {
            self.latch = false;
            self.code = @intCast(val >> 6);
            self.addr = (@as(u14, val & 0x3F) << 8) | self.latch_byte;

            switch (self.code) {
                0 => {
                    // Read mode - prefetch
                    self.read_buffer = self.vram[self.addr];
                    self.addr +%= 1;
                },
                2 => {
                    // Register write
                    const reg = val & 0x0F;
                    if (reg < self.regs.len) {
                        self.regs[reg] = self.latch_byte;
                        // Update screen height based on mode
                        if (reg == 0 or reg == 1) {
                            self.updateScreenHeight();
                        }
                    }
                },
                else => {},
            }
        }
    }

    // Data port read (I/O port $BE)
    pub fn readData(self: *VDP) u8 {
        self.latch = false;
        const val = self.read_buffer;
        self.read_buffer = self.vram[self.addr];
        self.addr +%= 1;
        return val;
    }

    // Data port write (I/O port $BE)
    pub fn writeData(self: *VDP, val: u8) void {
        self.latch = false;
        if (self.code == 3) {
            // CRAM write
            self.cram[self.addr & 0x1F] = val;
        } else {
            // VRAM write
            self.vram[self.addr] = val;
        }
        self.addr +%= 1;
    }

    // Status register read (I/O port $BF)
    pub fn readStatus(self: *VDP) u8 {
        self.latch = false;
        const val = self.status;
        self.status &= 0x1F; // Clear interrupt flags
        self.irq_pending = false;
        return val;
    }

    fn updateScreenHeight(self: *VDP) void {
        // Mode 4 with M1/M3 for 224-line mode
        if (self.regs[0] & 0x06 == 0x06 and self.regs[1] & 0x18 == 0x10) {
            self.screen_height = 224;
        } else {
            self.screen_height = 192;
        }
    }

    fn cramToRgb(self: *VDP, cram: u8) u32 {
        _ = self;
        // SMS: --BBGGRR (2 bits per channel, scale to 8 bits)
        const r = (cram & 0x03) * 85;
        const g = ((cram >> 2) & 0x03) * 85;
        const b = ((cram >> 4) & 0x03) * 85;
        // ABGR format for browser
        return 0xFF000000 | (@as(u32, b) << 16) | (@as(u32, g) << 8) | r;
    }
};
