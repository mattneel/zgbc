const std = @import("std");
const sms = @import("sms");
const SMS = sms.SMS;

/// Save frame buffer as PPM image (256x192, ABGR format)
fn saveScreenshot(frame: *const [256 * 192]u32, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    // PPM header
    try file.writeAll("P6\n256 192\n255\n");

    // Convert ABGR to RGB
    var pixels: [256 * 192 * 3]u8 = undefined;
    for (frame, 0..) |abgr, i| {
        pixels[i * 3 + 0] = @truncate(abgr); // R
        pixels[i * 3 + 1] = @truncate(abgr >> 8); // G
        pixels[i * 3 + 2] = @truncate(abgr >> 16); // B
    }

    try file.writeAll(&pixels);
}

/// Count non-black pixels to verify something is being rendered
fn countNonBlackPixels(frame: *const [256 * 192]u32) u32 {
    var count: u32 = 0;
    for (frame.*) |pixel| {
        // Check if pixel is not black (ignoring alpha)
        if ((pixel & 0x00FFFFFF) != 0) {
            count += 1;
        }
    }
    return count;
}

test "sms_sonic_visual" {
    // Open ROM
    var file = std.fs.cwd().openFile("roms/sonic.sms", .{}) catch {
        // Skip test if ROM not present
        return;
    };
    defer file.close();

    const stat = try file.stat();
    const rom = try std.testing.allocator.alloc(u8, stat.size);
    defer std.testing.allocator.free(rom);
    _ = try file.preadAll(rom, 0);

    var system = SMS{};
    system.loadRom(rom);

    // Run 60 frames (1 second)
    for (0..60) |_| {
        system.frame();
    }

    // Save screenshot
    try saveScreenshot(system.getFrameBuffer(), "sonic_sms.ppm");

    // Count non-black pixels - there should be a lot if rendering works
    const non_black = countNonBlackPixels(system.getFrameBuffer());

    // Verify we have some rendered content (at least 10% of screen)
    const threshold = (256 * 192) / 10;
    try std.testing.expect(non_black >= threshold);
}
