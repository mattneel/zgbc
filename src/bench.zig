//! libzetro Benchmark
//! Measures raw emulation performance.

const std = @import("std");
const GB = @import("gb/system.zig").GB;
const simd_batch = @import("simd_batch.zig");
const PPU = @import("gb/ppu.zig").PPU;

const BENCH_FRAMES = 10_000;

/// Save frame buffer as PPM image
fn saveScreenshot(frame: *const [160 * 144]u8, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    // PPM header
    try file.writeAll("P6\n160 144\n255\n");

    // Convert 2-bit color indices to RGB
    const palette = [4][3]u8{
        .{ 0x9B, 0xBC, 0x0F }, // Lightest
        .{ 0x8B, 0xAC, 0x0F }, // Light
        .{ 0x30, 0x62, 0x30 }, // Dark
        .{ 0x0F, 0x38, 0x0F }, // Darkest
    };

    var pixels: [160 * 144 * 3]u8 = undefined;
    for (frame, 0..) |color_idx, i| {
        const rgb = palette[color_idx];
        pixels[i * 3 + 0] = rgb[0];
        pixels[i * 3 + 1] = rgb[1];
        pixels[i * 3 + 2] = rgb[2];
    }

    try file.writeAll(&pixels);
}

fn runFrames(gb: *GB, frames: usize) void {
    for (0..frames) |_| {
        gb.frame();
    }
}

// Cache-line aligned GB wrapper to prevent false sharing
const AlignedGB = struct {
    gb: GB align(64) = .{},
    _padding: [64 - @sizeOf(GB) % 64]u8 = undefined,
};

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

    // Single-thread comparison: full vs headless
    std.debug.print("\n=== zgbc benchmark (Pokemon Red) ===\n", .{});

    var gb_full = GB{};
    try gb_full.loadRom(rom);
    gb_full.skipBootRom();
    for (0..1000) |_| gb_full.frame();

    // Save screenshot to verify PPU
    try saveScreenshot(gb_full.getFrameBuffer(), "screenshot.ppm");
    std.debug.print("Screenshot saved to screenshot.ppm\n", .{});

    // Benchmark full rendering
    var timer_full = try std.time.Timer.start();
    for (0..BENCH_FRAMES) |_| gb_full.frame();
    const full_ns = timer_full.read();
    const full_fps = @as(f64, BENCH_FRAMES) / (@as(f64, @floatFromInt(full_ns)) / 1e9);

    // Benchmark PPU-only (no APU) - RL training mode
    var gb_ppu_only = GB{};
    gb_ppu_only.render_graphics = true; // PPU enabled for pixel observations
    gb_ppu_only.render_audio = false; // APU disabled
    try gb_ppu_only.loadRom(rom);
    gb_ppu_only.skipBootRom();
    for (0..1000) |_| gb_ppu_only.frame();

    var timer_ppu_only = try std.time.Timer.start();
    for (0..BENCH_FRAMES) |_| gb_ppu_only.frame();
    const ppu_only_ns = timer_ppu_only.read();
    const ppu_only_fps = @as(f64, BENCH_FRAMES) / (@as(f64, @floatFromInt(ppu_only_ns)) / 1e9);

    // Benchmark headless (no graphics, no audio)
    var gb_headless = GB{};
    gb_headless.render_graphics = false;
    gb_headless.render_audio = false;
    try gb_headless.loadRom(rom);
    gb_headless.skipBootRom();
    for (0..1000) |_| gb_headless.frame();

    var timer_headless = try std.time.Timer.start();
    for (0..BENCH_FRAMES) |_| gb_headless.frame();
    const headless_ns = timer_headless.read();
    const headless_fps = @as(f64, BENCH_FRAMES) / (@as(f64, @floatFromInt(headless_ns)) / 1e9);

    std.debug.print("\nSingle-thread performance:\n", .{});
    std.debug.print("  Full (PPU+APU):    {d:>8.0} FPS\n", .{full_fps});
    std.debug.print("  PPU-only (no APU): {d:>8.0} FPS ({d:.1}x faster)  <-- RL-relevant\n", .{ ppu_only_fps, ppu_only_fps / full_fps });
    std.debug.print("  Headless:          {d:>8.0} FPS ({d:.1}x faster)\n", .{ headless_fps, headless_fps / full_fps });

    // Multi-threaded headless scaling
    std.debug.print("\nHeadless multi-threaded scaling:\n", .{});
    std.debug.print("Threads |    FPS    | Per-thread |  Scaling\n", .{});
    std.debug.print("--------|-----------|------------|----------\n", .{});

    const single_fps = headless_fps;

    const thread_counts = [_]usize{ 1, 2, 4, 8, 16, 32 };

    for (thread_counts) |num_threads| {
        // Allocate cache-aligned GB instances (headless mode)
        var gbs: [32]AlignedGB = undefined;
        for (gbs[0..num_threads]) |*agb| {
            agb.gb = GB{};
            agb.gb.render_graphics = false;
            agb.gb.render_audio = false;
            try agb.gb.loadRom(rom);
            agb.gb.skipBootRom();
        }

        // Warmup
        for (gbs[0..num_threads]) |*agb| {
            for (0..1000) |_| agb.gb.frame();
        }

        // Benchmark
        var timer = try std.time.Timer.start();

        var threads: [32]std.Thread = undefined;
        for (threads[0..num_threads], gbs[0..num_threads]) |*t, *agb| {
            t.* = try std.Thread.spawn(.{}, runFrames, .{ &agb.gb, BENCH_FRAMES });
        }
        for (threads[0..num_threads]) |*t| {
            t.join();
        }

        const elapsed_ns = timer.read();
        const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
        const total_frames: f64 = @floatFromInt(BENCH_FRAMES * num_threads);
        const fps = total_frames / elapsed_s;
        const per_thread = fps / @as(f64, @floatFromInt(num_threads));
        const scaling = fps / single_fps;

        std.debug.print("{d:>7} | {d:>9.0} | {d:>10.0} | {d:>7.2}x\n", .{
            num_threads, fps, per_thread, scaling,
        });
    }

    // SIMD ALU micro-benchmark
    try simd_batch.benchmarkALU();

    // Struct sizes
    std.debug.print("\n=== Struct sizes ===\n", .{});
    std.debug.print("GB:  {} bytes\n", .{@sizeOf(GB)});
}
