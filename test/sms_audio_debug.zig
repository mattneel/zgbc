const std = @import("std");
const sms_mod = @import("sms");
const SMS = sms_mod.SMS;

test "sms_audio_debug" {
    var file = std.fs.cwd().openFile("roms/sonic.sms", .{}) catch return;
    defer file.close();

    const stat = try file.stat();
    const rom = try std.testing.allocator.alloc(u8, stat.size);
    defer std.testing.allocator.free(rom);
    _ = try file.preadAll(rom, 0);

    var system = SMS{};
    system.loadRom(rom);

    // Run ~2 seconds to get past title screen into game
    var drain_buf: [4096]i16 = undefined;
    for (0..120) |_| {
        system.frame();
        // Drain audio buffer to prevent overflow
        _ = system.psg.readSamples(&drain_buf);
    }

    // Now sample PSG state over several frames
    std.debug.print("\n=== PSG Debug (Green Hill Zone) ===\n", .{});

    for (0..10) |frame_num| {
        system.frame();

        const psg = &system.psg;
        std.debug.print("Frame {d}:\n", .{frame_num});
        std.debug.print("  Ch0: freq={d:4} vol={d:2} counter={d:5} pol={}\n", .{
            psg.tone[0].freq, psg.tone[0].volume, psg.tone[0].counter, psg.tone[0].polarity
        });
        std.debug.print("  Ch1: freq={d:4} vol={d:2} counter={d:5} pol={}\n", .{
            psg.tone[1].freq, psg.tone[1].volume, psg.tone[1].counter, psg.tone[1].polarity
        });
        std.debug.print("  Ch2: freq={d:4} vol={d:2} counter={d:5} pol={}\n", .{
            psg.tone[2].freq, psg.tone[2].volume, psg.tone[2].counter, psg.tone[2].polarity
        });
        std.debug.print("  Noise: ctrl={d} vol={d:2} shift=0x{x:4}\n", .{
            psg.noise.ctrl, psg.noise.volume, psg.noise.shift
        });

        // Calculate expected frequencies
        // SN76489: freq_hz = 3579545 / (32 * period)
        if (psg.tone[0].freq > 0) {
            const hz0 = 3579545 / (32 * @as(u32, psg.tone[0].freq));
            std.debug.print("  Ch0 expected Hz: {d}\n", .{hz0});
        }
    }

    // Check sample buffer state
    std.debug.print("\nSample buffer: write_idx={d} read_idx={d}\n", .{
        system.psg.sample_write_idx, system.psg.sample_read_idx
    });

    // Read some samples and check range
    var samples: [1024]i16 = undefined;
    const count = system.psg.readSamples(&samples);

    var min: i16 = 32767;
    var max: i16 = -32768;
    for (samples[0..count]) |s| {
        if (s < min) min = s;
        if (s > max) max = s;
    }
    std.debug.print("Sample range: min={d} max={d} count={d}\n", .{min, max, count});
}
