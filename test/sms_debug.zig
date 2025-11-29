const std = @import("std");
const sms = @import("sms");

test "sms_boot" {
    var file = std.fs.cwd().openFile("roms/sonic.sms", .{}) catch {
        // Skip test if ROM not present
        return;
    };
    defer file.close();

    const stat = try file.stat();
    const rom = try std.testing.allocator.alloc(u8, stat.size);
    defer std.testing.allocator.free(rom);
    _ = try file.preadAll(rom, 0);

    var system = sms.SMS{};
    system.loadRom(rom);

    // Run one frame - should escape boot loop
    system.frame();

    // Verify we got past the initial vblank wait loop (PC > 0x10)
    if (system.cpu.pc <= 0x0010) {
        std.debug.print("\nSMS boot failed: stuck at PC=0x{X:0>4}\n", .{system.cpu.pc});
        return error.BootFailed;
    }
}
