//! Sega Genesis VDP (Video Display Processor)
//! 320x224 or 256x224 resolution, evolved from SMS VDP.

pub const VDP = struct {
    // Registers (24 total)
    regs: [24]u8 = [_]u8{0} ** 24,

    // Memory
    vram: [65536]u8 = [_]u8{0} ** 65536,
    cram: [128]u8 = [_]u8{0} ** 128, // 64 colors (9-bit, stored as 16-bit)
    vsram: [80]u8 = [_]u8{0} ** 80, // Vertical scroll

    // State
    addr: u16 = 0,
    code: u6 = 0,
    pending: bool = false,
    first_word: u16 = 0,
    read_buffer: u16 = 0,

    // Counters
    scanline: u16 = 0,
    hcounter: u16 = 0,
    vcounter: u8 = 0,

    // Status flags
    vblank_flag: bool = false,
    hblank_flag: bool = false,
    sprite_overflow: bool = false,
    sprite_collision: bool = false,

    // DMA
    dma_fill_pending: bool = false,
    dma_fill_data: u16 = 0,
    dma_source: []const u8 = &.{}, // ROM for DMA reads
    dma_ram: []const u8 = &.{}, // 68K RAM for DMA reads

    // Interrupts
    hint_counter: u8 = 0,
    hint_pending: bool = false,
    vint_pending: bool = false,

    // Frame tracking
    frame: u64 = 0,

    // Output (320x224 max)
    frame_buffer: [320 * 240]u32 = [_]u32{0} ** (320 * 240),

    // Priority buffer for sprite/plane priority
    priority_buffer: [320]u8 = [_]u8{0} ** 320,
    sprite_line_pixels: [320]bool = [_]bool{false} ** 320,

    // Debug counters
    debug_control_writes: u32 = 0,
    debug_data_writes: u32 = 0,
    debug_reg_writes: u32 = 0,
    debug_status_reads: u32 = 0,
    debug_vint_set: u32 = 0,

    pub const SCREEN_WIDTH = 320;
    pub const SCREEN_HEIGHT = 224;

    pub fn writeControl(self: *VDP, val: u16) void {
        self.debug_control_writes += 1;
        if (self.pending) {
            // Second word
            self.pending = false;
            self.code = @truncate(((val >> 2) & 0x3C) | (self.code & 0x03));
            self.addr = (self.first_word & 0x3FFF) | ((val & 0x03) << 14);

            // Check for DMA
            if (self.code & 0x20 != 0 and self.regs[1] & 0x10 != 0) {
                self.doDMA();
            }
        } else {
            // First word (or register write)
            if ((val & 0xC000) == 0x8000) {
                // Register write: 100R RRRR DDDD DDDD
                const reg: u5 = @truncate((val >> 8) & 0x1F);
                if (reg < self.regs.len) {
                    self.regs[reg] = @truncate(val);
                    self.debug_reg_writes += 1;
                }
                self.code = 0;
            } else {
                self.code = @truncate((self.code & 0x3C) | ((val >> 14) & 0x03));
                self.first_word = val;
                self.addr = val & 0x3FFF;
                self.pending = true;
            }
        }
    }

    pub fn writeData(self: *VDP, val: u16) void {
        self.pending = false;
        self.debug_data_writes += 1;

        // Handle DMA fill
        if (self.dma_fill_pending) {
            self.dma_fill_pending = false;
            self.dma_fill_data = val;
            self.doDMAFill();
            return;
        }

        const code_masked = self.code & 0x0F;
        switch (code_masked) {
            0x01 => { // VRAM write
                self.vram[self.addr & 0xFFFE] = @truncate(val >> 8);
                self.vram[(self.addr & 0xFFFE) | 1] = @truncate(val);
            },
            0x03 => { // CRAM write
                const cram_addr = (self.addr >> 1) & 0x3F;
                self.cram[cram_addr * 2] = @truncate(val);
                self.cram[cram_addr * 2 + 1] = @truncate(val >> 8);
            },
            0x05 => { // VSRAM write
                const vsram_addr = (self.addr >> 1) & 0x3F;
                if (vsram_addr * 2 + 1 < self.vsram.len) {
                    self.vsram[vsram_addr * 2] = @truncate(val);
                    self.vsram[vsram_addr * 2 + 1] = @truncate(val >> 8);
                }
            },
            else => {},
        }

        self.addr +%= self.regs[15];
    }

    pub fn readData(self: *VDP) u16 {
        self.pending = false;
        const result = self.read_buffer;

        switch (self.code & 0x0F) {
            0x00 => { // VRAM read
                self.read_buffer = (@as(u16, self.vram[self.addr & 0xFFFE]) << 8) |
                    self.vram[(self.addr & 0xFFFE) | 1];
            },
            0x04 => { // VSRAM read
                const vsram_addr = (self.addr >> 1) & 0x3F;
                if (vsram_addr * 2 + 1 < self.vsram.len) {
                    self.read_buffer = @as(u16, self.vsram[vsram_addr * 2]) |
                        (@as(u16, self.vsram[vsram_addr * 2 + 1]) << 8);
                }
            },
            0x08 => { // CRAM read
                const cram_addr = (self.addr >> 1) & 0x3F;
                self.read_buffer = @as(u16, self.cram[cram_addr * 2]) |
                    (@as(u16, self.cram[cram_addr * 2 + 1]) << 8);
            },
            else => {},
        }

        self.addr +%= self.regs[15];
        return result;
    }

    pub fn readStatus(self: *VDP) u16 {
        self.pending = false;
        self.debug_status_reads += 1;

        var status: u16 = 0x3400; // FIFO empty, DMA idle
        if (self.vint_pending) status |= 0x0080;
        if (self.sprite_overflow) status |= 0x0040;
        if (self.sprite_collision) status |= 0x0020;
        if (self.vblank_flag) status |= 0x0008;
        if (self.hblank_flag) status |= 0x0004;

        // Reading status clears interrupt + sprite flags per hardware behavior
        self.vint_pending = false;
        self.hint_pending = false;
        self.sprite_overflow = false;
        self.sprite_collision = false;

        return status;
    }

    pub fn readHV(self: *VDP) u16 {
        return (@as(u16, self.vcounter) << 8) | @as(u16, @truncate(self.hcounter >> 1));
    }

    fn doDMA(self: *VDP) void {
        const dma_mode = (self.regs[23] >> 6) & 3;

        switch (dma_mode) {
            0, 1 => self.doDMA68K(), // 68K to VRAM
            2 => self.dma_fill_pending = true, // VRAM fill (wait for data)
            else => self.doDMACopy(), // VRAM copy
        }
    }

    fn doDMA68K(self: *VDP) void {
        // DMA from 68K memory (ROM or RAM) to VRAM/CRAM/VSRAM
        var src: u32 = (@as(u32, self.regs[23] & 0x7F) << 17) |
            (@as(u32, self.regs[22]) << 9) |
            (@as(u32, self.regs[21]) << 1);
        var len: u32 = (@as(u32, self.regs[20]) << 8) | self.regs[19];
        if (len == 0) len = 0x10000;

        const dest_type = self.code & 0x07;

        while (len > 0) : (len -= 1) {
            // Read word from source (big endian)
            // Source can be ROM ($000000-$3FFFFF) or RAM ($E00000-$FFFFFF)
            var word: u16 = 0;
            if (src >= 0xE00000) {
                // Read from 68K RAM
                const ram_addr = src & 0xFFFF;
                if (ram_addr < self.dma_ram.len) {
                    word = (@as(u16, self.dma_ram[ram_addr]) << 8);
                    if (ram_addr + 1 < self.dma_ram.len) {
                        word |= self.dma_ram[ram_addr + 1];
                    }
                }
            } else if (src < self.dma_source.len) {
                // Read from ROM
                word = (@as(u16, self.dma_source[src]) << 8);
                if (src + 1 < self.dma_source.len) {
                    word |= self.dma_source[src + 1];
                }
            }

            // Write to destination
            switch (dest_type) {
                0x01 => { // VRAM
                    self.vram[self.addr & 0xFFFE] = @truncate(word >> 8);
                    self.vram[(self.addr & 0xFFFE) | 1] = @truncate(word);
                },
                0x03 => { // CRAM
                    const cram_addr = (self.addr >> 1) & 0x3F;
                    self.cram[cram_addr * 2] = @truncate(word);
                    self.cram[cram_addr * 2 + 1] = @truncate(word >> 8);
                },
                0x05 => { // VSRAM
                    const vsram_addr = (self.addr >> 1) & 0x3F;
                    if (vsram_addr * 2 + 1 < self.vsram.len) {
                        self.vsram[vsram_addr * 2] = @truncate(word);
                        self.vsram[vsram_addr * 2 + 1] = @truncate(word >> 8);
                    }
                },
                else => {},
            }

            src += 2;
            self.addr +%= self.regs[15];
        }

        // Update source address registers
        self.regs[21] = @truncate(src >> 1);
        self.regs[22] = @truncate(src >> 9);
        self.regs[23] = (self.regs[23] & 0x80) | @as(u8, @truncate(src >> 17));
    }

    fn doDMAFill(self: *VDP) void {
        var len: u32 = (@as(u32, self.regs[20]) << 8) | self.regs[19];
        if (len == 0) len = 0x10000;

        const fill_byte: u8 = @truncate(self.dma_fill_data >> 8);

        while (len > 0) : (len -= 1) {
            self.vram[self.addr & 0xFFFF] = fill_byte;
            self.addr +%= self.regs[15];
        }
    }

    fn doDMACopy(self: *VDP) void {
        var len: u32 = (@as(u32, self.regs[20]) << 8) | self.regs[19];
        if (len == 0) len = 0x10000;

        var src: u32 = (@as(u32, self.regs[22]) << 8) | self.regs[21];

        while (len > 0) : (len -= 1) {
            self.vram[self.addr & 0xFFFF] = self.vram[src & 0xFFFF];
            src += 1;
            self.addr +%= self.regs[15];
        }
    }

    pub fn tick(self: *VDP, cycles: u32) void {
        // Genesis timing: 3420 master clocks per line, M68K = master/7
        // 3420 / 7 = 488.57 M68K cycles per scanline
        self.hcounter += @truncate(cycles);

        while (self.hcounter >= 488) {
            self.hcounter -= 488;
            self.endScanline();
        }
    }

    fn endScanline(self: *VDP) void {
        self.hblank_flag = false;
        if (self.scanline < SCREEN_HEIGHT) {
            self.renderScanline(@truncate(self.scanline));
        }
        self.hblank_flag = true;

        // Update V counter
        self.scanline += 1;
        if (self.scanline < 0xEB) {
            self.vcounter = @truncate(self.scanline);
        } else {
            self.vcounter = @truncate(self.scanline - 6); // V counter jump
        }

        // H-Int counter reload behavior
        if (self.scanline <= SCREEN_HEIGHT) {
            if (self.hint_counter == 0) {
                self.hint_counter = self.regs[10];
                if (self.regs[0] & 0x10 != 0) {
                    self.hint_pending = true;
                }
            } else {
                self.hint_counter -= 1;
            }
        } else {
            self.hint_counter = self.regs[10];
        }

        // V-Int toggle when entering VBlank
        if (self.scanline == SCREEN_HEIGHT) {
            self.vblank_flag = true;
            if (self.regs[1] & 0x20 != 0) {
                self.vint_pending = true;
                self.debug_vint_set += 1;
            }
        }

        // Frame end
        if (self.scanline >= 262) {
            self.scanline = 0;
            self.vblank_flag = false;
            self.frame += 1;
        }
    }

    pub fn renderScanline(self: *VDP, line: u16) void {
        if (line >= SCREEN_HEIGHT) return;

        const h_cells: u16 = if (self.regs[12] & 0x01 != 0) 40 else 32;
        const width: usize = @as(usize, h_cells) * 8;

        // Clear line
        const start: usize = @as(usize, line) * SCREEN_WIDTH;
        const bg_color = self.getColor(@truncate(self.regs[7] & 0x3F));
        @memset(self.frame_buffer[start..][0..width], bg_color);
        @memset(&self.priority_buffer, 0);
        @memset(&self.sprite_line_pixels, false);

        // Skip if display disabled
        if (self.regs[1] & 0x40 == 0) return;

        // Render Plane B (back)
        self.renderPlane(line, h_cells, false);

        // Render Plane A
        self.renderPlane(line, h_cells, true);

        // Render Window (if enabled)
        self.renderWindow(line, h_cells);

        // Render Sprites
        self.renderSprites(line, h_cells);
    }

    fn renderPlane(self: *VDP, line: u16, h_cells: u16, plane_a: bool) void {
        const scroll_size = (self.regs[16] >> (if (plane_a) @as(u5, 0) else 4)) & 0x03;
        const plane_w: u16 = switch (@as(u2, @truncate(scroll_size & 3))) {
            0 => 32,
            1 => 64,
            2 => 32, // Invalid
            3 => 128,
        };
        const plane_h: u16 = switch (@as(u2, @truncate((self.regs[16] >> 4) & 3))) {
            0 => 32,
            1 => 64,
            2 => 32,
            3 => 128,
        };

        const scroll_base: u16 = if (plane_a)
            (@as(u16, self.regs[2] & 0x38) << 10)
        else
            (@as(u16, self.regs[4] & 0x07) << 13);

        // Get horizontal scroll
        const hscroll_mode = self.regs[11] & 0x03;
        const hscroll_base: u16 = (@as(u16, self.regs[13] & 0x3F) << 10);
        const hscroll_offset: u16 = switch (@as(u2, @truncate(hscroll_mode))) {
            0 => 0, // Full screen
            1 => 0, // Invalid, treat as full
            2 => (line & 0x07) * 4, // Per-8 lines
            3 => line * 4, // Per-line
        };
        const hscroll_addr = hscroll_base + hscroll_offset + (if (plane_a) @as(u16, 0) else 2);
        const hscroll: u16 = 0x400 - (self.readVram16(hscroll_addr) & 0x3FF);

        // Get vertical scroll (per-2-columns supported)
        const vscroll_mode = (self.regs[11] >> 2) & 1;

        for (0..h_cells * 8) |px| {
            const x: u16 = @intCast(px);
            const ux: usize = x;

            // Get vscroll for this column
            const vscroll: u16 = if (vscroll_mode != 0) blk: {
                const col = (x / 16) * 4 + (if (plane_a) @as(u16, 0) else 2);
                break :blk self.readVsram16(col) & 0x3FF;
            } else blk: {
                break :blk self.readVsram16(if (plane_a) 0 else 2) & 0x3FF;
            };

            const scroll_x = (x +% hscroll) % (plane_w * 8);
            const scroll_y = (line +% vscroll) % (plane_h * 8);

            // Get tile
            const tile_x = scroll_x / 8;
            const tile_y = scroll_y / 8;
            const name_addr = scroll_base + (tile_y * plane_w + tile_x) * 2;
            const name = self.readVram16(name_addr);

            // Decode name entry
            const tile_idx = name & 0x7FF;
            const palette: u2 = @truncate((name >> 13) & 0x03);
            const flip_h = name & 0x0800 != 0;
            const flip_v = name & 0x1000 != 0;
            const priority = name & 0x8000 != 0;

            // Get pixel
            var fine_x: u3 = @truncate(scroll_x & 7);
            var fine_y: u3 = @truncate(scroll_y & 7);
            if (flip_h) fine_x = 7 - fine_x;
            if (flip_v) fine_y = 7 - fine_y;

            const color_idx = self.getTilePixel(tile_idx, fine_x, fine_y);

            if (color_idx != 0) {
                const should_draw = if (priority)
                    self.priority_buffer[ux] < 2
                else
                    self.priority_buffer[ux] == 0;

                if (should_draw) {
                    const color = self.getColor(@as(u6, palette) * 16 + color_idx);
                    self.frame_buffer[@as(usize, line) * SCREEN_WIDTH + ux] = color;
                    if (priority) self.priority_buffer[ux] = 1;
                }
            }
        }
    }

    fn renderWindow(self: *VDP, line: u16, h_cells: u16) void {
        const window_base: u16 = (@as(u16, self.regs[3] & 0x3E) << 10);
        const win_w: u16 = if (h_cells == 40) 64 else 32;
        const width_px: u16 = h_cells * 8;

        const reg17 = self.regs[17];
        const win_right = reg17 & 0x80 != 0;
        const win_h_pos = (@as(u16, reg17 & 0x1F)) * 16;

        const reg18 = self.regs[18];
        const win_down = reg18 & 0x80 != 0;
        const win_v_pos = (@as(u16, reg18 & 0x1F)) * 8;

        const in_window_v = if (win_down)
            line >= win_v_pos
        else
            line < win_v_pos;
        if (!in_window_v) return;

        const x_start: u16 = if (win_right)
            if (win_h_pos > width_px) width_px else win_h_pos
        else
            0;
        const x_end: u16 = if (win_right)
            width_px
        else if (win_h_pos > width_px) width_px else win_h_pos;

        if (x_start >= x_end) return;

        for (x_start..x_end) |px| {
            const x: u16 = @intCast(px);
            const win_x = x - x_start;
            const win_y = if (win_down) line - win_v_pos else line;

            const tile_x = @as(u16, win_x) / 8;
            const tile_y = win_y / 8;
            if (tile_x >= win_w) continue;

            const name_addr = window_base + (tile_y * win_w + tile_x) * 2;
            const name = self.readVram16(name_addr);

            const tile_idx = name & 0x7FF;
            const palette: u2 = @truncate((name >> 13) & 0x03);
            const flip_h = name & 0x0800 != 0;
            const flip_v = name & 0x1000 != 0;
            const priority = name & 0x8000 != 0;

            var fine_x: u3 = @truncate(win_x & 7);
            var fine_y: u3 = @truncate(win_y & 7);
            if (flip_h) fine_x = 7 - fine_x;
            if (flip_v) fine_y = 7 - fine_y;

            const color_idx = self.getTilePixel(tile_idx, fine_x, fine_y);
            if (color_idx == 0) continue;

            const color = self.getColor(@as(u6, palette) * 16 + color_idx);
            const ux: usize = x;
            const idx = @as(usize, line) * SCREEN_WIDTH + ux;
            self.frame_buffer[idx] = color;
            if (priority) {
                self.priority_buffer[ux] = 2;
            } else if (self.priority_buffer[ux] == 0) {
                self.priority_buffer[ux] = 1;
            }
        }
    }

    fn renderSprites(self: *VDP, line: u16, h_cells: u16) void {
        const sat_base: u16 = (@as(u16, self.regs[5] & 0x7F) << 9);
        const max_sprites: u8 = if (h_cells == 40) 20 else 16;
        const base_sprite_height: u16 = if (self.regs[1] & 0x02 != 0) 16 else 8;
        const line_width: i32 = @as(i32, h_cells) * 8;

        var sprites_on_line: u8 = 0;
        var processed: u8 = 0;
        var link: u8 = 0;

        while (processed < 80) : (processed += 1) {
            const entry_addr = sat_base + @as(u16, link) * 8;
            const y_pos = self.readVram16(entry_addr) & 0x3FF;
            const size = self.vram[entry_addr + 2];
            const next_link = self.vram[entry_addr + 3] & 0x7F;
            const attr = self.readVram16(entry_addr + 4);
            const x_pos = self.readVram16(entry_addr + 6) & 0x3FF;

            const w_cells: u16 = (size & 0x03) + 1;
            const v_cells: u16 = ((size >> 2) & 0x03) + 1;
            const sprite_height = v_cells * base_sprite_height;

            const sprite_y = @as(i32, y_pos) - 128;
            const line_i32: i32 = @intCast(line);
            if (line_i32 >= sprite_y and line_i32 < sprite_y + @as(i32, sprite_height)) {
                sprites_on_line += 1;
                if (sprites_on_line > max_sprites) {
                    self.sprite_overflow = true;
                    break;
                }

                const palette: u2 = @truncate((attr >> 13) & 0x03);
                const flip_h = attr & 0x0800 != 0;
                const flip_v = attr & 0x1000 != 0;
                const priority = attr & 0x8000 != 0;
                const tile_base = attr & 0x07FF;

                var row: u16 = @intCast(line_i32 - sprite_y);
                if (flip_v) row = sprite_height - 1 - row;
                const tile_row = row / base_sprite_height;
                const fine_y: u3 = @truncate(row % base_sprite_height);

                for (0..w_cells * 8) |px| {
                    var col: u16 = @intCast(px);
                    if (flip_h) col = w_cells * 8 - 1 - col;

                    const tile_col = col / 8;
                    const fine_x: u3 = @truncate(col % 8);
                    const tile_idx = (tile_base + tile_row * w_cells + tile_col) & 0x07FF;
                    const color_idx = self.getTilePixel(tile_idx, fine_x, fine_y);
                    if (color_idx == 0) continue;

                    const screen_x = (@as(i32, x_pos) - 128) + @as(i32, @intCast(px));
                    if (screen_x < 0 or screen_x >= line_width) continue;

                    const ux: usize = @intCast(screen_x);
                    if (ux >= self.sprite_line_pixels.len) continue;
                    if (self.sprite_line_pixels[ux]) {
                        self.sprite_collision = true;
                    } else {
                        self.sprite_line_pixels[ux] = true;
                    }

                    const should_draw = if (priority) true else self.priority_buffer[ux] < 2;
                    if (!should_draw) continue;

                    const color = self.getColor(@as(u6, palette) * 16 + color_idx);
                    self.frame_buffer[@as(usize, line) * SCREEN_WIDTH + ux] = color;
                    self.priority_buffer[ux] = if (priority) 3 else 2;
                }
            }

            if (next_link == 0) break;
            link = next_link;
        }
    }

    fn getTilePixel(self: *VDP, tile: u16, x: u3, y: u3) u4 {
        // Genesis tiles: 32 bytes each (4bpp, 8x8)
        const tile_addr = @as(u32, tile) * 32 + @as(u32, y) * 4;
        const byte_idx = x >> 1;
        const byte = self.vram[(tile_addr + byte_idx) & 0xFFFF];

        return if (x & 1 == 0)
            @truncate(byte >> 4)
        else
            @truncate(byte & 0x0F);
    }

    fn getColor(self: *VDP, idx: u6) u32 {
        const cram_addr = @as(usize, idx) * 2;
        if (cram_addr + 1 >= self.cram.len) return 0xFF000000;

        const entry = @as(u16, self.cram[cram_addr]) |
            (@as(u16, self.cram[cram_addr + 1]) << 8);

        // Genesis: ----BBB-GGG-RRR-
        const r = ((entry >> 1) & 0x07) * 36;
        const g = ((entry >> 5) & 0x07) * 36;
        const b = ((entry >> 9) & 0x07) * 36;

        return 0xFF000000 | (@as(u32, b) << 16) | (@as(u32, g) << 8) | r;
    }

    fn readVram16(self: *VDP, addr: u16) u16 {
        return (@as(u16, self.vram[addr]) << 8) | self.vram[addr + 1];
    }

    fn readVsram16(self: *VDP, addr: u16) u16 {
        if (addr + 1 >= self.vsram.len) return 0;
        return @as(u16, self.vsram[addr]) | (@as(u16, self.vsram[addr + 1]) << 8);
    }
};
