//! LR35902 CPU (Sharp SM83 core)
//! Opcodes implemented via comptime table generation.

const std = @import("std");
const MMU = @import("mmu.zig").MMU;

pub const Flags = packed struct(u8) {
    _: u4 = 0,
    c: bool = false,
    h: bool = false,
    n: bool = false,
    z: bool = false,

    pub fn toU8(self: Flags) u8 {
        return @bitCast(self);
    }

    pub fn fromU8(val: u8) Flags {
        return @bitCast(val & 0xF0);
    }
};

pub const CPU = struct {
    a: u8 = 0,
    f: Flags = .{},
    b: u8 = 0,
    c: u8 = 0,
    d: u8 = 0,
    e: u8 = 0,
    h: u8 = 0,
    l: u8 = 0,
    sp: u16 = 0xFFFE,
    pc: u16 = 0x0100,

    ime: bool = false,
    halted: bool = false,
    halt_bug: bool = false,
    ime_scheduled: bool = false,

    pub fn getAF(self: *const CPU) u16 {
        return (@as(u16, self.a) << 8) | self.f.toU8();
    }
    pub fn setAF(self: *CPU, val: u16) void {
        self.a = @truncate(val >> 8);
        self.f = Flags.fromU8(@truncate(val));
    }
    pub fn getBC(self: *const CPU) u16 {
        return (@as(u16, self.b) << 8) | self.c;
    }
    pub fn setBC(self: *CPU, val: u16) void {
        self.b = @truncate(val >> 8);
        self.c = @truncate(val);
    }
    pub fn getDE(self: *const CPU) u16 {
        return (@as(u16, self.d) << 8) | self.e;
    }
    pub fn setDE(self: *CPU, val: u16) void {
        self.d = @truncate(val >> 8);
        self.e = @truncate(val);
    }
    pub fn getHL(self: *const CPU) u16 {
        return (@as(u16, self.h) << 8) | self.l;
    }
    pub fn setHL(self: *CPU, val: u16) void {
        self.h = @truncate(val >> 8);
        self.l = @truncate(val);
    }

    pub fn step(self: *CPU, mmu: *MMU) u8 {
        if (self.ime_scheduled) {
            self.ime_scheduled = false;
            self.ime = true;
        }

        if (self.ime) {
            const pending = mmu.ie & mmu.if_ & 0x1F;
            if (pending != 0) {
                return self.handleInterrupt(mmu, pending);
            }
        }

        if (self.halted) {
            if ((mmu.ie & mmu.if_ & 0x1F) != 0) {
                self.halted = false;
            } else {
                return 4;
            }
        }

        const opcode = self.fetch(mmu);
        return opcodes[opcode](self, mmu);
    }


    pub fn fetch(self: *CPU, mmu: *MMU) u8 {
        const val = mmu.read(self.pc);
        if (!self.halt_bug) {
            self.pc +%= 1;
        } else {
            self.halt_bug = false;
        }
        return val;
    }

    pub fn fetchWord(self: *CPU, mmu: *MMU) u16 {
        const lo = self.fetch(mmu);
        const hi = self.fetch(mmu);
        return (@as(u16, hi) << 8) | lo;
    }

    fn handleInterrupt(self: *CPU, mmu: *MMU, pending: u8) u8 {
        self.ime = false;
        self.halted = false;
        const int_bit: u3 = @intCast(@ctz(pending));
        const vector: u16 = 0x0040 + @as(u16, int_bit) * 8;
        mmu.if_ &= ~(@as(u8, 1) << int_bit);
        self.push(mmu, self.pc);
        self.pc = vector;
        return 20;
    }

    pub fn push(self: *CPU, mmu: *MMU, val: u16) void {
        self.sp -%= 1;
        mmu.write(self.sp, @truncate(val >> 8));
        self.sp -%= 1;
        mmu.write(self.sp, @truncate(val));
    }

    pub fn pop(self: *CPU, mmu: *MMU) u16 {
        const lo = mmu.read(self.sp);
        self.sp +%= 1;
        const hi = mmu.read(self.sp);
        self.sp +%= 1;
        return (@as(u16, hi) << 8) | lo;
    }

    // Register access by 3-bit index: 0=B,1=C,2=D,3=E,4=H,5=L,6=(HL),7=A
    pub fn getReg(self: *CPU, mmu: *MMU, comptime idx: u3) u8 {
        return switch (idx) {
            0 => self.b,
            1 => self.c,
            2 => self.d,
            3 => self.e,
            4 => self.h,
            5 => self.l,
            6 => mmu.read(self.getHL()),
            7 => self.a,
        };
    }

    pub fn setReg(self: *CPU, mmu: *MMU, comptime idx: u3, val: u8) void {
        switch (idx) {
            0 => self.b = val,
            1 => self.c = val,
            2 => self.d = val,
            3 => self.e = val,
            4 => self.h = val,
            5 => self.l = val,
            6 => mmu.write(self.getHL(), val),
            7 => self.a = val,
        }
    }

    // 16-bit register pair access: 0=BC,1=DE,2=HL,3=SP (for most ops) or AF (for push/pop)
    pub fn getRp(self: *CPU, comptime idx: u2) u16 {
        return switch (idx) {
            0 => self.getBC(),
            1 => self.getDE(),
            2 => self.getHL(),
            3 => self.sp,
        };
    }

    pub fn setRp(self: *CPU, comptime idx: u2, val: u16) void {
        switch (idx) {
            0 => self.setBC(val),
            1 => self.setDE(val),
            2 => self.setHL(val),
            3 => self.sp = val,
        }
    }

    // ALU operations
    pub fn aluAdd(self: *CPU, val: u8, carry: bool) void {
        const c: u8 = if (carry and self.f.c) 1 else 0;
        const result = @as(u16, self.a) + val + c;
        const half = (self.a & 0xF) + (val & 0xF) + c;
        self.a = @truncate(result);
        self.f = .{ .z = self.a == 0, .n = false, .h = half > 0xF, .c = result > 0xFF };
    }

    pub fn aluSub(self: *CPU, val: u8, carry: bool) void {
        const c: u8 = if (carry and self.f.c) 1 else 0;
        const result = @as(i16, self.a) - val - c;
        const half = @as(i16, self.a & 0xF) - (val & 0xF) - c;
        self.a = @truncate(@as(u16, @bitCast(result)));
        self.f = .{ .z = self.a == 0, .n = true, .h = half < 0, .c = result < 0 };
    }

    pub fn aluAnd(self: *CPU, val: u8) void {
        self.a &= val;
        self.f = .{ .z = self.a == 0, .n = false, .h = true, .c = false };
    }

    pub fn aluXor(self: *CPU, val: u8) void {
        self.a ^= val;
        self.f = .{ .z = self.a == 0, .n = false, .h = false, .c = false };
    }

    pub fn aluOr(self: *CPU, val: u8) void {
        self.a |= val;
        self.f = .{ .z = self.a == 0, .n = false, .h = false, .c = false };
    }

    pub fn aluCp(self: *CPU, val: u8) void {
        const result = @as(i16, self.a) - val;
        const half = @as(i16, self.a & 0xF) - (val & 0xF);
        self.f = .{ .z = self.a == val, .n = true, .h = half < 0, .c = result < 0 };
    }

    pub fn aluInc(self: *CPU, val: u8) u8 {
        const result = val +% 1;
        self.f.z = result == 0;
        self.f.n = false;
        self.f.h = (val & 0xF) == 0xF;
        return result;
    }

    pub fn aluDec(self: *CPU, val: u8) u8 {
        const result = val -% 1;
        self.f.z = result == 0;
        self.f.n = true;
        self.f.h = (val & 0xF) == 0;
        return result;
    }

    // Rotate/shift operations
    pub fn rlc(self: *CPU, val: u8) u8 {
        const carry = val >> 7;
        const result = (val << 1) | carry;
        self.f = .{ .z = result == 0, .n = false, .h = false, .c = carry != 0 };
        return result;
    }

    pub fn rrc(self: *CPU, val: u8) u8 {
        const carry = val & 1;
        const result = (val >> 1) | (carry << 7);
        self.f = .{ .z = result == 0, .n = false, .h = false, .c = carry != 0 };
        return result;
    }

    pub fn rl(self: *CPU, val: u8) u8 {
        const carry = val >> 7;
        const result = (val << 1) | @as(u8, if (self.f.c) 1 else 0);
        self.f = .{ .z = result == 0, .n = false, .h = false, .c = carry != 0 };
        return result;
    }

    pub fn rr(self: *CPU, val: u8) u8 {
        const carry = val & 1;
        const result = (val >> 1) | (@as(u8, if (self.f.c) 1 else 0) << 7);
        self.f = .{ .z = result == 0, .n = false, .h = false, .c = carry != 0 };
        return result;
    }

    pub fn sla(self: *CPU, val: u8) u8 {
        const carry = val >> 7;
        const result = val << 1;
        self.f = .{ .z = result == 0, .n = false, .h = false, .c = carry != 0 };
        return result;
    }

    pub fn sra(self: *CPU, val: u8) u8 {
        const carry = val & 1;
        const result = @as(u8, @bitCast(@as(i8, @bitCast(val)) >> 1));
        self.f = .{ .z = result == 0, .n = false, .h = false, .c = carry != 0 };
        return result;
    }

    pub fn swap(self: *CPU, val: u8) u8 {
        const result = (val >> 4) | (val << 4);
        self.f = .{ .z = result == 0, .n = false, .h = false, .c = false };
        return result;
    }

    pub fn srl(self: *CPU, val: u8) u8 {
        const carry = val & 1;
        const result = val >> 1;
        self.f = .{ .z = result == 0, .n = false, .h = false, .c = carry != 0 };
        return result;
    }

    pub fn bit(self: *CPU, b: u3, val: u8) void {
        self.f.z = (val >> b) & 1 == 0;
        self.f.n = false;
        self.f.h = true;
    }

    pub fn checkCondition(self: *CPU, comptime cc: u2) bool {
        return switch (cc) {
            0 => !self.f.z, // NZ
            1 => self.f.z, // Z
            2 => !self.f.c, // NC
            3 => self.f.c, // C
        };
    }
};

// =============================================================================
// Opcode Handlers
// =============================================================================

const Handler = *const fn (*CPU, *MMU) u8;

fn unimplemented(cpu: *CPU, mmu: *MMU) u8 {
    _ = mmu;
    _ = cpu;
    return 4;
}

// --- Generator functions for pattern-based opcodes ---

fn genLdRR(comptime d: u3, comptime s: u3) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            cpu.setReg(mmu, d, cpu.getReg(mmu, s));
            return if (d == 6 or s == 6) 8 else 4;
        }
    }.f;
}

fn genAluR(comptime op: u3, comptime r: u3) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            const val = cpu.getReg(mmu, r);
            switch (op) {
                0 => cpu.aluAdd(val, false),
                1 => cpu.aluAdd(val, true),
                2 => cpu.aluSub(val, false),
                3 => cpu.aluSub(val, true),
                4 => cpu.aluAnd(val),
                5 => cpu.aluXor(val),
                6 => cpu.aluOr(val),
                7 => cpu.aluCp(val),
            }
            return if (r == 6) 8 else 4;
        }
    }.f;
}

fn genLdRImm(comptime r: u3) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            const val = cpu.fetch(mmu);
            cpu.setReg(mmu, r, val);
            return if (r == 6) 12 else 8;
        }
    }.f;
}

fn genAluImm(comptime op: u3) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            const val = cpu.fetch(mmu);
            switch (op) {
                0 => cpu.aluAdd(val, false),
                1 => cpu.aluAdd(val, true),
                2 => cpu.aluSub(val, false),
                3 => cpu.aluSub(val, true),
                4 => cpu.aluAnd(val),
                5 => cpu.aluXor(val),
                6 => cpu.aluOr(val),
                7 => cpu.aluCp(val),
            }
            return 8;
        }
    }.f;
}

fn genLdRpImm(comptime rp: u2) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            const val = cpu.fetchWord(mmu);
            cpu.setRp(rp, val);
            return 12;
        }
    }.f;
}

fn genIncRp(comptime rp: u2) Handler {
    return struct {
        fn f(cpu: *CPU, _: *MMU) u8 {
            cpu.setRp(rp, cpu.getRp(rp) +% 1);
            return 8;
        }
    }.f;
}

fn genDecRp(comptime rp: u2) Handler {
    return struct {
        fn f(cpu: *CPU, _: *MMU) u8 {
            cpu.setRp(rp, cpu.getRp(rp) -% 1);
            return 8;
        }
    }.f;
}

fn genIncR(comptime r: u3) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            const val = cpu.getReg(mmu, r);
            cpu.setReg(mmu, r, cpu.aluInc(val));
            return if (r == 6) 12 else 4;
        }
    }.f;
}

fn genDecR(comptime r: u3) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            const val = cpu.getReg(mmu, r);
            cpu.setReg(mmu, r, cpu.aluDec(val));
            return if (r == 6) 12 else 4;
        }
    }.f;
}

fn genAddHlRp(comptime rp: u2) Handler {
    return struct {
        fn f(cpu: *CPU, _: *MMU) u8 {
            const hl = cpu.getHL();
            const val = cpu.getRp(rp);
            const result = @as(u32, hl) + val;
            const half = (hl & 0xFFF) + (val & 0xFFF);
            cpu.setHL(@truncate(result));
            cpu.f.n = false;
            cpu.f.h = half > 0xFFF;
            cpu.f.c = result > 0xFFFF;
            return 8;
        }
    }.f;
}

fn genPush(comptime rp: u2) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            const val = switch (rp) {
                0 => cpu.getBC(),
                1 => cpu.getDE(),
                2 => cpu.getHL(),
                3 => cpu.getAF(),
            };
            cpu.push(mmu, val);
            return 16;
        }
    }.f;
}

fn genPop(comptime rp: u2) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            const val = cpu.pop(mmu);
            switch (rp) {
                0 => cpu.setBC(val),
                1 => cpu.setDE(val),
                2 => cpu.setHL(val),
                3 => cpu.setAF(val),
            }
            return 12;
        }
    }.f;
}

fn genJpCc(comptime cc: u2) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            const addr = cpu.fetchWord(mmu);
            if (cpu.checkCondition(cc)) {
                cpu.pc = addr;
                return 16;
            }
            return 12;
        }
    }.f;
}

fn genJrCc(comptime cc: u2) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            const offset: i8 = @bitCast(cpu.fetch(mmu));
            if (cpu.checkCondition(cc)) {
                cpu.pc = @bitCast(@as(i16, @bitCast(cpu.pc)) +% offset);
                return 12;
            }
            return 8;
        }
    }.f;
}

fn genCallCc(comptime cc: u2) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            const addr = cpu.fetchWord(mmu);
            if (cpu.checkCondition(cc)) {
                cpu.push(mmu, cpu.pc);
                cpu.pc = addr;
                return 24;
            }
            return 12;
        }
    }.f;
}

fn genRetCc(comptime cc: u2) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            if (cpu.checkCondition(cc)) {
                cpu.pc = cpu.pop(mmu);
                return 20;
            }
            return 8;
        }
    }.f;
}

fn genRst(comptime n: u3) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            cpu.push(mmu, cpu.pc);
            cpu.pc = @as(u16, n) * 8;
            return 16;
        }
    }.f;
}

// --- Individual opcode handlers ---

fn op_nop(_: *CPU, _: *MMU) u8 {
    return 4;
}

fn op_halt(cpu: *CPU, mmu: *MMU) u8 {
    if (!cpu.ime and (mmu.ie & mmu.if_ & 0x1F) != 0) {
        cpu.halt_bug = true;
    } else {
        cpu.halted = true;
    }
    return 4;
}

fn op_stop(cpu: *CPU, mmu: *MMU) u8 {
    _ = cpu.fetch(mmu);
    return 4;
}

fn op_di(cpu: *CPU, _: *MMU) u8 {
    cpu.ime = false;
    cpu.ime_scheduled = false;
    return 4;
}

fn op_ei(cpu: *CPU, _: *MMU) u8 {
    cpu.ime_scheduled = true;
    return 4;
}

fn op_scf(cpu: *CPU, _: *MMU) u8 {
    cpu.f.n = false;
    cpu.f.h = false;
    cpu.f.c = true;
    return 4;
}

fn op_ccf(cpu: *CPU, _: *MMU) u8 {
    cpu.f.n = false;
    cpu.f.h = false;
    cpu.f.c = !cpu.f.c;
    return 4;
}

fn op_cpl(cpu: *CPU, _: *MMU) u8 {
    cpu.a = ~cpu.a;
    cpu.f.n = true;
    cpu.f.h = true;
    return 4;
}

fn op_daa(cpu: *CPU, _: *MMU) u8 {
    var adj: u8 = 0;
    var carry = false;

    if (cpu.f.n) {
        if (cpu.f.h) adj |= 0x06;
        if (cpu.f.c) adj |= 0x60;
        cpu.a -%= adj;
        carry = cpu.f.c;
    } else {
        if (cpu.f.h or (cpu.a & 0x0F) > 9) adj |= 0x06;
        if (cpu.f.c or cpu.a > 0x99) {
            adj |= 0x60;
            carry = true;
        }
        cpu.a +%= adj;
    }

    cpu.f.z = cpu.a == 0;
    cpu.f.h = false;
    cpu.f.c = carry;
    return 4;
}

fn op_jr(cpu: *CPU, mmu: *MMU) u8 {
    const offset: i8 = @bitCast(cpu.fetch(mmu));
    cpu.pc = @bitCast(@as(i16, @bitCast(cpu.pc)) +% offset);
    return 12;
}

fn op_jp(cpu: *CPU, mmu: *MMU) u8 {
    cpu.pc = cpu.fetchWord(mmu);
    return 16;
}

fn op_jp_hl(cpu: *CPU, _: *MMU) u8 {
    cpu.pc = cpu.getHL();
    return 4;
}

fn op_call(cpu: *CPU, mmu: *MMU) u8 {
    const addr = cpu.fetchWord(mmu);
    cpu.push(mmu, cpu.pc);
    cpu.pc = addr;
    return 24;
}

fn op_ret(cpu: *CPU, mmu: *MMU) u8 {
    cpu.pc = cpu.pop(mmu);
    return 16;
}

fn op_reti(cpu: *CPU, mmu: *MMU) u8 {
    cpu.pc = cpu.pop(mmu);
    cpu.ime = true;
    return 16;
}

fn op_ld_bc_a(cpu: *CPU, mmu: *MMU) u8 {
    mmu.write(cpu.getBC(), cpu.a);
    return 8;
}

fn op_ld_de_a(cpu: *CPU, mmu: *MMU) u8 {
    mmu.write(cpu.getDE(), cpu.a);
    return 8;
}

fn op_ld_hli_a(cpu: *CPU, mmu: *MMU) u8 {
    const hl = cpu.getHL();
    mmu.write(hl, cpu.a);
    cpu.setHL(hl +% 1);
    return 8;
}

fn op_ld_hld_a(cpu: *CPU, mmu: *MMU) u8 {
    const hl = cpu.getHL();
    mmu.write(hl, cpu.a);
    cpu.setHL(hl -% 1);
    return 8;
}

fn op_ld_a_bc(cpu: *CPU, mmu: *MMU) u8 {
    cpu.a = mmu.read(cpu.getBC());
    return 8;
}

fn op_ld_a_de(cpu: *CPU, mmu: *MMU) u8 {
    cpu.a = mmu.read(cpu.getDE());
    return 8;
}

fn op_ld_a_hli(cpu: *CPU, mmu: *MMU) u8 {
    const hl = cpu.getHL();
    cpu.a = mmu.read(hl);
    cpu.setHL(hl +% 1);
    return 8;
}

fn op_ld_a_hld(cpu: *CPU, mmu: *MMU) u8 {
    const hl = cpu.getHL();
    cpu.a = mmu.read(hl);
    cpu.setHL(hl -% 1);
    return 8;
}

fn op_ld_nn_sp(cpu: *CPU, mmu: *MMU) u8 {
    const addr = cpu.fetchWord(mmu);
    mmu.write(addr, @truncate(cpu.sp));
    mmu.write(addr +% 1, @truncate(cpu.sp >> 8));
    return 20;
}

fn op_ld_sp_hl(cpu: *CPU, _: *MMU) u8 {
    cpu.sp = cpu.getHL();
    return 8;
}

fn op_ld_hl_sp_n(cpu: *CPU, mmu: *MMU) u8 {
    const offset: i8 = @bitCast(cpu.fetch(mmu));
    const sp_i: i32 = cpu.sp;
    const result: i32 = sp_i + offset;
    cpu.setHL(@truncate(@as(u32, @bitCast(result))));
    cpu.f.z = false;
    cpu.f.n = false;
    // Half-carry and carry are computed on the low byte
    cpu.f.h = ((cpu.sp & 0xF) + (@as(u16, @bitCast(@as(i16, offset))) & 0xF)) > 0xF;
    cpu.f.c = ((cpu.sp & 0xFF) + (@as(u16, @bitCast(@as(i16, offset))) & 0xFF)) > 0xFF;
    return 12;
}

fn op_add_sp_n(cpu: *CPU, mmu: *MMU) u8 {
    const offset: i8 = @bitCast(cpu.fetch(mmu));
    const sp_i: i32 = cpu.sp;
    const result: i32 = sp_i + offset;
    cpu.f.z = false;
    cpu.f.n = false;
    cpu.f.h = ((cpu.sp & 0xF) + (@as(u16, @bitCast(@as(i16, offset))) & 0xF)) > 0xF;
    cpu.f.c = ((cpu.sp & 0xFF) + (@as(u16, @bitCast(@as(i16, offset))) & 0xFF)) > 0xFF;
    cpu.sp = @truncate(@as(u32, @bitCast(result)));
    return 16;
}

fn op_ldh_n_a(cpu: *CPU, mmu: *MMU) u8 {
    const offset = cpu.fetch(mmu);
    mmu.write(0xFF00 + @as(u16, offset), cpu.a);
    return 12;
}

fn op_ldh_a_n(cpu: *CPU, mmu: *MMU) u8 {
    const offset = cpu.fetch(mmu);
    cpu.a = mmu.read(0xFF00 + @as(u16, offset));
    return 12;
}

fn op_ldh_c_a(cpu: *CPU, mmu: *MMU) u8 {
    mmu.write(0xFF00 + @as(u16, cpu.c), cpu.a);
    return 8;
}

fn op_ldh_a_c(cpu: *CPU, mmu: *MMU) u8 {
    cpu.a = mmu.read(0xFF00 + @as(u16, cpu.c));
    return 8;
}

fn op_ld_nn_a(cpu: *CPU, mmu: *MMU) u8 {
    const addr = cpu.fetchWord(mmu);
    mmu.write(addr, cpu.a);
    return 16;
}

fn op_ld_a_nn(cpu: *CPU, mmu: *MMU) u8 {
    const addr = cpu.fetchWord(mmu);
    cpu.a = mmu.read(addr);
    return 16;
}

fn op_rlca(cpu: *CPU, _: *MMU) u8 {
    const carry = cpu.a >> 7;
    cpu.a = (cpu.a << 1) | carry;
    cpu.f = .{ .z = false, .n = false, .h = false, .c = carry != 0 };
    return 4;
}

fn op_rrca(cpu: *CPU, _: *MMU) u8 {
    const carry = cpu.a & 1;
    cpu.a = (cpu.a >> 1) | (carry << 7);
    cpu.f = .{ .z = false, .n = false, .h = false, .c = carry != 0 };
    return 4;
}

fn op_rla(cpu: *CPU, _: *MMU) u8 {
    const carry = cpu.a >> 7;
    cpu.a = (cpu.a << 1) | @as(u8, if (cpu.f.c) 1 else 0);
    cpu.f = .{ .z = false, .n = false, .h = false, .c = carry != 0 };
    return 4;
}

fn op_rra(cpu: *CPU, _: *MMU) u8 {
    const carry = cpu.a & 1;
    cpu.a = (cpu.a >> 1) | (@as(u8, if (cpu.f.c) 1 else 0) << 7);
    cpu.f = .{ .z = false, .n = false, .h = false, .c = carry != 0 };
    return 4;
}

fn op_cb(cpu: *CPU, mmu: *MMU) u8 {
    const op = cpu.fetch(mmu);
    return cb_opcodes[op](cpu, mmu);
}

// =============================================================================
// CB-prefix opcode generators
// =============================================================================

fn genCbRot(comptime op: u3, comptime r: u3) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            const val = cpu.getReg(mmu, r);
            const result = switch (op) {
                0 => cpu.rlc(val),
                1 => cpu.rrc(val),
                2 => cpu.rl(val),
                3 => cpu.rr(val),
                4 => cpu.sla(val),
                5 => cpu.sra(val),
                6 => cpu.swap(val),
                7 => cpu.srl(val),
            };
            cpu.setReg(mmu, r, result);
            return if (r == 6) 16 else 8;
        }
    }.f;
}

fn genCbBit(comptime b: u3, comptime r: u3) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            cpu.bit(b, cpu.getReg(mmu, r));
            return if (r == 6) 12 else 8;
        }
    }.f;
}

fn genCbRes(comptime b: u3, comptime r: u3) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            const val = cpu.getReg(mmu, r) & ~(@as(u8, 1) << b);
            cpu.setReg(mmu, r, val);
            return if (r == 6) 16 else 8;
        }
    }.f;
}

fn genCbSet(comptime b: u3, comptime r: u3) Handler {
    return struct {
        fn f(cpu: *CPU, mmu: *MMU) u8 {
            const val = cpu.getReg(mmu, r) | (@as(u8, 1) << b);
            cpu.setReg(mmu, r, val);
            return if (r == 6) 16 else 8;
        }
    }.f;
}

// =============================================================================
// Opcode Tables
// =============================================================================

const opcodes: [256]Handler = blk: {
    var table: [256]Handler = @splat(&unimplemented);

    // 0x00: NOP
    table[0x00] = &op_nop;

    // 0x10: STOP
    table[0x10] = &op_stop;

    // 0x76: HALT
    table[0x76] = &op_halt;

    // DI/EI
    table[0xF3] = &op_di;
    table[0xFB] = &op_ei;

    // SCF/CCF/CPL/DAA
    table[0x37] = &op_scf;
    table[0x3F] = &op_ccf;
    table[0x2F] = &op_cpl;
    table[0x27] = &op_daa;

    // Rotate A ops
    table[0x07] = &op_rlca;
    table[0x0F] = &op_rrca;
    table[0x17] = &op_rla;
    table[0x1F] = &op_rra;

    // JR
    table[0x18] = &op_jr;
    table[0x20] = genJrCc(0); // JR NZ
    table[0x28] = genJrCc(1); // JR Z
    table[0x30] = genJrCc(2); // JR NC
    table[0x38] = genJrCc(3); // JR C

    // JP
    table[0xC3] = &op_jp;
    table[0xE9] = &op_jp_hl;
    table[0xC2] = genJpCc(0); // JP NZ
    table[0xCA] = genJpCc(1); // JP Z
    table[0xD2] = genJpCc(2); // JP NC
    table[0xDA] = genJpCc(3); // JP C

    // CALL
    table[0xCD] = &op_call;
    table[0xC4] = genCallCc(0);
    table[0xCC] = genCallCc(1);
    table[0xD4] = genCallCc(2);
    table[0xDC] = genCallCc(3);

    // RET
    table[0xC9] = &op_ret;
    table[0xD9] = &op_reti;
    table[0xC0] = genRetCc(0);
    table[0xC8] = genRetCc(1);
    table[0xD0] = genRetCc(2);
    table[0xD8] = genRetCc(3);

    // RST
    table[0xC7] = genRst(0);
    table[0xCF] = genRst(1);
    table[0xD7] = genRst(2);
    table[0xDF] = genRst(3);
    table[0xE7] = genRst(4);
    table[0xEF] = genRst(5);
    table[0xF7] = genRst(6);
    table[0xFF] = genRst(7);

    // LD rr,nn (16-bit immediate)
    table[0x01] = genLdRpImm(0);
    table[0x11] = genLdRpImm(1);
    table[0x21] = genLdRpImm(2);
    table[0x31] = genLdRpImm(3);

    // INC/DEC rr
    table[0x03] = genIncRp(0);
    table[0x13] = genIncRp(1);
    table[0x23] = genIncRp(2);
    table[0x33] = genIncRp(3);
    table[0x0B] = genDecRp(0);
    table[0x1B] = genDecRp(1);
    table[0x2B] = genDecRp(2);
    table[0x3B] = genDecRp(3);

    // ADD HL,rr
    table[0x09] = genAddHlRp(0);
    table[0x19] = genAddHlRp(1);
    table[0x29] = genAddHlRp(2);
    table[0x39] = genAddHlRp(3);

    // PUSH/POP
    table[0xC5] = genPush(0);
    table[0xD5] = genPush(1);
    table[0xE5] = genPush(2);
    table[0xF5] = genPush(3);
    table[0xC1] = genPop(0);
    table[0xD1] = genPop(1);
    table[0xE1] = genPop(2);
    table[0xF1] = genPop(3);

    // LD A,(rr) / LD (rr),A
    table[0x02] = &op_ld_bc_a;
    table[0x12] = &op_ld_de_a;
    table[0x22] = &op_ld_hli_a;
    table[0x32] = &op_ld_hld_a;
    table[0x0A] = &op_ld_a_bc;
    table[0x1A] = &op_ld_a_de;
    table[0x2A] = &op_ld_a_hli;
    table[0x3A] = &op_ld_a_hld;

    // LD (nn),SP
    table[0x08] = &op_ld_nn_sp;

    // LD SP,HL / LD HL,SP+n / ADD SP,n
    table[0xF9] = &op_ld_sp_hl;
    table[0xF8] = &op_ld_hl_sp_n;
    table[0xE8] = &op_add_sp_n;

    // LDH
    table[0xE0] = &op_ldh_n_a;
    table[0xF0] = &op_ldh_a_n;
    table[0xE2] = &op_ldh_c_a;
    table[0xF2] = &op_ldh_a_c;

    // LD (nn),A / LD A,(nn)
    table[0xEA] = &op_ld_nn_a;
    table[0xFA] = &op_ld_a_nn;

    // CB prefix
    table[0xCB] = &op_cb;

    // LD r,r' (0x40-0x7F except 0x76)
    for (0..8) |d| {
        for (0..8) |s| {
            const idx = 0x40 + d * 8 + s;
            if (idx != 0x76) {
                table[idx] = genLdRR(@intCast(d), @intCast(s));
            }
        }
    }

    // ALU A,r (0x80-0xBF)
    for (0..8) |op| {
        for (0..8) |r| {
            table[0x80 + op * 8 + r] = genAluR(@intCast(op), @intCast(r));
        }
    }

    // LD r,imm (0x06,0x0E,0x16,0x1E,0x26,0x2E,0x36,0x3E)
    for (0..8) |r| {
        table[0x06 + r * 8] = genLdRImm(@intCast(r));
    }

    // INC/DEC r
    for (0..8) |r| {
        table[0x04 + r * 8] = genIncR(@intCast(r));
        table[0x05 + r * 8] = genDecR(@intCast(r));
    }

    // ALU A,imm (0xC6,0xCE,0xD6,0xDE,0xE6,0xEE,0xF6,0xFE)
    for (0..8) |op| {
        table[0xC6 + op * 8] = genAluImm(@intCast(op));
    }

    break :blk table;
};

const cb_opcodes: [256]Handler = blk: {
    var table: [256]Handler = @splat(&unimplemented);

    // Rotate/shift: 0x00-0x3F
    for (0..8) |op| {
        for (0..8) |r| {
            table[op * 8 + r] = genCbRot(@intCast(op), @intCast(r));
        }
    }

    // BIT: 0x40-0x7F
    for (0..8) |b| {
        for (0..8) |r| {
            table[0x40 + b * 8 + r] = genCbBit(@intCast(b), @intCast(r));
        }
    }

    // RES: 0x80-0xBF
    for (0..8) |b| {
        for (0..8) |r| {
            table[0x80 + b * 8 + r] = genCbRes(@intCast(b), @intCast(r));
        }
    }

    // SET: 0xC0-0xFF
    for (0..8) |b| {
        for (0..8) |r| {
            table[0xC0 + b * 8 + r] = genCbSet(@intCast(b), @intCast(r));
        }
    }

    break :blk table;
};

// =============================================================================
// Tests
// =============================================================================

test "flags bit layout" {
    var f = Flags{ .z = true, .c = true };
    try std.testing.expectEqual(@as(u8, 0x90), f.toU8());
    f = Flags.fromU8(0xFF);
    try std.testing.expectEqual(@as(u8, 0xF0), f.toU8());
}

test "register pairs" {
    var cpu = CPU{};
    cpu.setBC(0x1234);
    try std.testing.expectEqual(@as(u8, 0x12), cpu.b);
    try std.testing.expectEqual(@as(u8, 0x34), cpu.c);
    try std.testing.expectEqual(@as(u16, 0x1234), cpu.getBC());
}
