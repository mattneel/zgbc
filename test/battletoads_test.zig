const std = @import("std");
const zgbc = @import("zgbc");
const NES = zgbc.NES;

fn saveScreenshot(frame: *const [256 * 240]u32, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    try file.writeAll("P6\n256 240\n255\n");

    var pixels: [256 * 240 * 3]u8 = undefined;
    for (frame, 0..) |abgr, i| {
        pixels[i * 3 + 0] = @truncate(abgr); // R
        pixels[i * 3 + 1] = @truncate(abgr >> 8); // G
        pixels[i * 3 + 2] = @truncate(abgr >> 16); // B
    }

    try file.writeAll(&pixels);
}

fn countNonBlackPixels(frame: *const [256 * 240]u32) u32 {
    var count: u32 = 0;
    for (frame.*) |pixel| {
        if ((pixel & 0x00FFFFFF) != 0) {
            count += 1;
        }
    }
    return count;
}

test "battletoads_mmc3" {
    var file = std.fs.cwd().openFile("roms/battletoads.nes", .{}) catch {
        std.debug.print("Skipping - battletoads.nes not found\n", .{});
        return;
    };
    defer file.close();

    const stat = try file.stat();
    const rom = try std.testing.allocator.alloc(u8, stat.size);
    defer std.testing.allocator.free(rom);
    _ = try file.preadAll(rom, 0);

    var system = NES{};
    system.loadRom(rom);

    // Print mapper info
    std.debug.print("\n=== Battletoads Debug ===\n", .{});
    std.debug.print("PRG ROM size: {d} bytes\n", .{system.mmu.prg_rom.len});
    std.debug.print("CHR ROM size: {d} bytes\n", .{system.mmu.chr_rom.len});
    std.debug.print("CHR RAM: {}\n", .{system.ppu.use_chr_ram});

    // Print mapper type
    const mapper_name: []const u8 = switch (system.mmu.mapper) {
        .nrom => "NROM (0)",
        .mmc1 => "MMC1 (1)",
        .uxrom => "UxROM (2)",
        .mmc3 => "MMC3 (4)",
        .axrom => "AxROM (7)",
    };
    std.debug.print("Mapper: {s}\n", .{mapper_name});

    // Run a few frames and check state
    for (0..10) |frame_num| {
        system.frame();

        if (frame_num < 5) {
            std.debug.print("Frame {d}: PC=${X:04}\n", .{
                frame_num,
                system.cpu.pc,
            });
        }
    }

    // Run more frames
    for (0..50) |_| {
        system.frame();
    }

    // Save screenshot
    try saveScreenshot(system.getFrameBuffer(), "battletoads.ppm");

    const non_black = countNonBlackPixels(system.getFrameBuffer());
    std.debug.print("Non-black pixels: {d}\n", .{non_black});
    std.debug.print("CPU PC: ${X:04}\n", .{system.cpu.pc});

    // Check if we have any rendering
    if (non_black < 1000) {
        std.debug.print("WARNING: Screen appears mostly black!\n", .{});

        // Debug PPU state
        std.debug.print("PPU: ctrl=${X:02} mask=${X:02} status=${X:02}\n", .{
            system.ppu.ctrl,
            system.ppu.mask,
            system.ppu.status,
        });
        std.debug.print("PPU: scanline={d} cycle={d}\n", .{
            system.ppu.scanline,
            system.ppu.cycle,
        });
    }
}
