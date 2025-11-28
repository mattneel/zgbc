//! SIMD Batch Executor
//! Runs multiple GB instances in lock-step using SIMD operations.

const std = @import("std");
const GB = @import("gb.zig").GB;
const CPU = @import("cpu.zig").CPU;
const MMU = @import("mmu.zig").MMU;

pub const BATCH_SIZE = 16;
const Vec16u8 = @Vector(BATCH_SIZE, u8);
const Vec16u16 = @Vector(BATCH_SIZE, u16);
const Vec16i8 = @Vector(BATCH_SIZE, i8);

/// SIMD-friendly CPU state (SoA layout)
pub const BatchCPU = struct {
    // Registers as vectors - each lane is one instance
    a: Vec16u8 = @splat(0),
    b: Vec16u8 = @splat(0),
    c: Vec16u8 = @splat(0),
    d: Vec16u8 = @splat(0),
    e: Vec16u8 = @splat(0),
    h: Vec16u8 = @splat(0),
    l: Vec16u8 = @splat(0),

    // Flags as separate vectors (better than packed for SIMD)
    flag_z: Vec16u8 = @splat(0), // 0 or 1
    flag_n: Vec16u8 = @splat(0),
    flag_h: Vec16u8 = @splat(0),
    flag_c: Vec16u8 = @splat(0),

    sp: Vec16u16 = @splat(0xFFFE),
    pc: Vec16u16 = @splat(0x0100),

    ime: Vec16u8 = @splat(0),
    halted: Vec16u8 = @splat(0),

    /// Load from array of scalar CPUs
    pub fn loadFrom(cpus: *const [BATCH_SIZE]CPU) BatchCPU {
        var batch: BatchCPU = .{};
        inline for (0..BATCH_SIZE) |i| {
            batch.a[i] = cpus[i].a;
            batch.b[i] = cpus[i].b;
            batch.c[i] = cpus[i].c;
            batch.d[i] = cpus[i].d;
            batch.e[i] = cpus[i].e;
            batch.h[i] = cpus[i].h;
            batch.l[i] = cpus[i].l;
            batch.flag_z[i] = @intFromBool(cpus[i].f.z);
            batch.flag_n[i] = @intFromBool(cpus[i].f.n);
            batch.flag_h[i] = @intFromBool(cpus[i].f.h);
            batch.flag_c[i] = @intFromBool(cpus[i].f.c);
            batch.sp[i] = cpus[i].sp;
            batch.pc[i] = cpus[i].pc;
            batch.ime[i] = @intFromBool(cpus[i].ime);
            batch.halted[i] = @intFromBool(cpus[i].halted);
        }
        return batch;
    }

    /// Store back to array of scalar CPUs
    pub fn storeTo(self: *const BatchCPU, cpus: *[BATCH_SIZE]CPU) void {
        inline for (0..BATCH_SIZE) |i| {
            cpus[i].a = self.a[i];
            cpus[i].b = self.b[i];
            cpus[i].c = self.c[i];
            cpus[i].d = self.d[i];
            cpus[i].e = self.e[i];
            cpus[i].h = self.h[i];
            cpus[i].l = self.l[i];
            cpus[i].f.z = self.flag_z[i] != 0;
            cpus[i].f.n = self.flag_n[i] != 0;
            cpus[i].f.h = self.flag_h[i] != 0;
            cpus[i].f.c = self.flag_c[i] != 0;
            cpus[i].sp = self.sp[i];
            cpus[i].pc = self.pc[i];
            cpus[i].ime = self.ime[i] != 0;
            cpus[i].halted = self.halted[i] != 0;
        }
    }

    /// SIMD ADD A, r - adds value to A register across all instances
    pub fn addA(self: *BatchCPU, val: Vec16u8) void {
        const result = @addWithOverflow(self.a, val);
        const sum = result[0];
        const carry = result[1];

        // Half-carry: (a & 0xF) + (val & 0xF) > 0xF
        const half = ((self.a & @as(Vec16u8, @splat(0x0F))) +%
            (val & @as(Vec16u8, @splat(0x0F)))) >> @splat(4);

        self.a = sum;
        self.flag_z = @select(u8, sum == @as(Vec16u8, @splat(0)), @as(Vec16u8, @splat(1)), @as(Vec16u8, @splat(0)));
        self.flag_n = @splat(0);
        self.flag_h = half & @as(Vec16u8, @splat(1));
        self.flag_c = carry;
    }

    /// SIMD SUB A, r
    pub fn subA(self: *BatchCPU, val: Vec16u8) void {
        const result = @subWithOverflow(self.a, val);
        const diff = result[0];
        const borrow = result[1];

        // Half-borrow
        const half_borrow: Vec16u8 = @select(u8,
            (self.a & @as(Vec16u8, @splat(0x0F))) < (val & @as(Vec16u8, @splat(0x0F))),
            @as(Vec16u8, @splat(1)),
            @as(Vec16u8, @splat(0)));

        self.a = diff;
        self.flag_z = @select(u8, diff == @as(Vec16u8, @splat(0)), @as(Vec16u8, @splat(1)), @as(Vec16u8, @splat(0)));
        self.flag_n = @splat(1);
        self.flag_h = half_borrow;
        self.flag_c = borrow;
    }

    /// SIMD INC r (generic for any register)
    pub fn inc(reg: *Vec16u8, flag_z: *Vec16u8, flag_h: *Vec16u8, flag_n: *Vec16u8) void {
        const half = (reg.* & @as(Vec16u8, @splat(0x0F))) == @as(Vec16u8, @splat(0x0F));
        reg.* +%= @splat(1);
        flag_z.* = @select(u8, reg.* == @as(Vec16u8, @splat(0)), @as(Vec16u8, @splat(1)), @as(Vec16u8, @splat(0)));
        flag_n.* = @splat(0);
        flag_h.* = @select(u8, half, @as(Vec16u8, @splat(1)), @as(Vec16u8, @splat(0)));
    }

    /// SIMD DEC r
    pub fn dec(reg: *Vec16u8, flag_z: *Vec16u8, flag_h: *Vec16u8, flag_n: *Vec16u8) void {
        const half = (reg.* & @as(Vec16u8, @splat(0x0F))) == @as(Vec16u8, @splat(0));
        reg.* -%= @splat(1);
        flag_z.* = @select(u8, reg.* == @as(Vec16u8, @splat(0)), @as(Vec16u8, @splat(1)), @as(Vec16u8, @splat(0)));
        flag_n.* = @splat(1);
        flag_h.* = @select(u8, half, @as(Vec16u8, @splat(1)), @as(Vec16u8, @splat(0)));
    }

    /// Get HL register pair as vector
    pub fn getHL(self: *const BatchCPU) Vec16u16 {
        return (@as(Vec16u16, self.h) << @splat(8)) | @as(Vec16u16, self.l);
    }

    /// Set HL register pair from vector
    pub fn setHL(self: *BatchCPU, val: Vec16u16) void {
        self.h = @truncate(val >> @splat(8));
        self.l = @truncate(val);
    }
};

/// Check if all instances have the same PC (can execute in lock-step)
pub fn canLockStep(batch: *const BatchCPU) bool {
    const first_pc = batch.pc[0];
    return @reduce(.And, batch.pc == @as(Vec16u16, @splat(first_pc)));
}

/// Batch memory read - gather operation
pub fn batchRead(mmus: *[BATCH_SIZE]MMU, addrs: Vec16u16) Vec16u8 {
    var result: Vec16u8 = undefined;
    inline for (0..BATCH_SIZE) |i| {
        result[i] = mmus[i].read(addrs[i]);
    }
    return result;
}

/// Batch memory write - scatter operation
pub fn batchWrite(mmus: *[BATCH_SIZE]MMU, addrs: Vec16u16, vals: Vec16u8) void {
    inline for (0..BATCH_SIZE) |i| {
        mmus[i].write(addrs[i], vals[i]);
    }
}

test "batch cpu load/store roundtrip" {
    var cpus: [BATCH_SIZE]CPU = undefined;
    for (&cpus, 0..) |*cpu, i| {
        cpu.* = .{};
        cpu.a = @intCast(i);
        cpu.b = @intCast(i * 2);
    }

    const batch = BatchCPU.loadFrom(&cpus);

    try std.testing.expectEqual(@as(u8, 0), batch.a[0]);
    try std.testing.expectEqual(@as(u8, 15), batch.a[15]);

    var cpus2: [BATCH_SIZE]CPU = undefined;
    batch.storeTo(&cpus2);

    try std.testing.expectEqual(@as(u8, 0), cpus2[0].a);
    try std.testing.expectEqual(@as(u8, 15), cpus2[15].a);
}

test "simd add" {
    var batch = BatchCPU{};
    batch.a = @splat(0x0F);
    batch.addA(@splat(0x01));

    try std.testing.expectEqual(@as(u8, 0x10), batch.a[0]);
    try std.testing.expectEqual(@as(u8, 0), batch.flag_z[0]); // not zero
    try std.testing.expectEqual(@as(u8, 1), batch.flag_h[0]); // half carry
    try std.testing.expectEqual(@as(u8, 0), batch.flag_c[0]); // no carry
}

test "simd inc" {
    var batch = BatchCPU{};
    batch.b = @splat(0xFF);
    BatchCPU.inc(&batch.b, &batch.flag_z, &batch.flag_h, &batch.flag_n);

    try std.testing.expectEqual(@as(u8, 0), batch.b[0]);
    try std.testing.expectEqual(@as(u8, 1), batch.flag_z[0]); // zero
    try std.testing.expectEqual(@as(u8, 1), batch.flag_h[0]); // half carry
}

// =============================================================================
// Micro-benchmarks for SIMD vs Scalar ALU operations
// =============================================================================

const Flags = @import("cpu.zig").Flags;

/// Scalar ADD A, n with flag computation
fn scalarAdd(a: *u8, f: *Flags, val: u8) void {
    const result = @addWithOverflow(a.*, val);
    const half = ((a.* & 0x0F) + (val & 0x0F)) > 0x0F;
    a.* = result[0];
    f.z = a.* == 0;
    f.n = false;
    f.h = half;
    f.c = result[1] == 1;
}

/// Benchmark: Compare SIMD vs Scalar ADD operations
pub fn benchmarkALU() !void {
    const iterations = 10_000_000;

    // Scalar benchmark
    var scalar_sum: u64 = 0;
    var scalar_timer = try std.time.Timer.start();
    {
        var cpus: [BATCH_SIZE]CPU = undefined;
        for (&cpus) |*cpu| cpu.* = .{};

        for (0..iterations) |i| {
            const val: u8 = @truncate(i);
            for (&cpus) |*cpu| {
                scalarAdd(&cpu.a, &cpu.f, val);
            }
        }
        // Prevent dead code elimination
        for (&cpus) |*cpu| scalar_sum += cpu.a;
    }
    const scalar_ns = scalar_timer.read();

    // SIMD benchmark
    var simd_sum: u64 = 0;
    var simd_timer = try std.time.Timer.start();
    {
        var batch = BatchCPU{};

        for (0..iterations) |i| {
            const val: u8 = @truncate(i);
            batch.addA(@splat(val));
        }
        // Prevent dead code elimination
        simd_sum = @reduce(.Add, @as(@Vector(BATCH_SIZE, u64), batch.a));
    }
    const simd_ns = simd_timer.read();

    const scalar_ms = @as(f64, @floatFromInt(scalar_ns)) / 1_000_000.0;
    const simd_ms = @as(f64, @floatFromInt(simd_ns)) / 1_000_000.0;
    const speedup = scalar_ms / simd_ms;

    std.debug.print("\n=== SIMD ALU Micro-benchmark ===\n", .{});
    std.debug.print("Operations: {} ADD across {} instances\n", .{ iterations, BATCH_SIZE });
    std.debug.print("Scalar: {d:.2}ms ({d} checksum)\n", .{ scalar_ms, scalar_sum });
    std.debug.print("SIMD:   {d:.2}ms ({d} checksum)\n", .{ simd_ms, simd_sum });
    std.debug.print("Speedup: {d:.2}x\n", .{speedup});
}
