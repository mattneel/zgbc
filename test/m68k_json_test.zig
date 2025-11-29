const std = @import("std");
const zgbc = @import("zgbc");
const M68K = zgbc.genesis.cpu.M68K;

const TestBus = struct {
    ram: [1 << 20]u8 = undefined, // 1MB address space

    pub fn init() TestBus {
        var bus = TestBus{};
        @memset(&bus.ram, 0);
        return bus;
    }

    pub fn read8(self: *TestBus, addr: u32) u8 {
        return self.ram[addr & 0xFFFFF];
    }

    pub fn read16(self: *TestBus, addr: u32) u16 {
        const a = addr & 0xFFFFE;
        return (@as(u16, self.ram[a]) << 8) | self.ram[a + 1];
    }

    pub fn read32(self: *TestBus, addr: u32) u32 {
        return (@as(u32, self.read16(addr)) << 16) | self.read16(addr + 2);
    }

    pub fn write8(self: *TestBus, addr: u32, val: u8) void {
        self.ram[addr & 0xFFFFF] = val;
    }

    pub fn write16(self: *TestBus, addr: u32, val: u16) void {
        const a = addr & 0xFFFFE;
        self.ram[a] = @truncate(val >> 8);
        self.ram[a + 1] = @truncate(val);
    }

    pub fn write32(self: *TestBus, addr: u32, val: u32) void {
        self.write16(addr, @truncate(val >> 16));
        self.write16(addr + 2, @truncate(val));
    }
};

fn runTestFile(comptime filename: []const u8) !void {
    const json_data = @embedFile(filename);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_data, .{});
    defer parsed.deinit();

    const tests = parsed.value.array;
    var passed: usize = 0;
    var failed: usize = 0;

    for (tests.items) |test_case| {
        const obj = test_case.object;
        const name = obj.get("name").?.string;
        const initial = obj.get("initial").?.object;
        const final = obj.get("final").?.object;

        // Set up CPU and bus
        var bus = TestBus.init();
        var cpu = M68K{};

        // Load initial state
        cpu.d[0] = @intCast(initial.get("d0").?.integer);
        cpu.d[1] = @intCast(initial.get("d1").?.integer);
        cpu.d[2] = @intCast(initial.get("d2").?.integer);
        cpu.d[3] = @intCast(initial.get("d3").?.integer);
        cpu.d[4] = @intCast(initial.get("d4").?.integer);
        cpu.d[5] = @intCast(initial.get("d5").?.integer);
        cpu.d[6] = @intCast(initial.get("d6").?.integer);
        cpu.d[7] = @intCast(initial.get("d7").?.integer);
        cpu.a[0] = @intCast(initial.get("a0").?.integer);
        cpu.a[1] = @intCast(initial.get("a1").?.integer);
        cpu.a[2] = @intCast(initial.get("a2").?.integer);
        cpu.a[3] = @intCast(initial.get("a3").?.integer);
        cpu.a[4] = @intCast(initial.get("a4").?.integer);
        cpu.a[5] = @intCast(initial.get("a5").?.integer);
        cpu.a[6] = @intCast(initial.get("a6").?.integer);
        cpu.usp = @intCast(initial.get("usp").?.integer);
        cpu.ssp = @intCast(initial.get("ssp").?.integer);
        cpu.sr = @bitCast(@as(u16, @intCast(initial.get("sr").?.integer)));
        cpu.pc = @intCast(initial.get("pc").?.integer);

        // Set A7 based on supervisor mode
        cpu.a[7] = if (cpu.sr.s) cpu.ssp else cpu.usp;

        // Load initial RAM
        const init_ram = initial.get("ram").?.array;
        for (init_ram.items) |entry| {
            const arr = entry.array;
            const addr: u32 = @intCast(arr.items[0].integer);
            const val: u8 = @intCast(arr.items[1].integer);
            bus.ram[addr & 0xFFFFF] = val;
        }

        // Load prefetch into RAM at PC
        const prefetch = initial.get("prefetch").?.array;
        if (prefetch.items.len >= 1) {
            const w0: u16 = @intCast(prefetch.items[0].integer);
            bus.write16(cpu.pc, w0);
        }
        if (prefetch.items.len >= 2) {
            const w1: u16 = @intCast(prefetch.items[1].integer);
            bus.write16(cpu.pc + 2, w1);
        }

        // Debug first test
        if (passed == 0 and failed == 0) {
            std.debug.print("Test: {s}\n", .{name});
            std.debug.print("  Initial: PC=${X:08} A0=${X:08} SSP=${X:08} A7=${X:08}\n", .{ cpu.pc, cpu.a[0], cpu.ssp, cpu.a[7] });
            std.debug.print("  Opcode at PC: ${X:04}\n", .{bus.read16(cpu.pc)});
        }

        // Execute one instruction
        _ = cpu.step(&bus);

        // Update ssp/usp based on which one was modified
        if (cpu.sr.s) {
            cpu.ssp = cpu.a[7];
        } else {
            cpu.usp = cpu.a[7];
        }

        if (passed == 0 and failed == 0) {
            std.debug.print("  After: PC=${X:08} A7=${X:08} SSP=${X:08}\n", .{ cpu.pc, cpu.a[7], cpu.ssp });
        }

        // Check final state
        var test_passed = true;

        const exp_pc: u32 = @intCast(final.get("pc").?.integer);
        const exp_ssp: u32 = @intCast(final.get("ssp").?.integer);
        const exp_sr: u16 = @intCast(final.get("sr").?.integer);

        if (cpu.pc != exp_pc) {
            if (failed < 10) std.debug.print("FAIL {s}: PC expected ${X:08} got ${X:08}\n", .{ name, exp_pc, cpu.pc });
            test_passed = false;
        }
        if (cpu.ssp != exp_ssp) {
            if (failed < 10) std.debug.print("FAIL {s}: SSP expected ${X:08} got ${X:08}\n", .{ name, exp_ssp, cpu.ssp });
            test_passed = false;
        }
        if (@as(u16, @bitCast(cpu.sr)) != exp_sr) {
            if (failed < 10) std.debug.print("FAIL {s}: SR expected ${X:04} got ${X:04}\n", .{ name, exp_sr, @as(u16, @bitCast(cpu.sr)) });
            test_passed = false;
        }

        // Check RAM
        const final_ram = final.get("ram").?.array;
        for (final_ram.items) |entry| {
            const arr = entry.array;
            const addr: u32 = @intCast(arr.items[0].integer);
            const exp_val: u8 = @intCast(arr.items[1].integer);
            const got_val = bus.ram[addr & 0xFFFFF];
            if (got_val != exp_val) {
                if (failed < 10) std.debug.print("FAIL {s}: RAM[${X:06}] expected ${X:02} got ${X:02}\n", .{ name, addr, exp_val, got_val });
                test_passed = false;
            }
        }

        if (test_passed) {
            passed += 1;
        } else {
            failed += 1;
        }

        // Stop early if too many failures
        if (failed >= 20) break;
    }

    std.debug.print("{s}: {d} passed, {d} failed\n", .{ filename, passed, failed });
    if (failed > 0) {
        return error.TestFailed;
    }
}

test "JSR" {
    try runTestFile("roms/68000/JSR.json");
}

test "RTS" {
    try runTestFile("roms/68000/RTS.json");
}

test "BSR" {
    try runTestFile("roms/68000/BSR.json");
}

test "MOVEM.l" {
    try runTestFile("roms/68000/MOVEM.l.json");
}
