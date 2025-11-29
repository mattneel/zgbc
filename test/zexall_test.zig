//! ZEXALL Z80 instruction exerciser test
//! Tests all Z80 instructions for correctness.

const std = @import("std");
const sms = @import("sms");
const CPU = sms.sms.cpu.CPU;

/// Minimal bus for CP/M environment - just RAM, no peripherals needed
const TestBus = struct {
    ram: [65536]u8 = [_]u8{0} ** 65536,

    pub fn read(self: *TestBus, addr: u16) u8 {
        return self.ram[addr];
    }

    pub fn write(self: *TestBus, addr: u16, val: u8) void {
        self.ram[addr] = val;
    }

    pub fn ioRead(self: *TestBus, port: u8) u8 {
        _ = self;
        _ = port;
        return 0xFF;
    }

    pub fn ioWrite(self: *TestBus, port: u8, val: u8) void {
        _ = self;
        _ = port;
        _ = val;
    }
};

/// Run ZEXALL and return output
pub fn runZexall(output_buf: []u8) struct { len: usize, cycles: u64, done: bool } {
    // Load ZEXALL
    const rom = @embedFile("sms-test-roms/zexall.com");

    var bus = TestBus{};

    // Load program at 0x0100 (CP/M TPA)
    @memcpy(bus.ram[0x100..][0..rom.len], rom);

    // Set up CP/M environment
    bus.ram[0x0000] = 0xC3; // JP 0x0000 (warm boot - exit)
    bus.ram[0x0001] = 0x00;
    bus.ram[0x0002] = 0x00;
    bus.ram[0x0005] = 0xC9; // RET (we'll intercept before this)

    // Initialize CPU
    var cpu = CPU{};
    cpu.pc = 0x0100;
    cpu.sp = 0xF000;

    var output_len: usize = 0;
    var cycles: u64 = 0;
    const max_cycles: u64 = 50_000_000_000; // 50 billion cycles max
    var done = false;

    while (!done and cycles < max_cycles) {
        // Check for BDOS call
        if (cpu.pc == 0x0005) {
            // Handle BDOS functions
            switch (cpu.c) {
                2 => {
                    // Console output - character in E
                    if (output_len < output_buf.len) {
                        output_buf[output_len] = cpu.e;
                        output_len += 1;
                    }
                },
                9 => {
                    // Print string at DE until '$'
                    var addr = cpu.getDE();
                    while (bus.ram[addr] != '$') {
                        if (output_len < output_buf.len) {
                            output_buf[output_len] = bus.ram[addr];
                            output_len += 1;
                        }
                        addr +%= 1;
                    }
                },
                else => {},
            }
            // Return from BDOS - inline pop since Bus type doesn't match
            const lo = bus.read(cpu.sp);
            cpu.sp +%= 1;
            const hi = bus.read(cpu.sp);
            cpu.sp +%= 1;
            cpu.pc = (@as(u16, hi) << 8) | lo;
        } else if (cpu.pc == 0x0000) {
            // Warm boot - program done
            done = true;
        } else {
            cycles += cpu.step(&bus);
        }
    }

    return .{ .len = output_len, .cycles = cycles, .done = done };
}

test "zexall" {
    var output: [65536]u8 = undefined;
    const result = runZexall(&output);

    // Check for completion
    if (!result.done) {
        std.debug.print("\nZEXALL did not complete. Cycles: {d}, Output:\n{s}\n", .{
            result.cycles,
            output[0..@min(result.len, 4000)],
        });
        return error.TestDidNotComplete;
    }

    const out = output[0..result.len];
    const has_error = std.mem.indexOf(u8, out, "ERROR") != null;

    if (has_error) {
        std.debug.print("\nZEXALL FAILED:\n{s}\n", .{out});
        return error.ZexallFailed;
    }

    // Verify we actually ran to completion
    try std.testing.expect(std.mem.indexOf(u8, out, "Tests complete") != null);
}
