const std = @import("std");
const zgbc = @import("zgbc");
const Genesis = zgbc.Genesis;

fn saveScreenshot(frame: *const [320 * 224]u32, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    try file.writeAll("P6\n320 224\n255\n");

    var pixels: [320 * 224 * 3]u8 = undefined;
    for (frame, 0..) |abgr, i| {
        pixels[i * 3 + 0] = @truncate(abgr); // R
        pixels[i * 3 + 1] = @truncate(abgr >> 8); // G
        pixels[i * 3 + 2] = @truncate(abgr >> 16); // B
    }

    try file.writeAll(&pixels);
}

fn countNonBlackPixels(frame: *const [320 * 224]u32) u32 {
    var count: u32 = 0;
    for (frame.*) |pixel| {
        if ((pixel & 0x00FFFFFF) != 0) {
            count += 1;
        }
    }
    return count;
}

test "genesis_init" {
    var gen = Genesis{};
    gen.init();

    // Basic test - system should initialize
    try std.testing.expect(gen.m68k.sr.s == true); // Supervisor mode
}

test "genesis_sonic" {
    var file = std.fs.cwd().openFile("roms/sonic2.md", .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Skipping - sonic2.md not found in roms/\n", .{});
            return;
        }
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    const rom = try std.testing.allocator.alloc(u8, stat.size);
    defer std.testing.allocator.free(rom);
    _ = try file.preadAll(rom, 0);

    var gen = Genesis{};
    gen.loadRom(rom);

    std.debug.print("\n=== Genesis Debug ===\n", .{});
    std.debug.print("ROM size: {d} bytes\n", .{rom.len});
    std.debug.print("Initial PC: ${X:08}\n", .{gen.m68k.pc});
    std.debug.print("Initial SSP: ${X:08}\n", .{gen.m68k.ssp});

    // Trace first 100 instructions
    std.debug.print("\n=== Instruction Trace ===\n", .{});
    var last_pc: u32 = 0;
    var repeat_count: u32 = 0;
    for (0..500) |i| {
        const pc = gen.m68k.pc;
        const opcode = gen.bus.read16(pc);
        _ = gen.m68k.step(&gen.bus);

        if (pc == last_pc) {
            repeat_count += 1;
            if (repeat_count == 3) {
                std.debug.print("... (stuck at PC=${X:06})\n", .{pc});
            }
        } else {
            repeat_count = 0;
            if (i < 50 or (pc >= 0x330 and pc <= 0x340)) {
                std.debug.print("{d:3}: PC=${X:06} op=${X:04} -> PC=${X:06} D0=${X:08}\n", .{
                    i,
                    pc,
                    opcode,
                    gen.m68k.pc,
                    gen.m68k.d[0],
                });
            }
        }
        last_pc = pc;
    }

    // Run frames until checksum done, then trace more
    std.debug.print("\n=== Running until checksum done ===\n", .{});
    while (gen.m68k.pc >= 0x330 and gen.m68k.pc <= 0x340) {
        _ = gen.m68k.step(&gen.bus);
        gen.vdp.tick(8);
    }

    // Run more frames and check VDP state
    // Check all exception vectors
    std.debug.print("\nException vectors:\n", .{});
    std.debug.print("  HBlank (level 4) at $70: ${X:08}\n", .{gen.bus.read32(0x70)});
    std.debug.print("  VBlank (level 6) at $78: ${X:08}\n", .{gen.bus.read32(0x78)});
    std.debug.print("  TRAP #9 at $A4 (41*4): ${X:08}\n", .{gen.bus.read32(0xA4)});
    std.debug.print("  TRAP #0 at $80: ${X:08}\n", .{gen.bus.read32(0x80)});

    std.debug.print("\n=== Running frames ===\n", .{});
    var total_steps: u64 = 0;
    var in_ec0_region = false;
    var vblank_count: u32 = 0;
    var handler_steps: u32 = 0;
    for (0..300) |frame_idx| { // Run 300 frames to get past intro
        const start_frame = gen.vdp.frame;
        var step_count: u32 = 0;
        while (gen.vdp.frame == start_frame) {
            const old_pc = gen.m68k.pc;
            const old_a7 = gen.m68k.a[7];
            const opcode = gen.bus.read16(old_pc);

            const cycles = gen.step();

            // Count VBlank handler entries and trace first few
            if (gen.m68k.pc == 0x408 and old_pc != 0x408) {
                vblank_count += 1;
                if (vblank_count <= 1) {
                    std.debug.print("VBlank #{d}: cycles={d} scanline={d}\n", .{
                        vblank_count, cycles, gen.vdp.scanline,
                    });
                }
            }
            // Trace entire first VBlank handler execution
            if (vblank_count == 1) {
                handler_steps += 1;
                // Show cycles for first few loop iterations
                if (gen.m68k.pc >= 0x414 and gen.m68k.pc <= 0x420 and handler_steps < 20) {
                    std.debug.print("  loop: PC=${X:04} cycles={d}\n", .{ @as(u16, @truncate(gen.m68k.pc)), cycles });
                }
                if (gen.m68k.pc >= 0x460 or gen.m68k.pc < 0x400) {
                    std.debug.print("  Handler EXIT to PC=${X:06} after ~{d} steps, scanline={d}, vint={}\n", .{
                        gen.m68k.pc, step_count, gen.vdp.scanline, gen.vdp.vint_pending,
                    });
                    vblank_count = 99; // Skip further tracing
                }
            }
            // Track RTE when vint_pending is still true
            if (opcode == 0x4E73 and gen.vdp.vint_pending and vblank_count <= 5) {
                std.debug.print("RTE at ${X:06} with vint_pending still true!\n", .{old_pc});
            }

            // Track when we're in the $EC0xx region
            const now_in_ec0 = gen.m68k.pc >= 0xEC000 and gen.m68k.pc < 0xED000;
            if (now_in_ec0 and !in_ec0_region) {
                std.debug.print("ENTER $EC0xx at frame {d}: PC=${X:08}->${X:08} op=${X:04} A7=${X:08}\n", .{
                    frame_idx, old_pc, gen.m68k.pc, opcode, gen.m68k.a[7],
                });
            }
            if (!now_in_ec0 and in_ec0_region) {
                std.debug.print("EXIT $EC0xx at frame {d}: PC=${X:08}->${X:08} op=${X:04} A7=${X:08}\n", .{
                    frame_idx, old_pc, gen.m68k.pc, opcode, gen.m68k.a[7],
                });
            }
            // Check $FFFFFDF6 at entry
            if (now_in_ec0 and !in_ec0_region) {
                std.debug.print("  At entry: [$FFFFFDF6]=${X:08} [$FFFFFDFA]=${X:08} [$FFFFFDFC]=${X:08}\n", .{
                    gen.bus.read32(0xFFFFFDF6),
                    gen.bus.read32(0xFFFFDFA),
                    gen.bus.read32(0xFFFFFDFC),
                });
            }
            in_ec0_region = now_in_ec0;

            // Detailed trace in frame 16 when A7 is near the crash point
            if (frame_idx == 16 and old_a7 >= 0xFFFFFDF0 and old_a7 <= 0xFFFFFE00) {
                const is_call_ret = (opcode == 0x4E75) or ((opcode & 0xFF00) == 0x6100) or
                    ((opcode & 0xFFC0) == 0x4E80) or (opcode == 0x4EBA) or (opcode == 0x4EB9);
                if (is_call_ret) {
                    std.debug.print("frame16 step {d}: PC=${X:08} op=${X:04} A7=${X:08}->${X:08}\n", .{
                        step_count, old_pc, opcode, old_a7, gen.m68k.a[7],
                    });
                }
            }

            // Check for PC corruption
            if (gen.m68k.pc == 0 or gen.m68k.pc < 0x200) {
                std.debug.print("PC CORRUPTION at frame {d} step {d}: ${X:08} -> ${X:08}, op=${X:04}\n", .{
                    frame_idx, step_count, old_pc, gen.m68k.pc, opcode,
                });
                std.debug.print("  A7=${X:08} [A7-4]=${X:08} [A7]=${X:08}\n", .{
                    gen.m68k.a[7], gen.bus.read32(old_a7 -% 4), gen.bus.read32(old_a7),
                });
                break;
            }
            step_count += 1;
            total_steps += 1;
            if (step_count > 1000000) break;
        }
        if (gen.m68k.pc < 0x200) break;
    }

    std.debug.print("After 300 frames:\n", .{});
    std.debug.print("  VBlank handler entries: {d}\n", .{vblank_count});
    std.debug.print("  VDP vint_pending set: {d}\n", .{gen.vdp.debug_vint_set});
    std.debug.print("  VDP status reads: {d}\n", .{gen.vdp.debug_status_reads});
    std.debug.print("  VDP writes: ctrl={d} data={d} reg={d}\n", .{
        gen.vdp.debug_control_writes,
        gen.vdp.debug_data_writes,
        gen.vdp.debug_reg_writes,
    });
    std.debug.print("  VDP reg[0]=${X:02} reg[1]=${X:02}\n", .{ gen.vdp.regs[0], gen.vdp.regs[1] });
    std.debug.print("  Display enabled: {}\n", .{(gen.vdp.regs[1] & 0x40) != 0});

    // Check VRAM for non-zero data
    var vram_nonzero: u32 = 0;
    for (gen.vdp.vram) |b| {
        if (b != 0) vram_nonzero += 1;
    }
    std.debug.print("  VRAM non-zero bytes: {d}\n", .{vram_nonzero});

    // Check CRAM
    var cram_nonzero: u32 = 0;
    for (gen.vdp.cram) |c| {
        if (c != 0) cram_nonzero += 1;
    }
    std.debug.print("  CRAM non-zero entries: {d}\n", .{cram_nonzero});
    std.debug.print("  CRAM[0..16]: ", .{});
    for (0..16) |i| {
        std.debug.print("{X:02} ", .{gen.vdp.cram[i]});
    }
    std.debug.print("\n", .{});
    std.debug.print("  RAM[$FB00..16]: ", .{});
    for (0..16) |i| {
        std.debug.print("{X:02} ", .{gen.bus.ram[0xFB00 + i]});
    }
    std.debug.print("\n", .{});

    // Also trace instructions to see where we are
    std.debug.print("  PC=${X:06}\n", .{gen.m68k.pc});

    // Trace next few instructions to see what's happening
    std.debug.print("Tracing next 50 instructions:\n", .{});
    for (0..50) |i| {
        const pc = gen.m68k.pc;
        const opcode = gen.bus.read16(pc);
        _ = gen.m68k.step(&gen.bus);
        gen.vdp.tick(8);
        std.debug.print("{d:3}: PC=${X:06} op=${X:04} D0=${X:08} D1=${X:08}\n", .{
            i,
            pc,
            opcode,
            gen.m68k.d[0],
            gen.m68k.d[1],
        });
    }

    // Save screenshot
    try saveScreenshot(gen.getFrameBuffer(), "sonic_genesis.ppm");

    const non_black = countNonBlackPixels(gen.getFrameBuffer());
    std.debug.print("Non-black pixels: {d}\n", .{non_black});

    // Should have some rendering
    if (non_black < 1000) {
        std.debug.print("WARNING: Screen appears mostly black!\n", .{});
        const status = gen.vdp.readStatus();
        std.debug.print("VDP reg[0]=${X:02} reg[1]=${X:02} status=${X:04}\n", .{
            gen.vdp.regs[0],
            gen.vdp.regs[1],
            status,
        });
        std.debug.print("Display enabled: {}\n", .{(gen.vdp.regs[1] & 0x40) != 0});
        std.debug.print("Plane A base: ${X:04}, Plane B base: ${X:04}\n", .{
            @as(u16, gen.vdp.regs[2] & 0x38) << 10,
            @as(u16, gen.vdp.regs[4] & 0x07) << 13,
        });
        std.debug.print("DMA enabled: {}, DMA len: {d}\n", .{
            (gen.vdp.regs[1] & 0x10) != 0,
            @as(u16, gen.vdp.regs[19]) | (@as(u16, gen.vdp.regs[20]) << 8),
        });
        std.debug.print("VRAM non-zero bytes: {d}\n", .{vram_nonzero});
        std.debug.print("CRAM non-zero entries: {d}\n", .{cram_nonzero});
    }
}
