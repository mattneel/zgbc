//! PPU (Pixel Processing Unit)
//! Renders Game Boy graphics to a frame buffer.

const MMU = @import("mmu.zig").MMU;

/// Classic green palette (RGBA)
pub const PALETTE = [4]u32{
    0xFF9BBC0F, // Lightest (0)
    0xFF8BAC0F, // Light (1)
    0xFF306230, // Dark (2)
    0xFF0F380F, // Darkest (3)
};

pub const PPU = struct {
    frame_buffer: [160 * 144]u8 = [_]u8{0} ** (160 * 144), // 2-bit color indices
    window_line: u8 = 0, // Internal window line counter

    /// Render one scanline (call when LY changes, LY < 144)
    pub fn renderScanline(self: *PPU, mmu: *MMU) void {
        const ly = mmu.ly;
        if (ly >= 144) return; // VBlank, no rendering

        const lcdc = mmu.lcdc;
        if (lcdc & 0x80 == 0) return; // LCD disabled

        // Clear line to BG color 0
        const line_start = @as(usize, ly) * 160;
        @memset(self.frame_buffer[line_start..][0..160], 0);

        // Background
        if (lcdc & 0x01 != 0) {
            self.renderBgLine(mmu, ly);
        }

        // Window
        if (lcdc & 0x20 != 0) {
            self.renderWindowLine(mmu, ly);
        }

        // Sprites
        if (lcdc & 0x02 != 0) {
            self.renderSpriteLine(mmu, ly);
        }
    }

    fn renderBgLine(self: *PPU, mmu: *MMU, ly: u8) void {
        const scy = mmu.scy;
        const scx = mmu.scx;
        const lcdc = mmu.lcdc;

        // Tile map: 0x9800 or 0x9C00
        const map_base: u16 = if (lcdc & 0x08 != 0) 0x1C00 else 0x1800;

        // Tile data: 0x8000 (unsigned) or 0x8800 (signed)
        const signed = lcdc & 0x10 == 0;

        const y = ly +% scy;
        const tile_row = @as(u16, y >> 3);
        const fine_y: u16 = y & 7;

        const line_start = @as(usize, ly) * 160;

        for (0..160) |px| {
            const x = @as(u8, @intCast(px)) +% scx;
            const tile_col = @as(u16, x >> 3);
            const fine_x: u3 = @intCast(x & 7);

            // Get tile index from map
            const map_addr = map_base + tile_row * 32 + tile_col;
            const tile_idx = mmu.vram[map_addr];

            // Get tile data address
            const tile_addr: u16 = if (signed) blk: {
                const signed_idx: i8 = @bitCast(tile_idx);
                const offset: i16 = @as(i16, signed_idx) * 16;
                break :blk @intCast(@as(i32, 0x1000) + offset);
            } else @as(u16, tile_idx) * 16;

            // Get pixel from tile (2 bytes per row)
            const row_addr = tile_addr + fine_y * 2;
            const lo = mmu.vram[row_addr];
            const hi = mmu.vram[row_addr + 1];

            const bit: u3 = 7 - fine_x;
            const color_idx = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);

            // Apply BGP palette
            const color = (mmu.bgp >> (@as(u3, @intCast(color_idx)) * 2)) & 0x03;

            self.frame_buffer[line_start + px] = color;
        }
    }

    fn renderWindowLine(self: *PPU, mmu: *MMU, ly: u8) void {
        const wy = mmu.wy;
        const wx = mmu.wx;
        if (ly < wy) return;
        if (wx > 166) return;

        const lcdc = mmu.lcdc;
        // Window map: 0x9800 or 0x9C00 (bit 6 of LCDC)
        const map_base: u16 = if (lcdc & 0x40 != 0) 0x1C00 else 0x1800;
        const signed = lcdc & 0x10 == 0;

        const window_y = self.window_line;
        const tile_row = @as(u16, window_y >> 3);
        const fine_y: u16 = window_y & 7;

        const screen_x_start: u8 = if (wx < 7) 0 else wx - 7;
        const line_start = @as(usize, ly) * 160;

        var rendered = false;
        for (screen_x_start..160) |px| {
            const window_x: u8 = @intCast(px - screen_x_start);
            const tile_col = @as(u16, window_x >> 3);
            const fine_x: u3 = @intCast(window_x & 7);

            const map_addr = map_base + tile_row * 32 + tile_col;
            const tile_idx = mmu.vram[map_addr];

            const tile_addr: u16 = if (signed) blk: {
                const signed_idx: i8 = @bitCast(tile_idx);
                const offset: i16 = @as(i16, signed_idx) * 16;
                break :blk @intCast(@as(i32, 0x1000) + offset);
            } else @as(u16, tile_idx) * 16;

            const row_addr = tile_addr + fine_y * 2;
            const lo = mmu.vram[row_addr];
            const hi = mmu.vram[row_addr + 1];

            const bit: u3 = 7 - fine_x;
            const color_idx = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);
            const color = (mmu.bgp >> (@as(u3, @intCast(color_idx)) * 2)) & 0x03;

            self.frame_buffer[line_start + px] = color;
            rendered = true;
        }

        if (rendered) {
            self.window_line += 1;
        }
    }

    fn renderSpriteLine(self: *PPU, mmu: *MMU, ly: u8) void {
        const lcdc = mmu.lcdc;
        const sprite_height: u8 = if (lcdc & 0x04 != 0) 16 else 8;

        // Collect sprites on this line (max 10, lowest X has priority)
        var sprite_count: usize = 0;
        var sprites: [10]usize = undefined;

        for (0..40) |i| {
            const oam_addr = i * 4;
            const sprite_y = mmu.oam[oam_addr];
            if (sprite_y == 0 or sprite_y >= 160) continue;

            const top = sprite_y -% 16;
            if (ly < top or ly >= top +% sprite_height) continue;

            sprites[sprite_count] = i;
            sprite_count += 1;
            if (sprite_count >= 10) break;
        }

        // Render in reverse order (lower index = higher priority, drawn last)
        var idx = sprite_count;
        while (idx > 0) {
            idx -= 1;
            const i = sprites[idx];
            const oam_addr = i * 4;

            const sprite_y = mmu.oam[oam_addr];
            const sprite_x = mmu.oam[oam_addr + 1];
            var tile_idx = mmu.oam[oam_addr + 2];
            const attrs = mmu.oam[oam_addr + 3];

            if (sprite_x == 0 or sprite_x >= 168) continue;

            const flip_y = attrs & 0x40 != 0;
            const flip_x = attrs & 0x20 != 0;
            const priority = attrs & 0x80 != 0; // Behind BG if set
            const palette = if (attrs & 0x10 != 0) mmu.obp1 else mmu.obp0;

            var row = ly -% (sprite_y -% 16);
            if (flip_y) row = sprite_height - 1 - row;

            if (sprite_height == 16) {
                tile_idx &= 0xFE; // Ignore bit 0 for 8x16 sprites
            }

            const tile_addr: u16 = @as(u16, tile_idx) * 16 + @as(u16, row) * 2;
            const lo = mmu.vram[tile_addr];
            const hi = mmu.vram[tile_addr + 1];

            const line_start = @as(usize, ly) * 160;

            for (0..8) |px_i| {
                const px: u3 = @intCast(px_i);
                const screen_x_i16: i16 = @as(i16, sprite_x) - 8 + px;
                if (screen_x_i16 < 0 or screen_x_i16 >= 160) continue;
                const screen_x: usize = @intCast(screen_x_i16);

                const bit: u3 = if (flip_x) px else 7 - px;
                const color_idx = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);

                if (color_idx == 0) continue; // Transparent

                // Priority check: if priority bit set, only draw over BG color 0
                if (priority and self.frame_buffer[line_start + screen_x] != 0) continue;

                const color = (palette >> (@as(u3, @intCast(color_idx)) * 2)) & 0x03;
                self.frame_buffer[line_start + screen_x] = color;
            }
        }
    }

    /// Reset window line counter (call at start of frame)
    pub fn resetWindowLine(self: *PPU) void {
        self.window_line = 0;
    }

    /// Convert frame buffer to RGBA
    pub fn toRGBA(frame: *const [160 * 144]u8, out: *[160 * 144]u32) void {
        for (frame, out) |color_idx, *pixel| {
            pixel.* = PALETTE[color_idx];
        }
    }
};

test "ppu init" {
    const ppu = PPU{};
    _ = ppu.frame_buffer[0];
}
