//! zgbc Benchmark
//! Measures raw emulation performance.

const std = @import("std");
const GB = @import("gb.zig").GB;
const simd_batch = @import("simd_batch.zig");

const BENCH_FRAMES = 10_000;

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

    // Scaling test
    std.debug.print("\n=== zgbc benchmark (Pokemon Red) ===\n", .{});
    std.debug.print("Threads |    FPS    | Per-thread |  Scaling\n", .{});
    std.debug.print("--------|-----------|------------|----------\n", .{});

    const single_fps = blk: {
        var gb = GB{};
        try gb.loadRom(rom);
        gb.skipBootRom();
        for (0..1000) |_| gb.frame(); // warmup

        var timer = try std.time.Timer.start();
        for (0..BENCH_FRAMES) |_| gb.frame();
        const ns = timer.read();
        break :blk @as(f64, BENCH_FRAMES) / (@as(f64, @floatFromInt(ns)) / 1e9);
    };

    const thread_counts = [_]usize{ 1, 2, 4, 8, 16, 32 };

    for (thread_counts) |num_threads| {
        // Allocate cache-aligned GB instances
        var gbs: [32]AlignedGB = undefined;
        for (gbs[0..num_threads]) |*agb| {
            agb.gb = GB{};
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
}
