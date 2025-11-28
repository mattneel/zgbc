//! zgbc Benchmark
//! Measures raw emulation performance.

const std = @import("std");
const GB = @import("gb.zig").GB;

pub fn main() !void {
    // Load ROM from file using posix read
    const file = try std.fs.cwd().openFile("roms/pokered.gb", .{});
    defer file.close();
    const stat = try file.stat();
    const rom = try std.heap.page_allocator.alloc(u8, stat.size);
    defer std.heap.page_allocator.free(rom);

    // Read using preadAll
    const bytes_read = try std.posix.pread(file.handle, rom, 0);
    if (bytes_read != rom.len) return error.IncompleteRead;

    // Single instance benchmark
    {
        var gb = GB{};
        try gb.loadRom(rom);
        gb.skipBootRom();

        // Warmup - get to title screen
        for (0..1000) |_| {
            gb.frame();
        }

        // Benchmark
        const frames = 10_000;
        var timer = try std.time.Timer.start();

        for (0..frames) |_| {
            gb.frame();
        }

        const elapsed_ns = timer.read();
        const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const fps: f64 = @as(f64, @floatFromInt(frames)) / elapsed_s;

        std.debug.print("\n=== zgbc Benchmark (single instance) ===\n", .{});
        std.debug.print("Frames: {d}\n", .{frames});
        std.debug.print("Time: {d:.3}s\n", .{elapsed_s});
        std.debug.print("FPS: {d:.0}\n", .{fps});
        std.debug.print("vs realtime (60fps): {d:.0}x\n", .{fps / 60.0});
    }

    // 16 parallel instances benchmark
    {
        var gbs: [16]GB = undefined;
        for (&gbs) |*gb| {
            gb.* = GB{};
            try gb.loadRom(rom);
            gb.skipBootRom();
        }

        // Warmup
        for (0..1000) |_| {
            for (&gbs) |*gb| {
                gb.frame();
            }
        }

        // Benchmark
        const frames = 10_000;
        var timer = try std.time.Timer.start();

        for (0..frames) |_| {
            for (&gbs) |*gb| {
                gb.frame();
            }
        }

        const elapsed_ns = timer.read();
        const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const total_frames = frames * 16;
        const fps: f64 = @as(f64, @floatFromInt(total_frames)) / elapsed_s;

        std.debug.print("\n=== zgbc Benchmark (16 instances) ===\n", .{});
        std.debug.print("Instances: 16\n", .{});
        std.debug.print("Frames per instance: {d}\n", .{frames});
        std.debug.print("Total frames: {d}\n", .{total_frames});
        std.debug.print("Time: {d:.3}s\n", .{elapsed_s});
        std.debug.print("FPS (total): {d:.0}\n", .{fps});
        std.debug.print("FPS (per instance): {d:.0}\n", .{fps / 16.0});
        std.debug.print("vs realtime (60fps): {d:.0}x per instance\n", .{fps / 16.0 / 60.0});
        std.debug.print("\n", .{});
    }
}
