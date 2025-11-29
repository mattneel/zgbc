const std = @import("std");
const zgbc = @import("zgbc");
const M68K = zgbc.genesis.cpu.M68K;

// Simple test bus with RAM
const TestBus = struct {
    ram: [65536]u8 = [_]u8{0} ** 65536,

    pub fn read8(self: *TestBus, addr: u32) u8 {
        return self.ram[addr & 0xFFFF];
    }

    pub fn read16(self: *TestBus, addr: u32) u16 {
        const a = addr & 0xFFFE;
        return (@as(u16, self.ram[a]) << 8) | self.ram[a + 1];
    }

    pub fn read32(self: *TestBus, addr: u32) u32 {
        const hi = self.read16(addr);
        const lo = self.read16(addr + 2);
        return (@as(u32, hi) << 16) | lo;
    }

    pub fn write8(self: *TestBus, addr: u32, val: u8) void {
        self.ram[addr & 0xFFFF] = val;
    }

    pub fn write16(self: *TestBus, addr: u32, val: u16) void {
        const a = addr & 0xFFFE;
        self.ram[a] = @truncate(val >> 8);
        self.ram[a + 1] = @truncate(val);
    }

    pub fn write32(self: *TestBus, addr: u32, val: u32) void {
        self.write16(addr, @truncate(val >> 16));
        self.write16(addr + 2, @truncate(val));
    }

    fn loadCode(self: *TestBus, addr: u32, code: []const u16) void {
        var a = addr;
        for (code) |word| {
            self.write16(a, word);
            a += 2;
        }
    }
};

fn initCPU(bus: *TestBus) M68K {
    // Set up reset vector
    bus.write32(0, 0x1000); // SSP
    bus.write32(4, 0x100); // PC

    var cpu = M68K{};
    cpu.reset(bus);
    return cpu;
}

test "MOVEQ" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);

    // MOVEQ #$42, D0
    bus.write16(0x100, 0x7042);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0x42), cpu.d[0]);
    try std.testing.expectEqual(@as(u32, 0x102), cpu.pc);
}

test "MOVEQ negative" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);

    // MOVEQ #-1, D0 ($FF sign extended)
    bus.write16(0x100, 0x70FF);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), cpu.d[0]);
    try std.testing.expect(cpu.sr.n == true);
}

test "ADD.L Dn,Dn" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 100;
    cpu.d[1] = 200;

    // ADD.L D0, D1 (D1 = D1 + D0)
    bus.write16(0x100, 0xD280); // ADD.L D0, D1
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 300), cpu.d[1]);
}

test "SUB.L Dn,Dn" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 50;
    cpu.d[1] = 200;

    // SUB.L D0, D1 (D1 = D1 - D0)
    bus.write16(0x100, 0x9280); // SUB.L D0, D1
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 150), cpu.d[1]);
}

test "LEA" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);

    // LEA $1234, A0
    bus.write16(0x100, 0x41F9); // LEA (xxx).L, A0
    bus.write32(0x102, 0x00001234);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0x1234), cpu.a[0]);
}

test "LEA A5" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);

    // LEA $C00004, A5 (this is the exact opcode from Sonic 2)
    bus.write16(0x100, 0x4BF9); // LEA (xxx).L, A5
    bus.write32(0x102, 0x00C00004);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0x00C00004), cpu.a[5]);
    try std.testing.expectEqual(@as(u32, 0x106), cpu.pc);
}

test "MOVEA.L" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 0x12345678;

    // MOVEA.L D0, A0
    bus.write16(0x100, 0x2040); // MOVEA.L D0, A0
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0x12345678), cpu.a[0]);
}

test "CLR.L" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 0xFFFFFFFF;

    // CLR.L D0
    bus.write16(0x100, 0x4280);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0), cpu.d[0]);
    try std.testing.expect(cpu.sr.z == true);
}

test "BRA" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);

    // BRA.S +$10
    bus.write16(0x100, 0x6010);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0x112), cpu.pc);
}

test "BEQ taken" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.sr.z = true;

    // BEQ.S +$10
    bus.write16(0x100, 0x6710);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0x112), cpu.pc);
}

test "BEQ not taken" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.sr.z = false;

    // BEQ.S +$10
    bus.write16(0x100, 0x6710);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0x102), cpu.pc);
}

test "DBRA loop" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 3; // Loop 4 times (3, 2, 1, 0, then -1 exits)

    // DBRA D0, -2 (loop back to itself)
    bus.write16(0x100, 0x51C8);
    bus.write16(0x102, 0xFFFE); // -2 displacement

    var iterations: u32 = 0;
    while (cpu.d[0] != 0xFFFFFFFF and iterations < 10) {
        _ = cpu.step(&bus);
        iterations += 1;
        if (cpu.pc != 0x100) break; // Exited loop
    }

    try std.testing.expectEqual(@as(u32, 4), iterations);
}

test "JSR/RTS" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);

    // JSR $200
    bus.write16(0x100, 0x4EB9);
    bus.write32(0x102, 0x00000200);

    // RTS at $200
    bus.write16(0x200, 0x4E75);

    _ = cpu.step(&bus); // JSR
    try std.testing.expectEqual(@as(u32, 0x200), cpu.pc);

    _ = cpu.step(&bus); // RTS
    try std.testing.expectEqual(@as(u32, 0x106), cpu.pc);
}

test "BTST immediate" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 0b00001000; // Bit 3 set

    // BTST #3, D0
    bus.write16(0x100, 0x0800);
    bus.write16(0x102, 0x0003);
    _ = cpu.step(&bus);

    try std.testing.expect(cpu.sr.z == false); // Bit is set

    // BTST #4, D0
    cpu.pc = 0x100;
    bus.write16(0x102, 0x0004);
    _ = cpu.step(&bus);

    try std.testing.expect(cpu.sr.z == true); // Bit is clear
}

test "LSL/LSR" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 0x01;

    // LSL.L #4, D0
    bus.write16(0x100, 0xE988); // LSL.L #4, D0
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0x10), cpu.d[0]);

    // LSR.L #2, D0
    bus.write16(0x102, 0xE488); // LSR.L #2, D0
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0x04), cpu.d[0]);
}

test "CMP sets flags" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 100;
    cpu.d[1] = 100;

    // CMP.L D0, D1
    bus.write16(0x100, 0xB280);
    _ = cpu.step(&bus);

    try std.testing.expect(cpu.sr.z == true);
    try std.testing.expect(cpu.sr.n == false);
}

test "TST" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 0;

    // TST.L D0
    bus.write16(0x100, 0x4A80);
    _ = cpu.step(&bus);

    try std.testing.expect(cpu.sr.z == true);
    try std.testing.expect(cpu.sr.n == false);

    cpu.d[0] = 0x80000000;
    cpu.pc = 0x100;
    _ = cpu.step(&bus);

    try std.testing.expect(cpu.sr.z == false);
    try std.testing.expect(cpu.sr.n == true);
}

test "SWAP" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 0x12345678;

    // SWAP D0
    bus.write16(0x100, 0x4840);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0x56781234), cpu.d[0]);
}

test "EXT.W" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 0x000000FF; // -1 as byte

    // EXT.W D0
    bus.write16(0x100, 0x4880);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0x0000FFFF), cpu.d[0]);
}

test "EXT.L" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 0x0000FFFF; // -1 as word

    // EXT.L D0
    bus.write16(0x100, 0x48C0);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), cpu.d[0]);
}

test "NEG" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 1;

    // NEG.L D0
    bus.write16(0x100, 0x4480);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), cpu.d[0]);
}

test "NOT" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 0x00FF00FF;

    // NOT.L D0
    bus.write16(0x100, 0x4680);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0xFF00FF00), cpu.d[0]);
}

test "AND.L" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 0xFF00FF00;
    cpu.d[1] = 0x0F0F0F0F;

    // AND.L D0, D1
    bus.write16(0x100, 0xC280);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0x0F000F00), cpu.d[1]);
}

test "OR.L" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 0xFF00FF00;
    cpu.d[1] = 0x00FF00FF;

    // OR.L D0, D1
    bus.write16(0x100, 0x8280);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), cpu.d[1]);
}

test "EOR.L" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 0xFFFFFFFF;
    cpu.d[1] = 0x0F0F0F0F;

    // EOR.L D0, D1 -> D1 = D1 ^ D0
    // EOR Dn,<ea>: 1011 rrr 110 mmm rrr where rrr(11-9)=src, mmm/rrr=dest
    // D0 (src=0), D1 (mode=0,reg=1): 1011 000 110 000 001 = 0xB181
    bus.write16(0x100, 0xB181);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 0xF0F0F0F0), cpu.d[1]);
}

test "ADDQ" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 10;

    // ADDQ.L #5, D0
    bus.write16(0x100, 0x5A80);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 15), cpu.d[0]);
}

test "SUBQ" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 10;

    // SUBQ.L #3, D0
    bus.write16(0x100, 0x5780);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 7), cpu.d[0]);
}

test "MULU" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 100;
    cpu.d[1] = 200;

    // MULU D0, D1 (D1 = D1.w * D0.w)
    bus.write16(0x100, 0xC2C0);
    _ = cpu.step(&bus);

    try std.testing.expectEqual(@as(u32, 20000), cpu.d[1]);
}

test "DIVU" {
    var bus = TestBus{};
    var cpu = initCPU(&bus);
    cpu.d[0] = 7;
    cpu.d[1] = 100;

    // DIVU D0, D1 (D1 = D1 / D0, remainder in upper word)
    bus.write16(0x100, 0x82C0);
    _ = cpu.step(&bus);

    // Result: quotient = 14, remainder = 2
    try std.testing.expectEqual(@as(u32, (2 << 16) | 14), cpu.d[1]);
}
