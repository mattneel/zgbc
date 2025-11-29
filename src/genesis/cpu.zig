//! Motorola 68000 CPU
//! Main processor for Sega Genesis @ 7.67 MHz.

const std = @import("std");

pub const M68K = struct {
    // Data registers (32-bit)
    d: [8]u32 = [_]u32{0} ** 8,

    // Address registers (32-bit, A7 is stack pointer)
    a: [8]u32 = [_]u32{0} ** 8,

    // Program counter
    pc: u32 = 0,

    // Status register
    sr: SR = .{},

    // Stack pointers
    usp: u32 = 0, // User stack pointer
    ssp: u32 = 0, // Supervisor stack pointer

    // State
    stopped: bool = false,
    cycles: u32 = 0,
    irq_level: u3 = 0,

    // Debug
    debug_traced_200: bool = false,
    debug_traced_bad_pc: bool = false,

    pub const SR = packed struct(u16) {
        c: bool = false, // Carry
        v: bool = false, // Overflow
        z: bool = false, // Zero
        n: bool = false, // Negative
        x: bool = false, // Extend
        _pad: u3 = 0,
        i: u3 = 7, // Interrupt mask (0-7)
        _pad2: u2 = 0,
        s: bool = true, // Supervisor mode
        _pad3: u1 = 0,
        t: bool = false, // Trace
    };

    const Size = enum(u2) {
        byte = 0,
        word = 1,
        long = 2,

        fn bytes(self: Size) u32 {
            return switch (self) {
                .byte => 1,
                .word => 2,
                .long => 4,
            };
        }

        fn mask(self: Size) u32 {
            return switch (self) {
                .byte => 0xFF,
                .word => 0xFFFF,
                .long => 0xFFFFFFFF,
            };
        }

        fn signBit(self: Size) u32 {
            return switch (self) {
                .byte => 0x80,
                .word => 0x8000,
                .long => 0x80000000,
            };
        }
    };

    pub fn reset(self: *M68K, bus: anytype) void {
        self.ssp = bus.read32(0);
        self.pc = bus.read32(4);
        self.sr = .{ .s = true, .i = 7 };
        self.a[7] = self.ssp;
        self.stopped = false;
    }

    fn fetchWord(self: *M68K, bus: anytype) u16 {
        const val = bus.read16(self.pc);
        self.pc +%= 2;
        return val;
    }

    fn fetchLong(self: *M68K, bus: anytype) u32 {
        const hi = self.fetchWord(bus);
        const lo = self.fetchWord(bus);
        return (@as(u32, hi) << 16) | lo;
    }

    fn push32(self: *M68K, bus: anytype, val: u32) void {
        self.a[7] -%= 4;
        bus.write32(self.a[7], val);
    }

    fn push16(self: *M68K, bus: anytype, val: u16) void {
        self.a[7] -%= 2;
        bus.write16(self.a[7], val);
    }

    fn pop32(self: *M68K, bus: anytype) u32 {
        const val = bus.read32(self.a[7]);
        self.a[7] +%= 4;
        return val;
    }

    fn pop16(self: *M68K, bus: anytype) u16 {
        const val = bus.read16(self.a[7]);
        self.a[7] +%= 2;
        return val;
    }

    pub fn step(self: *M68K, bus: anytype) u32 {
        // Check for interrupts
        if (self.irq_level > self.sr.i) {
            self.handleInterrupt(bus, self.irq_level);
            return 44;
        }

        if (self.stopped) return 4;

        const opcode = self.fetchWord(bus);
        return self.execute(opcode, bus);
    }

    fn handleInterrupt(self: *M68K, bus: anytype, level: u3) void {
        // Save state
        if (!self.sr.s) {
            self.usp = self.a[7];
            self.a[7] = self.ssp;
        }
        self.push32(bus, self.pc);
        self.push16(bus, @bitCast(self.sr));

        // Enter supervisor mode, disable lower interrupts
        self.sr.s = true;
        self.sr.t = false;
        self.sr.i = level;

        // Vector address: level 1-7 use autovectors 25-31 (addresses $64-$7C)
        const vector_addr = (24 + @as(u32, level)) * 4;
        self.pc = bus.read32(vector_addr);
        self.stopped = false;
    }

    fn execute(self: *M68K, opcode: u16, bus: anytype) u32 {
        return switch (@as(u4, @truncate(opcode >> 12))) {
            0x0 => self.opImmediate(opcode, bus),
            0x1 => self.opMove(opcode, bus, .byte),
            0x2 => self.opMove(opcode, bus, .long),
            0x3 => self.opMove(opcode, bus, .word),
            0x4 => self.opMisc(opcode, bus),
            0x5 => self.opAddqSubq(opcode, bus),
            0x6 => self.opBranch(opcode, bus),
            0x7 => self.opMoveq(opcode, bus),
            0x8 => self.opOrDivSbcd(opcode, bus),
            0x9 => self.opSub(opcode, bus),
            0xA => 4, // Line A trap
            0xB => self.opCmpEor(opcode, bus),
            0xC => self.opAndMulAbcdExg(opcode, bus),
            0xD => self.opAdd(opcode, bus),
            0xE => self.opShift(opcode, bus),
            0xF => 4, // Line F trap
        };
    }

    // =========================================================================
    // Effective Address calculation
    // =========================================================================

    fn getEA(self: *M68K, bus: anytype, mode: u3, reg: u3, size: Size) u32 {
        return switch (mode) {
            0 => 0, // Dn - handled specially
            1 => 0, // An - handled specially
            2 => self.a[reg], // (An)
            3 => blk: { // (An)+
                const addr = self.a[reg];
                self.a[reg] +%= if (reg == 7 and size == .byte) 2 else size.bytes();
                break :blk addr;
            },
            4 => blk: { // -(An)
                self.a[reg] -%= if (reg == 7 and size == .byte) 2 else size.bytes();
                break :blk self.a[reg];
            },
            5 => blk: { // d16(An)
                const disp: i16 = @bitCast(self.fetchWord(bus));
                break :blk @bitCast(@as(i32, @bitCast(self.a[reg])) +% disp);
            },
            6 => self.getIndexedEA(bus, self.a[reg]), // d8(An,Xn)
            7 => switch (reg) {
                0 => blk: { // xxx.W
                    const addr: i16 = @bitCast(self.fetchWord(bus));
                    break :blk @bitCast(@as(i32, addr));
                },
                1 => self.fetchLong(bus), // xxx.L
                2 => blk: { // d16(PC)
                    const base = self.pc;
                    const disp: i16 = @bitCast(self.fetchWord(bus));
                    break :blk @bitCast(@as(i32, @bitCast(base)) +% disp);
                },
                3 => self.getIndexedEA(bus, self.pc), // d8(PC,Xn)
                4 => self.pc, // #imm - return PC, caller fetches
                else => 0,
            },
        };
    }

    fn getIndexedEA(self: *M68K, bus: anytype, base: u32) u32 {
        const ext = self.fetchWord(bus);
        const disp: i8 = @bitCast(@as(u8, @truncate(ext)));
        const idx_reg: u3 = @truncate((ext >> 12) & 7);
        const idx_is_a = ext & 0x8000 != 0;
        const idx_long = ext & 0x0800 != 0;

        var idx: i32 = if (idx_is_a)
            @bitCast(self.a[idx_reg])
        else
            @bitCast(self.d[idx_reg]);

        if (!idx_long) {
            const idx_u16: u16 = @truncate(@as(u32, @bitCast(idx)));
            idx = @as(i16, @bitCast(idx_u16));
        }

        return @bitCast(@as(i32, @bitCast(base)) +% disp +% idx);
    }

    fn readEA(self: *M68K, bus: anytype, mode: u3, reg: u3, size: Size) u32 {
        if (mode == 0) return self.d[reg] & size.mask();
        if (mode == 1) return self.a[reg] & size.mask();
        if (mode == 7 and reg == 4) {
            // Immediate
            return if (size == .long) self.fetchLong(bus) else self.fetchWord(bus) & size.mask();
        }

        const addr = self.getEA(bus, mode, reg, size);
        return switch (size) {
            .byte => bus.read8(addr),
            .word => bus.read16(addr),
            .long => bus.read32(addr),
        };
    }

    fn writeEA(self: *M68K, bus: anytype, mode: u3, reg: u3, size: Size, val: u32) void {
        if (mode == 0) {
            self.d[reg] = (self.d[reg] & ~size.mask()) | (val & size.mask());
            return;
        }
        if (mode == 1) {
            if (size == .byte) return; // Can't write byte to An
            self.a[reg] = if (size == .word) @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(val)))))) else val;
            return;
        }

        const addr = self.getEA(bus, mode, reg, size);
        switch (size) {
            .byte => bus.write8(addr, @truncate(val)),
            .word => bus.write16(addr, @truncate(val)),
            .long => bus.write32(addr, val),
        }
    }

    // Helper for reading from a computed address (avoids double-fetching extension words)
    fn readMem(self: *M68K, bus: anytype, addr: u32, size: Size) u32 {
        _ = self;
        return switch (size) {
            .byte => bus.read8(addr),
            .word => bus.read16(addr),
            .long => bus.read32(addr),
        };
    }

    // Helper for writing to a computed address (avoids double-fetching extension words)
    fn writeMem(self: *M68K, bus: anytype, addr: u32, size: Size, val: u32) void {
        _ = self;
        switch (size) {
            .byte => bus.write8(addr, @truncate(val)),
            .word => bus.write16(addr, @truncate(val)),
            .long => bus.write32(addr, val),
        }
    }

    // =========================================================================
    // Instruction implementations
    // =========================================================================

    fn opImmediate(self: *M68K, opcode: u16, bus: anytype) u32 {
        const size_bits = (opcode >> 6) & 3;
        const mode: u3 = @truncate((opcode >> 3) & 7);
        const reg: u3 = @truncate(opcode & 7);
        const op: u3 = @truncate((opcode >> 9) & 7);

        // Handle special cases where size=3 is invalid for standard immediate ops
        if (size_bits == 3) {
            // Size 3 is invalid for ORI/ANDI/SUBI/ADDI/EORI/CMPI
            // Could be CAS2 or invalid instruction
            return 4;
        }

        const size: Size = @enumFromInt(size_bits);

        return switch (op) {
            0 => self.opORI(bus, mode, reg, size),
            1 => self.opANDI(bus, mode, reg, size),
            2 => self.opSUBI(bus, mode, reg, size),
            3 => self.opADDI(bus, mode, reg, size),
            4 => self.opBitImm(opcode, bus), // BTST/BCHG/BCLR/BSET
            5 => self.opEORI(bus, mode, reg, size),
            6 => self.opCMPI(bus, mode, reg, size),
            7 => 4, // MOVES (privileged)
        };
    }

    fn opORI(self: *M68K, bus: anytype, mode: u3, reg: u3, size: Size) u32 {
        const imm = if (size == .long) self.fetchLong(bus) else self.fetchWord(bus) & size.mask();
        if (mode == 0) {
            const result = self.d[reg] | imm;
            self.d[reg] = (self.d[reg] & ~size.mask()) | (result & size.mask());
            self.setFlags_NZ(result, size);
            self.sr.v = false;
            self.sr.c = false;
            return if (size == .long) 16 else 8;
        }
        const addr = self.getEA(bus, mode, reg, size);
        const val = self.readMem(bus, addr, size);
        const result = val | imm;
        self.writeMem(bus, addr, size, result);
        self.setFlags_NZ(result, size);
        self.sr.v = false;
        self.sr.c = false;
        return if (size == .long) 16 else 8;
    }

    fn opANDI(self: *M68K, bus: anytype, mode: u3, reg: u3, size: Size) u32 {
        const imm = if (size == .long) self.fetchLong(bus) else self.fetchWord(bus) & size.mask();
        if (mode == 0) {
            const result = self.d[reg] & imm;
            self.d[reg] = (self.d[reg] & ~size.mask()) | (result & size.mask());
            self.setFlags_NZ(result, size);
            self.sr.v = false;
            self.sr.c = false;
            return if (size == .long) 16 else 8;
        }
        const addr = self.getEA(bus, mode, reg, size);
        const val = self.readMem(bus, addr, size);
        const result = val & imm;
        self.writeMem(bus, addr, size, result);
        self.setFlags_NZ(result, size);
        self.sr.v = false;
        self.sr.c = false;
        return if (size == .long) 16 else 8;
    }

    fn opSUBI(self: *M68K, bus: anytype, mode: u3, reg: u3, size: Size) u32 {
        const imm = if (size == .long) self.fetchLong(bus) else self.fetchWord(bus) & size.mask();
        if (mode == 0) {
            const result = self.sub(self.d[reg], imm, size);
            self.d[reg] = (self.d[reg] & ~size.mask()) | (result & size.mask());
            return if (size == .long) 16 else 8;
        }
        const addr = self.getEA(bus, mode, reg, size);
        const val = self.readMem(bus, addr, size);
        const result = self.sub(val, imm, size);
        self.writeMem(bus, addr, size, result);
        return if (size == .long) 16 else 8;
    }

    fn opADDI(self: *M68K, bus: anytype, mode: u3, reg: u3, size: Size) u32 {
        const imm = if (size == .long) self.fetchLong(bus) else self.fetchWord(bus) & size.mask();
        if (mode == 0) {
            const result = self.add(self.d[reg], imm, size);
            self.d[reg] = (self.d[reg] & ~size.mask()) | (result & size.mask());
            return if (size == .long) 16 else 8;
        }
        const addr = self.getEA(bus, mode, reg, size);
        const val = self.readMem(bus, addr, size);
        const result = self.add(val, imm, size);
        self.writeMem(bus, addr, size, result);
        return if (size == .long) 16 else 8;
    }

    fn opEORI(self: *M68K, bus: anytype, mode: u3, reg: u3, size: Size) u32 {
        const imm = if (size == .long) self.fetchLong(bus) else self.fetchWord(bus) & size.mask();
        if (mode == 0) {
            const result = self.d[reg] ^ imm;
            self.d[reg] = (self.d[reg] & ~size.mask()) | (result & size.mask());
            self.setFlags_NZ(result, size);
            self.sr.v = false;
            self.sr.c = false;
            return if (size == .long) 16 else 8;
        }
        const addr = self.getEA(bus, mode, reg, size);
        const val = self.readMem(bus, addr, size);
        const result = val ^ imm;
        self.writeMem(bus, addr, size, result);
        self.setFlags_NZ(result, size);
        self.sr.v = false;
        self.sr.c = false;
        return if (size == .long) 16 else 8;
    }

    fn opCMPI(self: *M68K, bus: anytype, mode: u3, reg: u3, size: Size) u32 {
        const imm = if (size == .long) self.fetchLong(bus) else self.fetchWord(bus) & size.mask();
        const val = self.readEA(bus, mode, reg, size);
        _ = self.sub(val, imm, size);
        return if (size == .long) 14 else 8;
    }

    fn opBitImm(self: *M68K, opcode: u16, bus: anytype) u32 {
        const bit_num: u5 = @truncate(self.fetchWord(bus));
        const mode: u3 = @truncate((opcode >> 3) & 7);
        const reg: u3 = @truncate(opcode & 7);
        const op: u2 = @truncate((opcode >> 6) & 3);

        if (mode == 0) {
            // Register - 32-bit
            const mask: u32 = @as(u32, 1) << @truncate(bit_num);
            self.sr.z = (self.d[reg] & mask) == 0;
            switch (op) {
                0 => {}, // BTST
                1 => self.d[reg] ^= mask, // BCHG
                2 => self.d[reg] &= ~mask, // BCLR
                3 => self.d[reg] |= mask, // BSET
            }
            return if (op == 0) 10 else 12;
        } else {
            // Memory - 8-bit
            const addr = self.getEA(bus, mode, reg, .byte);
            const val = bus.read8(addr);
            const mask: u8 = @as(u8, 1) << @truncate(bit_num & 7);
            self.sr.z = (val & mask) == 0;
            switch (op) {
                0 => {}, // BTST
                1 => bus.write8(addr, val ^ mask), // BCHG
                2 => bus.write8(addr, val & ~mask), // BCLR
                3 => bus.write8(addr, val | mask), // BSET
            }
            return if (op == 0) 8 else 12;
        }
    }

    fn opMove(self: *M68K, opcode: u16, bus: anytype, size: Size) u32 {
        const src_mode: u3 = @truncate((opcode >> 3) & 7);
        const src_reg: u3 = @truncate(opcode & 7);
        const dst_reg: u3 = @truncate((opcode >> 9) & 7);
        const dst_mode: u3 = @truncate((opcode >> 6) & 7);

        const val = self.readEA(bus, src_mode, src_reg, size);

        if (dst_mode == 1) {
            // MOVEA - no flags
            self.a[dst_reg] = if (size == .word)
                @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(val))))))
            else
                val;
        } else {
            self.writeEA(bus, dst_mode, dst_reg, size, val);
            self.setFlags_NZ(val, size);
            self.sr.v = false;
            self.sr.c = false;
        }

        return 4;
    }

    fn opMisc(self: *M68K, opcode: u16, bus: anytype) u32 {
        const mode: u3 = @truncate((opcode >> 3) & 7);
        const reg: u3 = @truncate(opcode & 7);

        return switch (@as(u6, @truncate((opcode >> 6) & 0x3F))) {
            0b000011 => self.opMoveFromSR(bus, mode, reg),
            0b010011 => self.opMoveToCC(bus),
            0b011011 => self.opMoveToSR(bus, mode, reg),
            0b000000 => self.opNEGX(bus, mode, reg, .byte),
            0b000001 => self.opNEGX(bus, mode, reg, .word),
            0b000010 => self.opNEGX(bus, mode, reg, .long),
            0b001000 => self.opCLR(bus, mode, reg, .byte),
            0b001001 => self.opCLR(bus, mode, reg, .word),
            0b001010 => self.opCLR(bus, mode, reg, .long),
            0b010000 => self.opNEG(bus, mode, reg, .byte),
            0b010001 => self.opNEG(bus, mode, reg, .word),
            0b010010 => self.opNEG(bus, mode, reg, .long),
            0b011000 => self.opNOT(bus, mode, reg, .byte),
            0b011001 => self.opNOT(bus, mode, reg, .word),
            0b011010 => self.opNOT(bus, mode, reg, .long),
            0b100000 => self.opNBCD(bus, mode, reg),
            0b100001 => if (mode == 0) self.opSWAP(reg) else self.opPEA(bus, mode, reg),
            0b100010 => if (mode == 0) self.opEXT(opcode) else self.opMOVEM(opcode, bus),
            0b100011 => if (mode == 0) self.opEXT(opcode) else self.opMOVEM(opcode, bus),
            0b101000 => self.opTST(bus, mode, reg, .byte),
            0b101001 => self.opTST(bus, mode, reg, .word),
            0b101010 => self.opTST(bus, mode, reg, .long),
            0b101011 => self.opTAS(bus, mode, reg),
            0b101100, 0b101101 => 4, // MULU/MULS (long form - 68020+)
            0b110010 => self.opMOVEM(opcode, bus), // MOVEM mem to reg (word)
            0b110011 => self.opMOVEM(opcode, bus), // MOVEM mem to reg (long)
            0b111001 => self.opControl(opcode, bus),
            0b111010 => self.opJSR(bus, mode, reg),
            0b111011 => self.opJMP(bus, mode, reg),
            else => blk: {
                // LEA
                if ((opcode >> 6) & 7 == 7) {
                    break :blk self.opLEA(bus, mode, reg, @truncate((opcode >> 9) & 7));
                }
                // CHK
                if ((opcode >> 6) & 7 == 6) {
                    break :blk 10; // CHK stub
                }
                break :blk 4;
            },
        };
    }

    fn opMoveFromSR(self: *M68K, bus: anytype, mode: u3, reg: u3) u32 {
        const sr_val = @as(u16, @bitCast(self.sr));
        self.writeEA(bus, mode, reg, .word, sr_val);
        return 6;
    }

    fn opMoveToCC(self: *M68K, bus: anytype) u32 {
        const val: u8 = @truncate(self.fetchWord(bus));
        const old_sr: u16 = @bitCast(self.sr);
        self.sr = @bitCast((old_sr & 0xFF00) | val);
        return 12;
    }

    fn opMoveToSR(self: *M68K, bus: anytype, mode: u3, reg: u3) u32 {
        if (!self.sr.s) return 4; // Privilege exception
        const old_s = self.sr.s;
        const val: u16 = @truncate(self.readEA(bus, mode, reg, .word));
        const new_sr: SR = @bitCast(val);

        // Handle stack pointer switch if S bit changes
        if (old_s and !new_sr.s) {
            // Switching from supervisor to user mode
            self.ssp = self.a[7];
            self.a[7] = self.usp;
        }
        // Note: switching from user to supervisor isn't possible here since
        // MOVE to SR is a privileged instruction (old_s is always true)

        self.sr = new_sr;
        return 12;
    }

    fn opNEGX(self: *M68K, bus: anytype, mode: u3, reg: u3, size: Size) u32 {
        const x: u32 = if (self.sr.x) 1 else 0;
        if (mode == 0) {
            const val = self.d[reg] & size.mask();
            const result = 0 -% val -% x;
            self.d[reg] = (self.d[reg] & ~size.mask()) | (result & size.mask());
            const masked = result & size.mask();
            if (masked != 0) self.sr.z = false;
            self.sr.n = (masked & size.signBit()) != 0;
            self.sr.c = val != 0 or x != 0;
            self.sr.x = self.sr.c;
            self.sr.v = (masked & size.signBit()) != 0 and (val & size.signBit()) != 0;
            return if (size == .long) 6 else 4;
        }
        const addr = self.getEA(bus, mode, reg, size);
        const val = self.readMem(bus, addr, size);
        const result = 0 -% val -% x;
        self.writeMem(bus, addr, size, result);
        const masked = result & size.mask();
        if (masked != 0) self.sr.z = false;
        self.sr.n = (masked & size.signBit()) != 0;
        self.sr.c = val != 0 or x != 0;
        self.sr.x = self.sr.c;
        self.sr.v = (masked & size.signBit()) != 0 and (val & size.signBit()) != 0;
        return if (size == .long) 6 else 4;
    }

    fn opCLR(self: *M68K, bus: anytype, mode: u3, reg: u3, size: Size) u32 {
        self.writeEA(bus, mode, reg, size, 0);
        self.sr.n = false;
        self.sr.z = true;
        self.sr.v = false;
        self.sr.c = false;
        return if (size == .long) 6 else 4;
    }

    fn opNEG(self: *M68K, bus: anytype, mode: u3, reg: u3, size: Size) u32 {
        if (mode == 0) {
            const val = self.d[reg] & size.mask();
            const result = self.sub(0, val, size);
            self.d[reg] = (self.d[reg] & ~size.mask()) | (result & size.mask());
            self.sr.x = self.sr.c;
            return if (size == .long) 6 else 4;
        }
        const addr = self.getEA(bus, mode, reg, size);
        const val = self.readMem(bus, addr, size);
        const result = self.sub(0, val, size);
        self.writeMem(bus, addr, size, result);
        self.sr.x = self.sr.c;
        return if (size == .long) 6 else 4;
    }

    fn opNOT(self: *M68K, bus: anytype, mode: u3, reg: u3, size: Size) u32 {
        if (mode == 0) {
            const result = ~self.d[reg] & size.mask();
            self.d[reg] = (self.d[reg] & ~size.mask()) | result;
            self.setFlags_NZ(result, size);
            self.sr.v = false;
            self.sr.c = false;
            return if (size == .long) 6 else 4;
        }
        const addr = self.getEA(bus, mode, reg, size);
        const val = self.readMem(bus, addr, size);
        const result = ~val & size.mask();
        self.writeMem(bus, addr, size, result);
        self.setFlags_NZ(result, size);
        self.sr.v = false;
        self.sr.c = false;
        return if (size == .long) 6 else 4;
    }

    fn opNBCD(self: *M68K, bus: anytype, mode: u3, reg: u3) u32 {
        const val = self.readEA(bus, mode, reg, .byte);
        const x: u8 = if (self.sr.x) 1 else 0;
        var result: u8 = 0 -% @as(u8, @truncate(val)) -% x;

        // BCD adjust
        if ((result & 0x0F) > 9) result -%= 6;
        if ((result & 0xF0) > 0x90) {
            result -%= 0x60;
            self.sr.c = true;
            self.sr.x = true;
        } else {
            self.sr.c = false;
            self.sr.x = false;
        }

        if (result != 0) self.sr.z = false;
        self.writeEA(bus, mode, reg, .byte, result);
        return 6;
    }

    fn opSWAP(self: *M68K, reg: u3) u32 {
        self.d[reg] = (self.d[reg] >> 16) | (self.d[reg] << 16);
        self.setFlags_NZ(self.d[reg], .long);
        self.sr.v = false;
        self.sr.c = false;
        return 4;
    }

    fn opPEA(self: *M68K, bus: anytype, mode: u3, reg: u3) u32 {
        const addr = self.getEA(bus, mode, reg, .long);
        self.push32(bus, addr);
        return 12;
    }

    fn opMOVEM(self: *M68K, opcode: u16, bus: anytype) u32 {
        const dr = (opcode >> 10) & 1 != 0; // 0=reg to mem, 1=mem to reg
        const size: Size = if ((opcode >> 6) & 1 != 0) .long else .word;
        const mode: u3 = @truncate((opcode >> 3) & 7);
        const reg: u3 = @truncate(opcode & 7);


        // For modes 2/3/4, save PC before mask word (no extension words)
        const pc_before_mask = self.pc;

        const mask = self.fetchWord(bus);

        // For modes 5/6/7, save PC after mask word (before extension words)
        const pc_after_mask = self.pc;

        // For post-inc (3) and pre-dec (4), use An directly - MOVEM handles updates
        var addr = if (mode == 3 or mode == 4) self.a[reg] else self.getEA(bus, mode, reg, size);

        // For predecrement mode, the actual first access address is An - 2 (word boundary)
        const access_addr = if (mode == 4) addr -% 2 else addr;

        // Check for odd address (Address Error - data access)
        if (access_addr & 1 != 0) {
            // PC depends on addressing mode
            var saved_pc: u32 = undefined;
            if (mode < 5) {
                saved_pc = pc_before_mask;
            } else if (mode == 7 and reg == 1) {
                // xxx.L: PC includes first word of long address
                saved_pc = pc_after_mask + 2;
            } else {
                saved_pc = pc_after_mask;
            }
            // Status word: for dr=1 modes 5/6, need to set bit 4
            var status_word: u16 = undefined;
            if (dr) {
                // mem to reg: set bit 4 for modes 5/6/7
                status_word = ((opcode | 0x0010) & 0xFFF0) | 0x0005;
            } else {
                // reg to mem
                status_word = (opcode & 0xFFE0) | 0x0005;
            }
            return self.addressErrorWithPC(bus, access_addr, opcode, saved_pc, status_word);
        }

        var count: u32 = 0;

        if (dr) {
            // Memory to registers
            for (0..16) |i| {
                if (mask & (@as(u16, 1) << @truncate(i)) != 0) {
                    const val = if (size == .long) bus.read32(addr) else @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(bus.read16(addr))))));
                    if (i < 8) {
                        self.d[i] = val;
                    } else {
                        self.a[i - 8] = val;
                    }
                    addr +%= size.bytes();
                    count += 1;
                }
            }
            if (mode == 3) {
                self.a[reg] = addr; // Post-increment
            }
        } else {
            // Registers to memory
            if (mode == 4) {
                // Pre-decrement: mask is reversed (bit 0=A7, bit 15=D0)
                // Iterate 0->15 which stores A7 first, D0 last
                for (0..16) |i| {
                    if (mask & (@as(u16, 1) << @truncate(i)) != 0) {
                        addr -%= size.bytes();
                        const val = if (i < 8) self.a[7 - i] else self.d[15 - i];
                        if (size == .long) {
                            bus.write32(addr, val);
                        } else {
                            bus.write16(addr, @truncate(val));
                        }
                        count += 1;
                    }
                }
                self.a[reg] = addr;
            } else {
                for (0..16) |i| {
                    if (mask & (@as(u16, 1) << @truncate(i)) != 0) {
                        const val = if (i < 8) self.d[i] else self.a[i - 8];
                        if (size == .long) {
                            bus.write32(addr, val);
                        } else {
                            bus.write16(addr, @truncate(val));
                        }
                        addr +%= size.bytes();
                        count += 1;
                    }
                }
            }
        }

        const size_mult: u32 = if (size == .long) 8 else 4;
        return 8 + count * size_mult;
    }

    fn opTST(self: *M68K, bus: anytype, mode: u3, reg: u3, size: Size) u32 {
        const val = self.readEA(bus, mode, reg, size);
        self.setFlags_NZ(val, size);
        self.sr.v = false;
        self.sr.c = false;
        return 4;
    }

    fn opTAS(self: *M68K, bus: anytype, mode: u3, reg: u3) u32 {
        const val = self.readEA(bus, mode, reg, .byte);
        self.setFlags_NZ(val, .byte);
        self.sr.v = false;
        self.sr.c = false;
        self.writeEA(bus, mode, reg, .byte, val | 0x80);
        return 4;
    }

    fn opEXT(self: *M68K, opcode: u16) u32 {
        const reg: u3 = @truncate(opcode & 7);
        const op_mode = (opcode >> 6) & 7;

        if (op_mode == 2) {
            // EXT.W
            self.d[reg] = (self.d[reg] & 0xFFFF0000) | @as(u32, @as(u16, @bitCast(@as(i16, @as(i8, @bitCast(@as(u8, @truncate(self.d[reg]))))))));
            self.setFlags_NZ(self.d[reg] & 0xFFFF, .word);
        } else if (op_mode == 3) {
            // EXT.L
            self.d[reg] = @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(self.d[reg]))))));
            self.setFlags_NZ(self.d[reg], .long);
        } else if (op_mode == 7) {
            // EXTB.L
            self.d[reg] = @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(self.d[reg]))))));
            self.setFlags_NZ(self.d[reg], .long);
        }

        self.sr.v = false;
        self.sr.c = false;
        return 4;
    }

    fn opLEA(self: *M68K, bus: anytype, mode: u3, reg: u3, dst: u3) u32 {
        self.a[dst] = self.getEA(bus, mode, reg, .long);
        return 4;
    }

    fn opControl(self: *M68K, opcode: u16, bus: anytype) u32 {
        const nibble_hi: u4 = @truncate((opcode >> 4) & 0xF);
        const nibble_lo: u4 = @truncate(opcode & 0xF);

        return switch (nibble_hi) {
            4 => blk: { // TRAP #vector
                const vector: u32 = 32 + @as(u32, nibble_lo);
                if (!self.sr.s) {
                    self.usp = self.a[7];
                    self.a[7] = self.ssp;
                }
                self.push32(bus, self.pc);
                self.push16(bus, @bitCast(self.sr));
                self.sr.s = true;
                self.pc = bus.read32(vector * 4);
                break :blk 34;
            },
            5 => blk: { // LINK / UNLK
                const reg: u3 = @truncate(opcode & 7);
                if (opcode & 0x8 != 0) {
                    // UNLK An
                    self.a[7] = self.a[reg];
                    self.a[reg] = self.pop32(bus);
                    break :blk 12;
                } else {
                    // LINK An, #disp
                    self.push32(bus, self.a[reg]);
                    self.a[reg] = self.a[7];
                    const disp: i16 = @bitCast(self.fetchWord(bus));
                    self.a[7] = @bitCast(@as(i32, @bitCast(self.a[7])) +% disp);
                    break :blk 16;
                }
            },
            6 => blk: { // MOVE USP
                if (!self.sr.s) break :blk 4;
                const reg: u3 = @truncate(opcode & 7);
                if (opcode & 0x8 != 0) {
                    // MOVE USP, An
                    self.a[reg] = self.usp;
                } else {
                    // MOVE An, USP
                    self.usp = self.a[reg];
                }
                break :blk 4;
            },
            7 => switch (nibble_lo) {
                0 => 4, // RESET
                1 => 4, // NOP
                2 => blk: { // STOP
                    if (!self.sr.s) break :blk 4;
                    const old_s = self.sr.s;
                    const new_sr: SR = @bitCast(self.fetchWord(bus));
                    // Handle stack pointer switch if S bit changes
                    if (old_s and !new_sr.s) {
                        self.ssp = self.a[7];
                        self.a[7] = self.usp;
                    }
                    self.sr = new_sr;
                    self.stopped = true;
                    break :blk 4;
                },
                3 => blk: { // RTE
                    if (!self.sr.s) break :blk 4;
                    const popped_sr = self.pop16(bus);
                    self.sr = @bitCast(popped_sr);
                    self.pc = self.pop32(bus);
                    if (!self.sr.s) {
                        self.ssp = self.a[7];
                        self.a[7] = self.usp;
                    }
                    break :blk 20;
                },
                5 => blk: { // RTS
                    const addr = self.pop32(bus);
                    if (addr & 1 != 0) {
                        break :blk self.addressError(bus, addr, 0x4E75);
                    }
                    self.pc = addr;
                    break :blk 16;
                },
                6 => 4, // TRAPV
                7 => blk: { // RTR
                    const cc: u8 = @truncate(self.pop16(bus));
                    const old_sr: u16 = @bitCast(self.sr);
                    self.sr = @bitCast((old_sr & 0xFF00) | cc);
                    self.pc = self.pop32(bus);
                    break :blk 20;
                },
                else => 4,
            },
            else => 4,
        };
    }

    fn addressError(self: *M68K, bus: anytype, addr: u32, opcode: u16) u32 {
        // For instruction fetch errors (JSR/JMP/BSR/Bcc), saved PC is addr-4
        // Status word: (opcode | 0x001E) & 0xFFFE for instruction fetch
        const status_word = (opcode | 0x001E) & 0xFFFE;
        return self.addressErrorWithPC(bus, addr, opcode, addr -% 4, status_word);
    }

    fn addressErrorWithPC(self: *M68K, bus: anytype, addr: u32, opcode: u16, saved_pc: u32, status_word: u16) u32 {
        // Push exception frame for Address Error (vector 3)
        // 68000 order (pushed high to low): PC, SR, IR, Access addr, Status word
        if (!self.sr.s) {
            self.usp = self.a[7];
            self.a[7] = self.ssp;
        }
        self.push32(bus, saved_pc); // Program counter
        self.push16(bus, @bitCast(self.sr)); // Status register
        self.push16(bus, opcode); // Instruction register
        self.push32(bus, addr); // Access address
        self.push16(bus, status_word); // Function word
        self.sr.s = true;
        self.pc = bus.read32(3 * 4); // Vector 3 = Address Error
        return 50;
    }

    fn opJSR(self: *M68K, bus: anytype, mode: u3, reg: u3) u32 {
        const addr = self.getEA(bus, mode, reg, .long);
        if (addr & 1 != 0) {
            return self.addressError(bus, addr, 0x4E80 | (@as(u16, mode) << 3) | reg);
        }
        self.push32(bus, self.pc);
        self.pc = addr;
        return 18;
    }

    fn opJMP(self: *M68K, bus: anytype, mode: u3, reg: u3) u32 {
        const addr = self.getEA(bus, mode, reg, .long);
        if (addr & 1 != 0) {
            return self.addressError(bus, addr, 0x4EC0 | (@as(u16, mode) << 3) | reg);
        }
        self.pc = addr;
        return 8;
    }

    fn opAddqSubq(self: *M68K, opcode: u16, bus: anytype) u32 {
        const size_bits = (opcode >> 6) & 3;

        // Size = 3 means Scc or DBcc, not ADDQ/SUBQ
        if (size_bits == 3) {
            return self.opSccDBcc(opcode, bus);
        }

        var data: u32 = (opcode >> 9) & 7;
        if (data == 0) data = 8;

        const size: Size = @enumFromInt(size_bits);
        const mode: u3 = @truncate((opcode >> 3) & 7);
        const reg: u3 = @truncate(opcode & 7);
        const is_sub = opcode & 0x0100 != 0;

        if (mode == 0) {
            // Data register
            const val = self.d[reg] & size.mask();
            const result = if (is_sub) self.sub(val, data, size) else self.add(val, data, size);
            self.d[reg] = (self.d[reg] & ~size.mask()) | (result & size.mask());
            self.sr.x = self.sr.c;
            return if (size == .long) 8 else 4;
        }

        if (mode == 1) {
            // Address register - no flags
            if (is_sub) {
                self.a[reg] -%= data;
            } else {
                self.a[reg] +%= data;
            }
            return 8;
        }

        // Memory EA - get address once, then read-modify-write
        const addr = self.getEA(bus, mode, reg, size);
        const val: u32 = switch (size) {
            .byte => bus.read8(addr),
            .word => bus.read16(addr),
            .long => bus.read32(addr),
        };
        const result = if (is_sub) self.sub(val, data, size) else self.add(val, data, size);
        switch (size) {
            .byte => bus.write8(addr, @truncate(result)),
            .word => bus.write16(addr, @truncate(result)),
            .long => bus.write32(addr, result),
        }
        self.sr.x = self.sr.c;

        return if (size == .long) 8 else 4;
    }

    fn opSccDBcc(self: *M68K, opcode: u16, bus: anytype) u32 {
        const cond: u4 = @truncate((opcode >> 8) & 0xF);
        const mode: u3 = @truncate((opcode >> 3) & 7);
        const reg: u3 = @truncate(opcode & 7);

        if (mode == 1) {
            // DBcc - decrement and branch
            const disp = @as(i16, @bitCast(self.fetchWord(bus)));
            if (!self.checkCondition(cond)) {
                const dn = @as(i16, @bitCast(@as(u16, @truncate(self.d[reg]))));
                const result = dn -% 1;
                self.d[reg] = (self.d[reg] & 0xFFFF0000) | @as(u32, @bitCast(@as(i32, result) & 0xFFFF));
                if (result != -1) {
                    self.pc = @bitCast(@as(i32, @bitCast(self.pc)) +% disp - 2);
                    return 10;
                }
            }
            return 14;
        }

        // Scc - set according to condition
        const result: u32 = if (self.checkCondition(cond)) 0xFF else 0x00;
        self.writeEA(bus, mode, reg, .byte, result);
        return if (self.checkCondition(cond)) 6 else 4;
    }

    fn opBranch(self: *M68K, opcode: u16, bus: anytype) u32 {
        const cond: u4 = @truncate((opcode >> 8) & 0xF);
        var disp: i32 = @as(i8, @bitCast(@as(u8, @truncate(opcode))));

        // Save base PC for target calculation (relative to PC after opcode)
        const base_pc = self.pc;

        // Only 0 means word displacement on 68000
        // Note: 68000 does NOT support 32-bit displacement ($FF is just -1)
        if (disp == 0) {
            disp = @as(i16, @bitCast(self.fetchWord(bus)));
        }

        // Return address is PC after entire instruction
        const return_addr = self.pc;

        // Target is relative to PC after opcode word (not after displacement)
        const target: u32 = @bitCast(@as(i32, @bitCast(base_pc)) +% disp);

        // BSR - push return address BEFORE checking target (68000 behavior)
        if (cond == 1) {
            self.push32(bus, return_addr);
            if (target & 1 != 0) {
                return self.addressError(bus, target, opcode);
            }
            self.pc = target;
            return 18;
        }

        if (self.checkCondition(cond)) {
            if (target & 1 != 0) {
                return self.addressError(bus, target, opcode);
            }
            self.pc = target;
            return 10;
        }
        return 8;
    }

    fn opMoveq(self: *M68K, opcode: u16, bus: anytype) u32 {
        _ = bus;
        const reg: u3 = @truncate((opcode >> 9) & 7);
        const data: i8 = @bitCast(@as(u8, @truncate(opcode)));
        self.d[reg] = @bitCast(@as(i32, data));
        self.setFlags_NZ(self.d[reg], .long);
        self.sr.v = false;
        self.sr.c = false;
        return 4;
    }

    fn opOrDivSbcd(self: *M68K, opcode: u16, bus: anytype) u32 {
        const reg: u3 = @truncate((opcode >> 9) & 7);
        const mode: u3 = @truncate((opcode >> 3) & 7);
        const ea_reg: u3 = @truncate(opcode & 7);
        const opmode = (opcode >> 6) & 7;

        if (opmode == 3) {
            // DIVU
            const dividend = self.d[reg];
            const divisor: u32 = self.readEA(bus, mode, ea_reg, .word);
            if (divisor == 0) {
                // Division by zero trap
                return 38;
            }
            const quotient = dividend / divisor;
            const remainder = dividend % divisor;
            if (quotient > 0xFFFF) {
                self.sr.v = true;
                self.sr.c = false;
            } else {
                self.d[reg] = (remainder << 16) | (quotient & 0xFFFF);
                self.sr.z = (quotient & 0xFFFF) == 0;
                self.sr.n = (quotient & 0x8000) != 0;
                self.sr.v = false;
                self.sr.c = false;
            }
            return 140;
        }

        if (opmode == 7) {
            // DIVS
            const dividend: i32 = @bitCast(self.d[reg]);
            const divisor: i32 = @as(i16, @bitCast(@as(u16, @truncate(self.readEA(bus, mode, ea_reg, .word)))));
            if (divisor == 0) {
                return 38;
            }
            const quotient = @divTrunc(dividend, divisor);
            const remainder = @rem(dividend, divisor);
            if (quotient > 32767 or quotient < -32768) {
                self.sr.v = true;
                self.sr.c = false;
            } else {
                self.d[reg] = (@as(u32, @bitCast(remainder)) << 16) | (@as(u32, @bitCast(quotient)) & 0xFFFF);
                self.sr.z = (quotient & 0xFFFF) == 0;
                self.sr.n = quotient < 0;
                self.sr.v = false;
                self.sr.c = false;
            }
            return 158;
        }

        // OR
        const size: Size = @enumFromInt(opmode & 3);
        const to_reg = opmode < 4;

        if (to_reg) {
            const val = self.readEA(bus, mode, ea_reg, size);
            const result = (self.d[reg] | val) & size.mask();
            self.d[reg] = (self.d[reg] & ~size.mask()) | result;
            self.setFlags_NZ(result, size);
        } else {
            const val = self.readEA(bus, mode, ea_reg, size);
            const result = (val | self.d[reg]) & size.mask();
            self.writeEA(bus, mode, ea_reg, size, result);
            self.setFlags_NZ(result, size);
        }
        self.sr.v = false;
        self.sr.c = false;

        return if (size == .long) 8 else 4;
    }

    fn opSub(self: *M68K, opcode: u16, bus: anytype) u32 {
        const reg: u3 = @truncate((opcode >> 9) & 7);
        const mode: u3 = @truncate((opcode >> 3) & 7);
        const ea_reg: u3 = @truncate(opcode & 7);
        const opmode = (opcode >> 6) & 7;

        if (opmode == 3 or opmode == 7) {
            // SUBA
            const size: Size = if (opmode == 3) .word else .long;
            var val = self.readEA(bus, mode, ea_reg, size);
            if (size == .word) val = @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(val))))));
            self.a[reg] -%= val;
            return if (size == .long) 8 else 8;
        }

        const size: Size = @enumFromInt(opmode & 3);
        const to_reg = opmode < 4;

        if (to_reg) {
            const val = self.readEA(bus, mode, ea_reg, size);
            const result = self.sub(self.d[reg], val, size);
            self.d[reg] = (self.d[reg] & ~size.mask()) | result;
        } else {
            const val = self.readEA(bus, mode, ea_reg, size);
            const result = self.sub(val, self.d[reg], size);
            self.writeEA(bus, mode, ea_reg, size, result);
        }
        self.sr.x = self.sr.c;

        return if (size == .long) 8 else 4;
    }

    fn opCmpEor(self: *M68K, opcode: u16, bus: anytype) u32 {
        const reg: u3 = @truncate((opcode >> 9) & 7);
        const mode: u3 = @truncate((opcode >> 3) & 7);
        const ea_reg: u3 = @truncate(opcode & 7);
        const opmode = (opcode >> 6) & 7;

        if (opmode == 3 or opmode == 7) {
            // CMPA
            const size: Size = if (opmode == 3) .word else .long;
            var val = self.readEA(bus, mode, ea_reg, size);
            if (size == .word) val = @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(val))))));
            _ = self.sub(self.a[reg], val, .long);
            return if (size == .long) 6 else 6;
        }

        const size: Size = @enumFromInt(opmode & 3);

        if (opmode >= 4) {
            // EOR
            const val = self.readEA(bus, mode, ea_reg, size);
            const result = (val ^ self.d[reg]) & size.mask();
            self.writeEA(bus, mode, ea_reg, size, result);
            self.setFlags_NZ(result, size);
            self.sr.v = false;
            self.sr.c = false;
        } else {
            // CMP
            const val = self.readEA(bus, mode, ea_reg, size);
            _ = self.sub(self.d[reg], val, size);
        }

        return if (size == .long) 6 else 4;
    }

    fn opAndMulAbcdExg(self: *M68K, opcode: u16, bus: anytype) u32 {
        const reg: u3 = @truncate((opcode >> 9) & 7);
        const mode: u3 = @truncate((opcode >> 3) & 7);
        const ea_reg: u3 = @truncate(opcode & 7);
        const opmode = (opcode >> 6) & 7;

        if (opmode == 3) {
            // MULU
            const src: u32 = self.readEA(bus, mode, ea_reg, .word);
            self.d[reg] = (self.d[reg] & 0xFFFF) * src;
            self.setFlags_NZ(self.d[reg], .long);
            self.sr.v = false;
            self.sr.c = false;
            return 70;
        }

        if (opmode == 7) {
            // MULS
            const src: i16 = @bitCast(@as(u16, @truncate(self.readEA(bus, mode, ea_reg, .word))));
            const dst: i16 = @bitCast(@as(u16, @truncate(self.d[reg])));
            self.d[reg] = @bitCast(@as(i32, src) * dst);
            self.setFlags_NZ(self.d[reg], .long);
            self.sr.v = false;
            self.sr.c = false;
            return 70;
        }

        if (opmode == 4 and mode == 0) {
            // ABCD (reg)
            return 6;
        }
        if (opmode == 4 and mode == 1) {
            // ABCD (mem)
            return 18;
        }
        if (opmode == 5 and mode == 0) {
            // EXG Dn,Dn
            std.mem.swap(u32, &self.d[reg], &self.d[ea_reg]);
            return 6;
        }
        if (opmode == 5 and mode == 1) {
            // EXG An,An
            std.mem.swap(u32, &self.a[reg], &self.a[ea_reg]);
            return 6;
        }
        if (opmode == 6 and mode == 1) {
            // EXG Dn,An
            std.mem.swap(u32, &self.d[reg], &self.a[ea_reg]);
            return 6;
        }

        // AND
        const size: Size = @enumFromInt(opmode & 3);
        const to_reg = opmode < 4;

        if (to_reg) {
            const val = self.readEA(bus, mode, ea_reg, size);
            const result = (self.d[reg] & val) & size.mask();
            self.d[reg] = (self.d[reg] & ~size.mask()) | result;
            self.setFlags_NZ(result, size);
        } else {
            const val = self.readEA(bus, mode, ea_reg, size);
            const result = (val & self.d[reg]) & size.mask();
            self.writeEA(bus, mode, ea_reg, size, result);
            self.setFlags_NZ(result, size);
        }
        self.sr.v = false;
        self.sr.c = false;

        return if (size == .long) 8 else 4;
    }

    fn opAdd(self: *M68K, opcode: u16, bus: anytype) u32 {
        const reg: u3 = @truncate((opcode >> 9) & 7);
        const mode: u3 = @truncate((opcode >> 3) & 7);
        const ea_reg: u3 = @truncate(opcode & 7);
        const opmode = (opcode >> 6) & 7;

        if (opmode == 3 or opmode == 7) {
            // ADDA
            const size: Size = if (opmode == 3) .word else .long;
            var val = self.readEA(bus, mode, ea_reg, size);
            if (size == .word) val = @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(val))))));
            self.a[reg] +%= val;
            return if (size == .long) 8 else 8;
        }

        const size: Size = @enumFromInt(opmode & 3);
        const to_reg = opmode < 4;

        if (to_reg) {
            const val = self.readEA(bus, mode, ea_reg, size);
            const result = self.add(self.d[reg], val, size);
            self.d[reg] = (self.d[reg] & ~size.mask()) | result;
        } else {
            const val = self.readEA(bus, mode, ea_reg, size);
            const result = self.add(val, self.d[reg], size);
            self.writeEA(bus, mode, ea_reg, size, result);
        }
        self.sr.x = self.sr.c;

        return if (size == .long) 8 else 4;
    }

    fn opShift(self: *M68K, opcode: u16, bus: anytype) u32 {
        const reg: u3 = @truncate(opcode & 7);
        const dr = (opcode >> 8) & 1 != 0; // Left or right
        const size_bits = (opcode >> 6) & 3;

        // Size = 3 means memory shift operation
        if (size_bits == 3) {
            const mode: u3 = @truncate((opcode >> 3) & 7);
            const typ: u2 = @truncate((opcode >> 9) & 3);
            const val = self.readEA(bus, mode, reg, .word);
            const result = if (dr)
                self.shiftLeft(val, 1, .word, typ)
            else
                self.shiftRight(val, 1, .word, typ);
            self.writeEA(bus, mode, reg, .word, result);
            return 8;
        }

        const size: Size = @enumFromInt(size_bits);
        const ir = (opcode >> 5) & 1 != 0; // Immediate or register count
        const typ: u2 = @truncate((opcode >> 3) & 3); // ASL/LSL/ROXL/ROL
        const count_reg: u3 = @truncate((opcode >> 9) & 7);

        var count: u32 = if (ir) self.d[count_reg] & 63 else @as(u32, count_reg);
        if (!ir and count == 0) count = 8;

        const val = self.d[reg] & size.mask();
        const result = if (dr)
            self.shiftLeft(val, count, size, typ)
        else
            self.shiftRight(val, count, size, typ);

        self.d[reg] = (self.d[reg] & ~size.mask()) | result;

        return 6 + count * 2;
    }

    fn shiftLeft(self: *M68K, val: u32, count: u32, size: Size, typ: u2) u32 {
        if (count == 0) {
            self.setFlags_NZ(val, size);
            self.sr.c = false;
            self.sr.v = false;
            return val;
        }

        var result = val;
        var carry = false;
        var overflow = false;
        const x_in = self.sr.x;

        for (0..count) |_| {
            carry = (result & size.signBit()) != 0;
            result = (result << 1) & size.mask();

            if (typ == 2) { // ROXL
                if (x_in) result |= 1;
                self.sr.x = carry;
            }
            if (typ == 3) { // ROL
                if (carry) result |= 1;
            }
            if (typ == 0) { // ASL
                if ((result & size.signBit() != 0) != carry) overflow = true;
                self.sr.x = carry;
            }
            if (typ == 1) { // LSL
                self.sr.x = carry;
            }
        }

        self.setFlags_NZ(result, size);
        self.sr.c = carry;
        self.sr.v = if (typ == 0) overflow else false;

        return result;
    }

    fn shiftRight(self: *M68K, val: u32, count: u32, size: Size, typ: u2) u32 {
        if (count == 0) {
            self.setFlags_NZ(val, size);
            self.sr.c = false;
            self.sr.v = false;
            return val;
        }

        var result = val;
        var carry = false;
        const sign = val & size.signBit();
        const x_in = self.sr.x;

        for (0..count) |_| {
            carry = (result & 1) != 0;
            result >>= 1;

            if (typ == 0 and sign != 0) result |= size.signBit(); // ASR
            if (typ == 2) { // ROXR
                if (x_in) result |= size.signBit();
                self.sr.x = carry;
            }
            if (typ == 3) { // ROR
                if (carry) result |= size.signBit();
            }
            if (typ == 0 or typ == 1) { // ASR/LSR
                self.sr.x = carry;
            }
        }

        self.setFlags_NZ(result, size);
        self.sr.c = carry;
        self.sr.v = false;

        return result;
    }

    // =========================================================================
    // Flag helpers
    // =========================================================================

    fn setFlags_NZ(self: *M68K, val: u32, size: Size) void {
        const masked = val & size.mask();
        self.sr.z = masked == 0;
        self.sr.n = (masked & size.signBit()) != 0;
    }

    fn add(self: *M68K, a: u32, b: u32, size: Size) u32 {
        const mask = size.mask();
        const sign = size.signBit();
        const result = (a & mask) +% (b & mask);
        const masked = result & mask;

        self.sr.z = masked == 0;
        self.sr.n = (masked & sign) != 0;
        self.sr.c = result > mask;
        self.sr.v = ((a ^ result) & (b ^ result) & sign) != 0;

        return masked;
    }

    fn sub(self: *M68K, a: u32, b: u32, size: Size) u32 {
        const mask = size.mask();
        const sign = size.signBit();
        const result = (a & mask) -% (b & mask);
        const masked = result & mask;

        self.sr.z = masked == 0;
        self.sr.n = (masked & sign) != 0;
        self.sr.c = (b & mask) > (a & mask);
        self.sr.v = ((a ^ b) & (a ^ masked) & sign) != 0;

        return masked;
    }

    fn checkCondition(self: *M68K, cond: u4) bool {
        return switch (cond) {
            0x0 => true, // T (BRA)
            0x1 => false, // F (BSR handled separately)
            0x2 => !self.sr.c and !self.sr.z, // HI
            0x3 => self.sr.c or self.sr.z, // LS
            0x4 => !self.sr.c, // CC
            0x5 => self.sr.c, // CS
            0x6 => !self.sr.z, // NE
            0x7 => self.sr.z, // EQ
            0x8 => !self.sr.v, // VC
            0x9 => self.sr.v, // VS
            0xA => !self.sr.n, // PL
            0xB => self.sr.n, // MI
            0xC => self.sr.n == self.sr.v, // GE
            0xD => self.sr.n != self.sr.v, // LT
            0xE => !self.sr.z and (self.sr.n == self.sr.v), // GT
            0xF => self.sr.z or (self.sr.n != self.sr.v), // LE
        };
    }
};
