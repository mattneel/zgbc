//! Z80 CPU
//! Real Zilog Z80 @ 3.58 MHz for Sega Master System.
//! Generic over bus type for testing with ZEXALL.

const std = @import("std");

pub const CPU = struct {
    // Main registers
    a: u8 = 0,
    f: Flags = .{},
    b: u8 = 0,
    c: u8 = 0,
    d: u8 = 0,
    e: u8 = 0,
    h: u8 = 0,
    l: u8 = 0,

    // Alternate registers (Z80 specific)
    a_: u8 = 0,
    f_: Flags = .{},
    b_: u8 = 0,
    c_: u8 = 0,
    d_: u8 = 0,
    e_: u8 = 0,
    h_: u8 = 0,
    l_: u8 = 0,

    // Index registers (Z80 specific)
    ix: u16 = 0,
    iy: u16 = 0,

    // Other registers
    sp: u16 = 0xDFF0,
    pc: u16 = 0,
    i: u8 = 0, // Interrupt vector
    r: u8 = 0, // Refresh counter

    // Interrupt state
    iff1: bool = false,
    iff2: bool = false,
    im: u2 = 0, // Interrupt mode
    halted: bool = false,
    nmi_pending: bool = false,
    irq_pending: bool = false,

    pub const Flags = packed struct {
        c: bool = false, // Carry (bit 0)
        n: bool = false, // Add/Subtract (bit 1)
        pv: bool = false, // Parity/Overflow (bit 2)
        x: bool = false, // Undocumented X flag (bit 3) - copy of result bit 3
        h: bool = false, // Half carry (bit 4)
        y: bool = false, // Undocumented Y flag (bit 5) - copy of result bit 5
        z: bool = false, // Zero (bit 6)
        s: bool = false, // Sign (bit 7)
    };

    // Register pair accessors
    pub fn getAF(self: *CPU) u16 {
        return (@as(u16, self.a) << 8) | @as(u8, @bitCast(self.f));
    }
    pub fn setAF(self: *CPU, val: u16) void {
        self.a = @truncate(val >> 8);
        self.f = @bitCast(@as(u8, @truncate(val)));
    }
    pub fn getBC(self: *CPU) u16 {
        return (@as(u16, self.b) << 8) | self.c;
    }
    pub fn setBC(self: *CPU, val: u16) void {
        self.b = @truncate(val >> 8);
        self.c = @truncate(val);
    }
    pub fn getDE(self: *CPU) u16 {
        return (@as(u16, self.d) << 8) | self.e;
    }
    pub fn setDE(self: *CPU, val: u16) void {
        self.d = @truncate(val >> 8);
        self.e = @truncate(val);
    }
    pub fn getHL(self: *CPU) u16 {
        return (@as(u16, self.h) << 8) | self.l;
    }
    pub fn setHL(self: *CPU, val: u16) void {
        self.h = @truncate(val >> 8);
        self.l = @truncate(val);
    }

    fn fetch(self: *CPU, bus: anytype) u8 {
        const val = bus.read(self.pc);
        self.pc +%= 1;
        return val;
    }

    fn fetch16(self: *CPU, bus: anytype) u16 {
        const lo = self.fetch(bus);
        const hi = self.fetch(bus);
        return (@as(u16, hi) << 8) | lo;
    }

    fn push(self: *CPU, bus: anytype, val: u16) void {
        self.sp -%= 1;
        bus.write(self.sp, @truncate(val >> 8));
        self.sp -%= 1;
        bus.write(self.sp, @truncate(val));
    }

    pub fn pop(self: *CPU, bus: anytype) u16 {
        const lo = bus.read(self.sp);
        self.sp +%= 1;
        const hi = bus.read(self.sp);
        self.sp +%= 1;
        return (@as(u16, hi) << 8) | lo;
    }

    pub fn step(self: *CPU, bus: anytype) u8 {
        // Handle interrupts
        if (self.nmi_pending) {
            self.nmi_pending = false;
            self.halted = false;
            self.iff2 = self.iff1;
            self.iff1 = false;
            self.push(bus, self.pc);
            self.pc = 0x0066;
            return 11;
        }

        if (self.irq_pending and self.iff1) {
            self.halted = false;
            self.iff1 = false;
            self.iff2 = false;
            self.push(bus, self.pc);
            self.pc = 0x0038; // IM 1 vector (SMS uses IM 1)
            return 13;
        }

        if (self.halted) return 4;

        self.r +%= 1;
        const opcode = self.fetch(bus);

        return switch (opcode) {
            0xCB => self.executeCB(bus),
            0xED => self.executeED(bus),
            0xDD => self.executeIndexed(bus, &self.ix),
            0xFD => self.executeIndexed(bus, &self.iy),
            else => self.executeMain(opcode, bus),
        };
    }

    fn executeMain(self: *CPU, opcode: u8, bus: anytype) u8 {
        return switch (opcode) {
            0x00 => 4, // NOP
            0x01 => { self.setBC(self.fetch16(bus)); return 10; }, // LD BC,nn
            0x02 => { bus.write(self.getBC(), self.a); return 7; }, // LD (BC),A
            0x03 => { self.setBC(self.getBC() +% 1); return 6; }, // INC BC
            0x04 => { self.b = self.inc8(self.b); return 4; }, // INC B
            0x05 => { self.b = self.dec8(self.b); return 4; }, // DEC B
            0x06 => { self.b = self.fetch(bus); return 7; }, // LD B,n
            0x07 => { self.rlca(); return 4; }, // RLCA
            0x08 => { self.exAF(); return 4; }, // EX AF,AF'
            0x09 => { self.addHL(self.getBC()); return 11; }, // ADD HL,BC
            0x0A => { self.a = bus.read(self.getBC()); return 7; }, // LD A,(BC)
            0x0B => { self.setBC(self.getBC() -% 1); return 6; }, // DEC BC
            0x0C => { self.c = self.inc8(self.c); return 4; }, // INC C
            0x0D => { self.c = self.dec8(self.c); return 4; }, // DEC C
            0x0E => { self.c = self.fetch(bus); return 7; }, // LD C,n
            0x0F => { self.rrca(); return 4; }, // RRCA

            0x10 => self.djnz(bus), // DJNZ
            0x11 => { self.setDE(self.fetch16(bus)); return 10; }, // LD DE,nn
            0x12 => { bus.write(self.getDE(), self.a); return 7; }, // LD (DE),A
            0x13 => { self.setDE(self.getDE() +% 1); return 6; }, // INC DE
            0x14 => { self.d = self.inc8(self.d); return 4; }, // INC D
            0x15 => { self.d = self.dec8(self.d); return 4; }, // DEC D
            0x16 => { self.d = self.fetch(bus); return 7; }, // LD D,n
            0x17 => { self.rla(); return 4; }, // RLA
            0x18 => { self.jr(bus, true); return 12; }, // JR e
            0x19 => { self.addHL(self.getDE()); return 11; }, // ADD HL,DE
            0x1A => { self.a = bus.read(self.getDE()); return 7; }, // LD A,(DE)
            0x1B => { self.setDE(self.getDE() -% 1); return 6; }, // DEC DE
            0x1C => { self.e = self.inc8(self.e); return 4; }, // INC E
            0x1D => { self.e = self.dec8(self.e); return 4; }, // DEC E
            0x1E => { self.e = self.fetch(bus); return 7; }, // LD E,n
            0x1F => { self.rra(); return 4; }, // RRA

            0x20 => self.jrCond(bus, !self.f.z), // JR NZ
            0x21 => { self.setHL(self.fetch16(bus)); return 10; }, // LD HL,nn
            0x22 => { const a = self.fetch16(bus); bus.write(a, self.l); bus.write(a +% 1, self.h); return 16; }, // LD (nn),HL
            0x23 => { self.setHL(self.getHL() +% 1); return 6; }, // INC HL
            0x24 => { self.h = self.inc8(self.h); return 4; }, // INC H
            0x25 => { self.h = self.dec8(self.h); return 4; }, // DEC H
            0x26 => { self.h = self.fetch(bus); return 7; }, // LD H,n
            0x27 => { self.daa(); return 4; }, // DAA
            0x28 => self.jrCond(bus, self.f.z), // JR Z
            0x29 => { self.addHL(self.getHL()); return 11; }, // ADD HL,HL
            0x2A => { const a = self.fetch16(bus); self.l = bus.read(a); self.h = bus.read(a +% 1); return 16; }, // LD HL,(nn)
            0x2B => { self.setHL(self.getHL() -% 1); return 6; }, // DEC HL
            0x2C => { self.l = self.inc8(self.l); return 4; }, // INC L
            0x2D => { self.l = self.dec8(self.l); return 4; }, // DEC L
            0x2E => { self.l = self.fetch(bus); return 7; }, // LD L,n
            0x2F => { // CPL
                self.a = ~self.a;
                self.f.h = true;
                self.f.n = true;
                self.f.x = self.a & 0x08 != 0;
                self.f.y = self.a & 0x20 != 0;
                return 4;
            },

            0x30 => self.jrCond(bus, !self.f.c), // JR NC
            0x31 => { self.sp = self.fetch16(bus); return 10; }, // LD SP,nn
            0x32 => { bus.write(self.fetch16(bus), self.a); return 13; }, // LD (nn),A
            0x33 => { self.sp +%= 1; return 6; }, // INC SP
            0x34 => { const a = self.getHL(); bus.write(a, self.inc8(bus.read(a))); return 11; }, // INC (HL)
            0x35 => { const a = self.getHL(); bus.write(a, self.dec8(bus.read(a))); return 11; }, // DEC (HL)
            0x36 => { bus.write(self.getHL(), self.fetch(bus)); return 10; }, // LD (HL),n
            0x37 => { // SCF
                // X/Y from A OR current F (undocumented behavior)
                const f_val: u8 = @bitCast(self.f);
                const xy_src = self.a | f_val;
                self.f.c = true;
                self.f.h = false;
                self.f.n = false;
                self.f.x = xy_src & 0x08 != 0;
                self.f.y = xy_src & 0x20 != 0;
                return 4;
            },
            0x38 => self.jrCond(bus, self.f.c), // JR C
            0x39 => { self.addHL(self.sp); return 11; }, // ADD HL,SP
            0x3A => { self.a = bus.read(self.fetch16(bus)); return 13; }, // LD A,(nn)
            0x3B => { self.sp -%= 1; return 6; }, // DEC SP
            0x3C => { self.a = self.inc8(self.a); return 4; }, // INC A
            0x3D => { self.a = self.dec8(self.a); return 4; }, // DEC A
            0x3E => { self.a = self.fetch(bus); return 7; }, // LD A,n
            0x3F => { // CCF
                // X/Y from A OR current F (undocumented behavior)
                const f_val: u8 = @bitCast(self.f);
                const xy_src = self.a | f_val;
                self.f.h = self.f.c;
                self.f.c = !self.f.c;
                self.f.n = false;
                self.f.x = xy_src & 0x08 != 0;
                self.f.y = xy_src & 0x20 != 0;
                return 4;
            },

            // LD r,r' (0x40-0x7F except 0x76)
            0x40 => 4, // LD B,B
            0x41 => { self.b = self.c; return 4; },
            0x42 => { self.b = self.d; return 4; },
            0x43 => { self.b = self.e; return 4; },
            0x44 => { self.b = self.h; return 4; },
            0x45 => { self.b = self.l; return 4; },
            0x46 => { self.b = bus.read(self.getHL()); return 7; },
            0x47 => { self.b = self.a; return 4; },
            0x48 => { self.c = self.b; return 4; },
            0x49 => 4, // LD C,C
            0x4A => { self.c = self.d; return 4; },
            0x4B => { self.c = self.e; return 4; },
            0x4C => { self.c = self.h; return 4; },
            0x4D => { self.c = self.l; return 4; },
            0x4E => { self.c = bus.read(self.getHL()); return 7; },
            0x4F => { self.c = self.a; return 4; },
            0x50 => { self.d = self.b; return 4; },
            0x51 => { self.d = self.c; return 4; },
            0x52 => 4, // LD D,D
            0x53 => { self.d = self.e; return 4; },
            0x54 => { self.d = self.h; return 4; },
            0x55 => { self.d = self.l; return 4; },
            0x56 => { self.d = bus.read(self.getHL()); return 7; },
            0x57 => { self.d = self.a; return 4; },
            0x58 => { self.e = self.b; return 4; },
            0x59 => { self.e = self.c; return 4; },
            0x5A => { self.e = self.d; return 4; },
            0x5B => 4, // LD E,E
            0x5C => { self.e = self.h; return 4; },
            0x5D => { self.e = self.l; return 4; },
            0x5E => { self.e = bus.read(self.getHL()); return 7; },
            0x5F => { self.e = self.a; return 4; },
            0x60 => { self.h = self.b; return 4; },
            0x61 => { self.h = self.c; return 4; },
            0x62 => { self.h = self.d; return 4; },
            0x63 => { self.h = self.e; return 4; },
            0x64 => 4, // LD H,H
            0x65 => { self.h = self.l; return 4; },
            0x66 => { self.h = bus.read(self.getHL()); return 7; },
            0x67 => { self.h = self.a; return 4; },
            0x68 => { self.l = self.b; return 4; },
            0x69 => { self.l = self.c; return 4; },
            0x6A => { self.l = self.d; return 4; },
            0x6B => { self.l = self.e; return 4; },
            0x6C => { self.l = self.h; return 4; },
            0x6D => 4, // LD L,L
            0x6E => { self.l = bus.read(self.getHL()); return 7; },
            0x6F => { self.l = self.a; return 4; },
            0x70 => { bus.write(self.getHL(), self.b); return 7; },
            0x71 => { bus.write(self.getHL(), self.c); return 7; },
            0x72 => { bus.write(self.getHL(), self.d); return 7; },
            0x73 => { bus.write(self.getHL(), self.e); return 7; },
            0x74 => { bus.write(self.getHL(), self.h); return 7; },
            0x75 => { bus.write(self.getHL(), self.l); return 7; },
            0x76 => { self.halted = true; return 4; }, // HALT
            0x77 => { bus.write(self.getHL(), self.a); return 7; },
            0x78 => { self.a = self.b; return 4; },
            0x79 => { self.a = self.c; return 4; },
            0x7A => { self.a = self.d; return 4; },
            0x7B => { self.a = self.e; return 4; },
            0x7C => { self.a = self.h; return 4; },
            0x7D => { self.a = self.l; return 4; },
            0x7E => { self.a = bus.read(self.getHL()); return 7; },
            0x7F => 4, // LD A,A

            // ALU operations (0x80-0xBF)
            0x80...0x87 => { self.add8(self.getReg8(@truncate(opcode & 7), bus)); return if (opcode & 7 == 6) 7 else 4; },
            0x88...0x8F => { self.adc8(self.getReg8(@truncate(opcode & 7), bus)); return if (opcode & 7 == 6) 7 else 4; },
            0x90...0x97 => { self.sub8(self.getReg8(@truncate(opcode & 7), bus)); return if (opcode & 7 == 6) 7 else 4; },
            0x98...0x9F => { self.sbc8(self.getReg8(@truncate(opcode & 7), bus)); return if (opcode & 7 == 6) 7 else 4; },
            0xA0...0xA7 => { self.and8(self.getReg8(@truncate(opcode & 7), bus)); return if (opcode & 7 == 6) 7 else 4; },
            0xA8...0xAF => { self.xor8(self.getReg8(@truncate(opcode & 7), bus)); return if (opcode & 7 == 6) 7 else 4; },
            0xB0...0xB7 => { self.or8(self.getReg8(@truncate(opcode & 7), bus)); return if (opcode & 7 == 6) 7 else 4; },
            0xB8...0xBF => { self.cp8(self.getReg8(@truncate(opcode & 7), bus)); return if (opcode & 7 == 6) 7 else 4; },

            // Misc (0xC0-0xFF)
            0xC0 => self.retCond(bus, !self.f.z),
            0xC1 => { self.setBC(self.pop(bus)); return 10; },
            0xC2 => self.jpCond(bus, !self.f.z),
            0xC3 => { self.pc = self.fetch16(bus); return 10; },
            0xC4 => self.callCond(bus, !self.f.z),
            0xC5 => { self.push(bus, self.getBC()); return 11; },
            0xC6 => { self.add8(self.fetch(bus)); return 7; },
            0xC7 => { self.push(bus, self.pc); self.pc = 0x00; return 11; },
            0xC8 => self.retCond(bus, self.f.z),
            0xC9 => { self.pc = self.pop(bus); return 10; },
            0xCA => self.jpCond(bus, self.f.z),
            // 0xCB handled separately
            0xCC => self.callCond(bus, self.f.z),
            0xCD => { const a = self.fetch16(bus); self.push(bus, self.pc); self.pc = a; return 17; },
            0xCE => { self.adc8(self.fetch(bus)); return 7; },
            0xCF => { self.push(bus, self.pc); self.pc = 0x08; return 11; },

            0xD0 => self.retCond(bus, !self.f.c),
            0xD1 => { self.setDE(self.pop(bus)); return 10; },
            0xD2 => self.jpCond(bus, !self.f.c),
            0xD3 => { bus.ioWrite(self.fetch(bus), self.a); return 11; }, // OUT (n),A
            0xD4 => self.callCond(bus, !self.f.c),
            0xD5 => { self.push(bus, self.getDE()); return 11; },
            0xD6 => { self.sub8(self.fetch(bus)); return 7; },
            0xD7 => { self.push(bus, self.pc); self.pc = 0x10; return 11; },
            0xD8 => self.retCond(bus, self.f.c),
            0xD9 => { self.exx(); return 4; }, // EXX
            0xDA => self.jpCond(bus, self.f.c),
            0xDB => { self.a = bus.ioRead(self.fetch(bus)); return 11; }, // IN A,(n)
            0xDC => self.callCond(bus, self.f.c),
            // 0xDD handled separately
            0xDE => { self.sbc8(self.fetch(bus)); return 7; },
            0xDF => { self.push(bus, self.pc); self.pc = 0x18; return 11; },

            0xE0 => self.retCond(bus, !self.f.pv),
            0xE1 => { self.setHL(self.pop(bus)); return 10; },
            0xE2 => self.jpCond(bus, !self.f.pv),
            0xE3 => { // EX (SP),HL
                const lo = bus.read(self.sp);
                const hi = bus.read(self.sp +% 1);
                bus.write(self.sp, self.l);
                bus.write(self.sp +% 1, self.h);
                self.l = lo;
                self.h = hi;
                return 19;
            },
            0xE4 => self.callCond(bus, !self.f.pv),
            0xE5 => { self.push(bus, self.getHL()); return 11; },
            0xE6 => { self.and8(self.fetch(bus)); return 7; },
            0xE7 => { self.push(bus, self.pc); self.pc = 0x20; return 11; },
            0xE8 => self.retCond(bus, self.f.pv),
            0xE9 => { self.pc = self.getHL(); return 4; }, // JP (HL)
            0xEA => self.jpCond(bus, self.f.pv),
            0xEB => { // EX DE,HL
                const tmp = self.getDE();
                self.setDE(self.getHL());
                self.setHL(tmp);
                return 4;
            },
            0xEC => self.callCond(bus, self.f.pv),
            // 0xED handled separately
            0xEE => { self.xor8(self.fetch(bus)); return 7; },
            0xEF => { self.push(bus, self.pc); self.pc = 0x28; return 11; },

            0xF0 => self.retCond(bus, !self.f.s),
            0xF1 => { self.setAF(self.pop(bus)); return 10; },
            0xF2 => self.jpCond(bus, !self.f.s),
            0xF3 => { self.iff1 = false; self.iff2 = false; return 4; }, // DI
            0xF4 => self.callCond(bus, !self.f.s),
            0xF5 => { self.push(bus, self.getAF()); return 11; },
            0xF6 => { self.or8(self.fetch(bus)); return 7; },
            0xF7 => { self.push(bus, self.pc); self.pc = 0x30; return 11; },
            0xF8 => self.retCond(bus, self.f.s),
            0xF9 => { self.sp = self.getHL(); return 6; }, // LD SP,HL
            0xFA => self.jpCond(bus, self.f.s),
            0xFB => { self.iff1 = true; self.iff2 = true; return 4; }, // EI
            0xFC => self.callCond(bus, self.f.s),
            // 0xFD handled separately
            0xFE => { self.cp8(self.fetch(bus)); return 7; },
            0xFF => { self.push(bus, self.pc); self.pc = 0x38; return 11; },

            else => 4, // Undefined
        };
    }

    fn executeCB(self: *CPU, bus: anytype) u8 {
        self.r +%= 1;
        const op = self.fetch(bus);
        const reg: u3 = @truncate(op & 0x07);
        const bit: u3 = @truncate((op >> 3) & 0x07);

        var val = self.getReg8(reg, bus);
        const cycles: u8 = if (reg == 6) 15 else 8;

        switch (@as(u2, @truncate(op >> 6))) {
            0 => { // Rotates/shifts
                val = switch (@as(u3, @truncate((op >> 3) & 0x07))) {
                    0 => self.rlc(val),
                    1 => self.rrc(val),
                    2 => self.rl(val),
                    3 => self.rr(val),
                    4 => self.sla(val),
                    5 => self.sra(val),
                    6 => self.sll(val), // Undocumented
                    7 => self.srl(val),
                };
                self.setReg8(reg, val, bus);
            },
            1 => { // BIT
                const tested_bit = (val >> bit) & 1;
                self.f.z = tested_bit == 0;
                self.f.pv = self.f.z; // P/V is same as Z for BIT
                self.f.s = (bit == 7) and (tested_bit != 0);
                self.f.h = true;
                self.f.n = false;
                // X/Y from the operand value (for BIT n,r) or from high byte of HL (for BIT n,(HL))
                if (reg == 6) {
                    // BIT n,(HL) - X/Y from high byte of HL
                    self.f.x = self.h & 0x08 != 0;
                    self.f.y = self.h & 0x20 != 0;
                } else {
                    // BIT n,r - X/Y from the operand value
                    self.f.x = val & 0x08 != 0;
                    self.f.y = val & 0x20 != 0;
                }
                return if (reg == 6) 12 else 8;
            },
            2 => { // RES
                val &= ~(@as(u8, 1) << bit);
                self.setReg8(reg, val, bus);
            },
            3 => { // SET
                val |= @as(u8, 1) << bit;
                self.setReg8(reg, val, bus);
            },
        }
        return cycles;
    }

    fn executeED(self: *CPU, bus: anytype) u8 {
        self.r +%= 1;
        const op = self.fetch(bus);

        return switch (op) {
            // IN r,(C)
            0x40 => { self.b = self.inReg(bus); return 12; },
            0x48 => { self.c = self.inReg(bus); return 12; },
            0x50 => { self.d = self.inReg(bus); return 12; },
            0x58 => { self.e = self.inReg(bus); return 12; },
            0x60 => { self.h = self.inReg(bus); return 12; },
            0x68 => { self.l = self.inReg(bus); return 12; },
            0x70 => { _ = self.inReg(bus); return 12; }, // IN (C) - flags only
            0x78 => { self.a = self.inReg(bus); return 12; },

            // OUT (C),r
            0x41 => { bus.ioWrite(self.c, self.b); return 12; },
            0x49 => { bus.ioWrite(self.c, self.c); return 12; },
            0x51 => { bus.ioWrite(self.c, self.d); return 12; },
            0x59 => { bus.ioWrite(self.c, self.e); return 12; },
            0x61 => { bus.ioWrite(self.c, self.h); return 12; },
            0x69 => { bus.ioWrite(self.c, self.l); return 12; },
            0x71 => { bus.ioWrite(self.c, 0); return 12; }, // OUT (C),0
            0x79 => { bus.ioWrite(self.c, self.a); return 12; },

            // SBC HL,rr
            0x42 => { self.sbcHL(self.getBC()); return 15; },
            0x52 => { self.sbcHL(self.getDE()); return 15; },
            0x62 => { self.sbcHL(self.getHL()); return 15; },
            0x72 => { self.sbcHL(self.sp); return 15; },

            // ADC HL,rr
            0x4A => { self.adcHL(self.getBC()); return 15; },
            0x5A => { self.adcHL(self.getDE()); return 15; },
            0x6A => { self.adcHL(self.getHL()); return 15; },
            0x7A => { self.adcHL(self.sp); return 15; },

            // LD (nn),rr
            0x43 => { const a = self.fetch16(bus); bus.write(a, self.c); bus.write(a +% 1, self.b); return 20; },
            0x53 => { const a = self.fetch16(bus); bus.write(a, self.e); bus.write(a +% 1, self.d); return 20; },
            0x63 => { const a = self.fetch16(bus); bus.write(a, self.l); bus.write(a +% 1, self.h); return 20; },
            0x73 => { const a = self.fetch16(bus); bus.write(a, @truncate(self.sp)); bus.write(a +% 1, @truncate(self.sp >> 8)); return 20; },

            // LD rr,(nn)
            0x4B => { const a = self.fetch16(bus); self.c = bus.read(a); self.b = bus.read(a +% 1); return 20; },
            0x5B => { const a = self.fetch16(bus); self.e = bus.read(a); self.d = bus.read(a +% 1); return 20; },
            0x6B => { const a = self.fetch16(bus); self.l = bus.read(a); self.h = bus.read(a +% 1); return 20; },
            0x7B => { const a = self.fetch16(bus); self.sp = @as(u16, bus.read(a +% 1)) << 8 | bus.read(a); return 20; },

            // NEG
            0x44, 0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C => {
                const old = self.a;
                self.a = 0 -% self.a;
                self.f.s = self.a & 0x80 != 0;
                self.f.z = self.a == 0;
                self.f.h = (old & 0x0F) != 0;
                self.f.pv = old == 0x80;
                self.f.n = true;
                self.f.c = old != 0;
                self.f.x = self.a & 0x08 != 0;
                self.f.y = self.a & 0x20 != 0;
                return 8;
            },

            // RETN
            0x45, 0x55, 0x5D, 0x65, 0x6D, 0x75, 0x7D => {
                self.iff1 = self.iff2;
                self.pc = self.pop(bus);
                return 14;
            },

            // RETI
            0x4D => {
                self.pc = self.pop(bus);
                return 14;
            },

            // IM n
            0x46, 0x66 => { self.im = 0; return 8; },
            0x56, 0x76 => { self.im = 1; return 8; },
            0x5E, 0x7E => { self.im = 2; return 8; },

            // LD I,A / LD A,I / LD R,A / LD A,R
            0x47 => { self.i = self.a; return 9; },
            0x4F => { self.r = self.a; return 9; },
            0x57 => {
                self.a = self.i;
                self.f.s = self.a & 0x80 != 0;
                self.f.z = self.a == 0;
                self.f.h = false;
                self.f.pv = self.iff2;
                self.f.n = false;
                return 9;
            },
            0x5F => {
                self.a = self.r;
                self.f.s = self.a & 0x80 != 0;
                self.f.z = self.a == 0;
                self.f.h = false;
                self.f.pv = self.iff2;
                self.f.n = false;
                return 9;
            },

            // RRD/RLD
            0x67 => { // RRD
                const m = bus.read(self.getHL());
                bus.write(self.getHL(), (self.a << 4) | (m >> 4));
                self.a = (self.a & 0xF0) | (m & 0x0F);
                self.f.s = self.a & 0x80 != 0;
                self.f.z = self.a == 0;
                self.f.h = false;
                self.f.pv = parity(self.a);
                self.f.n = false;
                self.f.x = self.a & 0x08 != 0;
                self.f.y = self.a & 0x20 != 0;
                return 18;
            },
            0x6F => { // RLD
                const m = bus.read(self.getHL());
                bus.write(self.getHL(), (m << 4) | (self.a & 0x0F));
                self.a = (self.a & 0xF0) | (m >> 4);
                self.f.s = self.a & 0x80 != 0;
                self.f.z = self.a == 0;
                self.f.h = false;
                self.f.pv = parity(self.a);
                self.f.n = false;
                self.f.x = self.a & 0x08 != 0;
                self.f.y = self.a & 0x20 != 0;
                return 18;
            },

            // Block instructions
            0xA0 => self.ldi(bus),
            0xA1 => self.cpi(bus),
            0xA2 => self.ini(bus),
            0xA3 => self.outi(bus),
            0xA8 => self.ldd(bus),
            0xA9 => self.cpd(bus),
            0xAA => self.ind(bus),
            0xAB => self.outd(bus),
            0xB0 => self.ldir(bus),
            0xB1 => self.cpir(bus),
            0xB2 => self.inir(bus),
            0xB3 => self.otir(bus),
            0xB8 => self.lddr(bus),
            0xB9 => self.cpdr(bus),
            0xBA => self.indr(bus),
            0xBB => self.otdr(bus),

            else => 8, // NOP for undefined
        };
    }

    fn executeIndexed(self: *CPU, bus: anytype, idx: *u16) u8 {
        self.r +%= 1;
        const op = self.fetch(bus);

        // DDCB/FDCB prefix
        if (op == 0xCB) {
            const d: i8 = @bitCast(self.fetch(bus));
            const addr = idx.* +% @as(u16, @bitCast(@as(i16, d)));
            const op2 = self.fetch(bus);
            return self.executeIndexedCB(bus, addr, op2);
        }

        return switch (op) {
            0x09 => { self.addIX(idx, self.getBC()); return 15; },
            0x19 => { self.addIX(idx, self.getDE()); return 15; },
            0x21 => { idx.* = self.fetch16(bus); return 14; },
            0x22 => { const a = self.fetch16(bus); bus.write(a, @truncate(idx.*)); bus.write(a +% 1, @truncate(idx.* >> 8)); return 20; },
            0x23 => { idx.* +%= 1; return 10; },
            0x24 => { const hi: u8 = @truncate(idx.* >> 8); idx.* = (idx.* & 0xFF) | (@as(u16, self.inc8(hi)) << 8); return 8; },
            0x25 => { const hi: u8 = @truncate(idx.* >> 8); idx.* = (idx.* & 0xFF) | (@as(u16, self.dec8(hi)) << 8); return 8; },
            0x26 => { idx.* = (idx.* & 0xFF) | (@as(u16, self.fetch(bus)) << 8); return 11; },
            0x29 => { self.addIX(idx, idx.*); return 15; },
            0x2A => { const a = self.fetch16(bus); idx.* = @as(u16, bus.read(a +% 1)) << 8 | bus.read(a); return 20; },
            0x2B => { idx.* -%= 1; return 10; },
            0x2C => { idx.* = (idx.* & 0xFF00) | self.inc8(@truncate(idx.*)); return 8; },
            0x2D => { idx.* = (idx.* & 0xFF00) | self.dec8(@truncate(idx.*)); return 8; },
            0x2E => { idx.* = (idx.* & 0xFF00) | self.fetch(bus); return 11; },
            0x34 => {
                const d: i8 = @bitCast(self.fetch(bus));
                const addr = idx.* +% @as(u16, @bitCast(@as(i16, d)));
                bus.write(addr, self.inc8(bus.read(addr)));
                return 23;
            },
            0x35 => {
                const d: i8 = @bitCast(self.fetch(bus));
                const addr = idx.* +% @as(u16, @bitCast(@as(i16, d)));
                bus.write(addr, self.dec8(bus.read(addr)));
                return 23;
            },
            0x36 => {
                const d: i8 = @bitCast(self.fetch(bus));
                const addr = idx.* +% @as(u16, @bitCast(@as(i16, d)));
                bus.write(addr, self.fetch(bus));
                return 19;
            },
            0x39 => { self.addIX(idx, self.sp); return 15; },

            // LD r,(IX+d)
            0x46 => { self.b = self.readIndexed(bus, idx.*); return 19; },
            0x4E => { self.c = self.readIndexed(bus, idx.*); return 19; },
            0x56 => { self.d = self.readIndexed(bus, idx.*); return 19; },
            0x5E => { self.e = self.readIndexed(bus, idx.*); return 19; },
            0x66 => { self.h = self.readIndexed(bus, idx.*); return 19; },
            0x6E => { self.l = self.readIndexed(bus, idx.*); return 19; },
            0x7E => { self.a = self.readIndexed(bus, idx.*); return 19; },

            // LD (IX+d),r
            0x70 => { self.writeIndexed(bus, idx.*, self.b); return 19; },
            0x71 => { self.writeIndexed(bus, idx.*, self.c); return 19; },
            0x72 => { self.writeIndexed(bus, idx.*, self.d); return 19; },
            0x73 => { self.writeIndexed(bus, idx.*, self.e); return 19; },
            0x74 => { self.writeIndexed(bus, idx.*, self.h); return 19; },
            0x75 => { self.writeIndexed(bus, idx.*, self.l); return 19; },
            0x77 => { self.writeIndexed(bus, idx.*, self.a); return 19; },

            // Undocumented IXH/IXL operations
            0x44 => { self.b = @truncate(idx.* >> 8); return 8; },
            0x45 => { self.b = @truncate(idx.*); return 8; },
            0x4C => { self.c = @truncate(idx.* >> 8); return 8; },
            0x4D => { self.c = @truncate(idx.*); return 8; },
            0x54 => { self.d = @truncate(idx.* >> 8); return 8; },
            0x55 => { self.d = @truncate(idx.*); return 8; },
            0x5C => { self.e = @truncate(idx.* >> 8); return 8; },
            0x5D => { self.e = @truncate(idx.*); return 8; },
            0x60 => { idx.* = (idx.* & 0xFF) | (@as(u16, self.b) << 8); return 8; },
            0x61 => { idx.* = (idx.* & 0xFF) | (@as(u16, self.c) << 8); return 8; },
            0x62 => { idx.* = (idx.* & 0xFF) | (@as(u16, self.d) << 8); return 8; },
            0x63 => { idx.* = (idx.* & 0xFF) | (@as(u16, self.e) << 8); return 8; },
            0x64 => 8, // LD IXH,IXH
            0x65 => { const lo: u8 = @truncate(idx.*); idx.* = (idx.* & 0xFF) | (@as(u16, lo) << 8); return 8; },
            0x67 => { idx.* = (idx.* & 0xFF) | (@as(u16, self.a) << 8); return 8; },
            0x68 => { idx.* = (idx.* & 0xFF00) | self.b; return 8; },
            0x69 => { idx.* = (idx.* & 0xFF00) | self.c; return 8; },
            0x6A => { idx.* = (idx.* & 0xFF00) | self.d; return 8; },
            0x6B => { idx.* = (idx.* & 0xFF00) | self.e; return 8; },
            0x6C => { const hi: u8 = @truncate(idx.* >> 8); idx.* = (idx.* & 0xFF00) | hi; return 8; },
            0x6D => 8, // LD IXL,IXL
            0x6F => { idx.* = (idx.* & 0xFF00) | self.a; return 8; },
            0x7C => { self.a = @truncate(idx.* >> 8); return 8; },
            0x7D => { self.a = @truncate(idx.*); return 8; },

            // ALU (IX+d)
            0x86 => { self.add8(self.readIndexed(bus, idx.*)); return 19; },
            0x8E => { self.adc8(self.readIndexed(bus, idx.*)); return 19; },
            0x96 => { self.sub8(self.readIndexed(bus, idx.*)); return 19; },
            0x9E => { self.sbc8(self.readIndexed(bus, idx.*)); return 19; },
            0xA6 => { self.and8(self.readIndexed(bus, idx.*)); return 19; },
            0xAE => { self.xor8(self.readIndexed(bus, idx.*)); return 19; },
            0xB6 => { self.or8(self.readIndexed(bus, idx.*)); return 19; },
            0xBE => { self.cp8(self.readIndexed(bus, idx.*)); return 19; },

            // Undocumented ALU IXH/IXL
            0x84 => { self.add8(@truncate(idx.* >> 8)); return 8; },
            0x85 => { self.add8(@truncate(idx.*)); return 8; },
            0x8C => { self.adc8(@truncate(idx.* >> 8)); return 8; },
            0x8D => { self.adc8(@truncate(idx.*)); return 8; },
            0x94 => { self.sub8(@truncate(idx.* >> 8)); return 8; },
            0x95 => { self.sub8(@truncate(idx.*)); return 8; },
            0x9C => { self.sbc8(@truncate(idx.* >> 8)); return 8; },
            0x9D => { self.sbc8(@truncate(idx.*)); return 8; },
            0xA4 => { self.and8(@truncate(idx.* >> 8)); return 8; },
            0xA5 => { self.and8(@truncate(idx.*)); return 8; },
            0xAC => { self.xor8(@truncate(idx.* >> 8)); return 8; },
            0xAD => { self.xor8(@truncate(idx.*)); return 8; },
            0xB4 => { self.or8(@truncate(idx.* >> 8)); return 8; },
            0xB5 => { self.or8(@truncate(idx.*)); return 8; },
            0xBC => { self.cp8(@truncate(idx.* >> 8)); return 8; },
            0xBD => { self.cp8(@truncate(idx.*)); return 8; },

            0xE1 => { idx.* = self.pop(bus); return 14; },
            0xE3 => {
                const lo = bus.read(self.sp);
                const hi = bus.read(self.sp +% 1);
                bus.write(self.sp, @truncate(idx.*));
                bus.write(self.sp +% 1, @truncate(idx.* >> 8));
                idx.* = (@as(u16, hi) << 8) | lo;
                return 23;
            },
            0xE5 => { self.push(bus, idx.*); return 15; },
            0xE9 => { self.pc = idx.*; return 8; },
            0xF9 => { self.sp = idx.*; return 10; },

            else => self.executeMain(op, bus), // Fall through to main decoder
        };
    }

    fn executeIndexedCB(self: *CPU, bus: anytype, addr: u16, op: u8) u8 {
        const bit: u3 = @truncate((op >> 3) & 0x07);
        const reg: u3 = @truncate(op & 0x07);
        var val = bus.read(addr);

        switch (@as(u2, @truncate(op >> 6))) {
            0 => { // Rotates/shifts
                val = switch (@as(u3, @truncate((op >> 3) & 0x07))) {
                    0 => self.rlc(val),
                    1 => self.rrc(val),
                    2 => self.rl(val),
                    3 => self.rr(val),
                    4 => self.sla(val),
                    5 => self.sra(val),
                    6 => self.sll(val),
                    7 => self.srl(val),
                };
                bus.write(addr, val);
                // Also store in register if specified (undocumented)
                if (reg != 6) self.setReg8(reg, val, bus);
                return 23;
            },
            1 => { // BIT (indexed)
                const tested_bit = (val >> bit) & 1;
                self.f.z = tested_bit == 0;
                self.f.pv = self.f.z; // P/V is same as Z for BIT
                self.f.s = (bit == 7) and (tested_bit != 0);
                self.f.h = true;
                self.f.n = false;
                // X/Y from high byte of the computed address
                self.f.x = addr & 0x0800 != 0;
                self.f.y = addr & 0x2000 != 0;
                return 20;
            },
            2 => { // RES
                val &= ~(@as(u8, 1) << bit);
                bus.write(addr, val);
                if (reg != 6) self.setReg8(reg, val, bus);
                return 23;
            },
            3 => { // SET
                val |= @as(u8, 1) << bit;
                bus.write(addr, val);
                if (reg != 6) self.setReg8(reg, val, bus);
                return 23;
            },
        }
    }

    fn readIndexed(self: *CPU, bus: anytype, idx: u16) u8 {
        const d: i8 = @bitCast(self.fetch(bus));
        const addr = idx +% @as(u16, @bitCast(@as(i16, d)));
        return bus.read(addr);
    }

    fn writeIndexed(self: *CPU, bus: anytype, idx: u16, val: u8) void {
        const d: i8 = @bitCast(self.fetch(bus));
        const addr = idx +% @as(u16, @bitCast(@as(i16, d)));
        bus.write(addr, val);
    }

    // Helper functions
    fn getReg8(self: *CPU, reg: u3, bus: anytype) u8 {
        return switch (reg) {
            0 => self.b,
            1 => self.c,
            2 => self.d,
            3 => self.e,
            4 => self.h,
            5 => self.l,
            6 => bus.read(self.getHL()),
            7 => self.a,
        };
    }

    fn setReg8(self: *CPU, reg: u3, val: u8, bus: anytype) void {
        switch (reg) {
            0 => self.b = val,
            1 => self.c = val,
            2 => self.d = val,
            3 => self.e = val,
            4 => self.h = val,
            5 => self.l = val,
            6 => bus.write(self.getHL(), val),
            7 => self.a = val,
        }
    }

    // ALU operations
    fn add8(self: *CPU, val: u8) void {
        const result = @as(u16, self.a) + val;
        self.f.h = (self.a & 0x0F) + (val & 0x0F) > 0x0F;
        self.f.pv = ((self.a ^ val ^ 0x80) & (self.a ^ @as(u8, @truncate(result)))) & 0x80 != 0;
        self.f.c = result > 0xFF;
        self.a = @truncate(result);
        self.f.s = self.a & 0x80 != 0;
        self.f.z = self.a == 0;
        self.f.n = false;
        self.f.x = self.a & 0x08 != 0;
        self.f.y = self.a & 0x20 != 0;
    }

    fn adc8(self: *CPU, val: u8) void {
        const c: u8 = if (self.f.c) 1 else 0;
        const result = @as(u16, self.a) + val + c;
        self.f.h = (self.a & 0x0F) + (val & 0x0F) + c > 0x0F;
        self.f.pv = ((self.a ^ val ^ 0x80) & (self.a ^ @as(u8, @truncate(result)))) & 0x80 != 0;
        self.f.c = result > 0xFF;
        self.a = @truncate(result);
        self.f.s = self.a & 0x80 != 0;
        self.f.z = self.a == 0;
        self.f.n = false;
        self.f.x = self.a & 0x08 != 0;
        self.f.y = self.a & 0x20 != 0;
    }

    fn sub8(self: *CPU, val: u8) void {
        const result = @as(i16, self.a) - val;
        self.f.h = (self.a & 0x0F) < (val & 0x0F);
        self.f.pv = ((self.a ^ val) & (self.a ^ @as(u8, @truncate(@as(u16, @bitCast(result)))))) & 0x80 != 0;
        self.f.c = result < 0;
        self.a = @truncate(@as(u16, @bitCast(result)));
        self.f.s = self.a & 0x80 != 0;
        self.f.z = self.a == 0;
        self.f.n = true;
        self.f.x = self.a & 0x08 != 0;
        self.f.y = self.a & 0x20 != 0;
    }

    fn sbc8(self: *CPU, val: u8) void {
        const c: u8 = if (self.f.c) 1 else 0;
        const result = @as(i16, self.a) - val - c;
        self.f.h = (self.a & 0x0F) < (val & 0x0F) + c;
        self.f.pv = ((self.a ^ val) & (self.a ^ @as(u8, @truncate(@as(u16, @bitCast(result)))))) & 0x80 != 0;
        self.f.c = result < 0;
        self.a = @truncate(@as(u16, @bitCast(result)));
        self.f.s = self.a & 0x80 != 0;
        self.f.z = self.a == 0;
        self.f.n = true;
        self.f.x = self.a & 0x08 != 0;
        self.f.y = self.a & 0x20 != 0;
    }

    fn and8(self: *CPU, val: u8) void {
        self.a &= val;
        self.f.s = self.a & 0x80 != 0;
        self.f.z = self.a == 0;
        self.f.h = true;
        self.f.pv = parity(self.a);
        self.f.n = false;
        self.f.c = false;
        self.f.x = self.a & 0x08 != 0;
        self.f.y = self.a & 0x20 != 0;
    }

    fn xor8(self: *CPU, val: u8) void {
        self.a ^= val;
        self.f.s = self.a & 0x80 != 0;
        self.f.z = self.a == 0;
        self.f.h = false;
        self.f.pv = parity(self.a);
        self.f.n = false;
        self.f.c = false;
        self.f.x = self.a & 0x08 != 0;
        self.f.y = self.a & 0x20 != 0;
    }

    fn or8(self: *CPU, val: u8) void {
        self.a |= val;
        self.f.s = self.a & 0x80 != 0;
        self.f.z = self.a == 0;
        self.f.h = false;
        self.f.pv = parity(self.a);
        self.f.n = false;
        self.f.c = false;
        self.f.x = self.a & 0x08 != 0;
        self.f.y = self.a & 0x20 != 0;
    }

    fn cp8(self: *CPU, val: u8) void {
        const result = @as(i16, self.a) - val;
        const r8 = @as(u8, @truncate(@as(u16, @bitCast(result))));
        self.f.s = r8 & 0x80 != 0;
        self.f.z = r8 == 0;
        self.f.h = (self.a & 0x0F) < (val & 0x0F);
        self.f.pv = ((self.a ^ val) & (self.a ^ r8)) & 0x80 != 0;
        self.f.n = true;
        self.f.c = result < 0;
        // CP is special: X and Y flags come from operand, not result
        self.f.x = val & 0x08 != 0;
        self.f.y = val & 0x20 != 0;
    }

    fn inc8(self: *CPU, val: u8) u8 {
        const result = val +% 1;
        self.f.s = result & 0x80 != 0;
        self.f.z = result == 0;
        self.f.h = (val & 0x0F) == 0x0F;
        self.f.pv = val == 0x7F;
        self.f.n = false;
        self.f.x = result & 0x08 != 0;
        self.f.y = result & 0x20 != 0;
        return result;
    }

    fn dec8(self: *CPU, val: u8) u8 {
        const result = val -% 1;
        self.f.s = result & 0x80 != 0;
        self.f.z = result == 0;
        self.f.h = (val & 0x0F) == 0x00;
        self.f.pv = val == 0x80;
        self.f.n = true;
        self.f.x = result & 0x08 != 0;
        self.f.y = result & 0x20 != 0;
        return result;
    }

    fn addHL(self: *CPU, val: u16) void {
        const hl = self.getHL();
        const result = @as(u32, hl) + val;
        self.f.h = (hl & 0x0FFF) + (val & 0x0FFF) > 0x0FFF;
        self.f.c = result > 0xFFFF;
        self.f.n = false;
        const res16: u16 = @truncate(result);
        self.setHL(res16);
        // X/Y from high byte of result
        self.f.x = res16 & 0x0800 != 0;
        self.f.y = res16 & 0x2000 != 0;
    }

    fn addIX(self: *CPU, idx: *u16, val: u16) void {
        const result = @as(u32, idx.*) + val;
        self.f.h = (idx.* & 0x0FFF) + (val & 0x0FFF) > 0x0FFF;
        self.f.c = result > 0xFFFF;
        self.f.n = false;
        const res16: u16 = @truncate(result);
        idx.* = res16;
        // X/Y from high byte of result
        self.f.x = res16 & 0x0800 != 0;
        self.f.y = res16 & 0x2000 != 0;
    }

    fn adcHL(self: *CPU, val: u16) void {
        const c: u16 = if (self.f.c) 1 else 0;
        const hl = self.getHL();
        const result = @as(u32, hl) + val + c;
        const res16: u16 = @truncate(result);
        self.f.s = res16 & 0x8000 != 0;
        self.f.z = res16 == 0;
        self.f.h = (hl & 0x0FFF) + (val & 0x0FFF) + c > 0x0FFF;
        self.f.pv = ((hl ^ val ^ 0x8000) & (hl ^ res16)) & 0x8000 != 0;
        self.f.n = false;
        self.f.c = result > 0xFFFF;
        self.setHL(res16);
        // X/Y from high byte of result
        self.f.x = res16 & 0x0800 != 0;
        self.f.y = res16 & 0x2000 != 0;
    }

    fn sbcHL(self: *CPU, val: u16) void {
        const c: u16 = if (self.f.c) 1 else 0;
        const hl = self.getHL();
        const result = @as(i32, hl) - val - c;
        const res16: u16 = @truncate(@as(u32, @bitCast(result)));
        self.f.s = res16 & 0x8000 != 0;
        self.f.z = res16 == 0;
        self.f.h = (hl & 0x0FFF) < (val & 0x0FFF) + c;
        self.f.pv = ((hl ^ val) & (hl ^ res16)) & 0x8000 != 0;
        self.f.n = true;
        self.f.c = result < 0;
        self.setHL(res16);
        // X/Y from high byte of result
        self.f.x = res16 & 0x0800 != 0;
        self.f.y = res16 & 0x2000 != 0;
    }

    // Rotates
    fn rlca(self: *CPU) void {
        const c = self.a >> 7;
        self.a = (self.a << 1) | c;
        self.f.c = c != 0;
        self.f.h = false;
        self.f.n = false;
        self.f.x = self.a & 0x08 != 0;
        self.f.y = self.a & 0x20 != 0;
    }

    fn rrca(self: *CPU) void {
        const c = self.a & 1;
        self.a = (self.a >> 1) | (c << 7);
        self.f.c = c != 0;
        self.f.h = false;
        self.f.n = false;
        self.f.x = self.a & 0x08 != 0;
        self.f.y = self.a & 0x20 != 0;
    }

    fn rla(self: *CPU) void {
        const c: u8 = if (self.f.c) 1 else 0;
        self.f.c = self.a & 0x80 != 0;
        self.a = (self.a << 1) | c;
        self.f.h = false;
        self.f.n = false;
        self.f.x = self.a & 0x08 != 0;
        self.f.y = self.a & 0x20 != 0;
    }

    fn rra(self: *CPU) void {
        const c: u8 = if (self.f.c) 0x80 else 0;
        self.f.c = self.a & 1 != 0;
        self.a = (self.a >> 1) | c;
        self.f.h = false;
        self.f.n = false;
        self.f.x = self.a & 0x08 != 0;
        self.f.y = self.a & 0x20 != 0;
    }

    fn rlc(self: *CPU, val: u8) u8 {
        const c = val >> 7;
        const result = (val << 1) | c;
        self.f.c = c != 0;
        self.f.s = result & 0x80 != 0;
        self.f.z = result == 0;
        self.f.h = false;
        self.f.pv = parity(result);
        self.f.n = false;
        self.f.x = result & 0x08 != 0;
        self.f.y = result & 0x20 != 0;
        return result;
    }

    fn rrc(self: *CPU, val: u8) u8 {
        const c = val & 1;
        const result = (val >> 1) | (c << 7);
        self.f.c = c != 0;
        self.f.s = result & 0x80 != 0;
        self.f.z = result == 0;
        self.f.h = false;
        self.f.pv = parity(result);
        self.f.n = false;
        self.f.x = result & 0x08 != 0;
        self.f.y = result & 0x20 != 0;
        return result;
    }

    fn rl(self: *CPU, val: u8) u8 {
        const c: u8 = if (self.f.c) 1 else 0;
        const result = (val << 1) | c;
        self.f.c = val & 0x80 != 0;
        self.f.s = result & 0x80 != 0;
        self.f.z = result == 0;
        self.f.h = false;
        self.f.pv = parity(result);
        self.f.n = false;
        self.f.x = result & 0x08 != 0;
        self.f.y = result & 0x20 != 0;
        return result;
    }

    fn rr(self: *CPU, val: u8) u8 {
        const c: u8 = if (self.f.c) 0x80 else 0;
        const result = (val >> 1) | c;
        self.f.c = val & 1 != 0;
        self.f.s = result & 0x80 != 0;
        self.f.z = result == 0;
        self.f.h = false;
        self.f.pv = parity(result);
        self.f.n = false;
        self.f.x = result & 0x08 != 0;
        self.f.y = result & 0x20 != 0;
        return result;
    }

    fn sla(self: *CPU, val: u8) u8 {
        self.f.c = val & 0x80 != 0;
        const result = val << 1;
        self.f.s = result & 0x80 != 0;
        self.f.z = result == 0;
        self.f.h = false;
        self.f.pv = parity(result);
        self.f.n = false;
        self.f.x = result & 0x08 != 0;
        self.f.y = result & 0x20 != 0;
        return result;
    }

    fn sra(self: *CPU, val: u8) u8 {
        self.f.c = val & 1 != 0;
        const result = (val >> 1) | (val & 0x80);
        self.f.s = result & 0x80 != 0;
        self.f.z = result == 0;
        self.f.h = false;
        self.f.pv = parity(result);
        self.f.n = false;
        self.f.x = result & 0x08 != 0;
        self.f.y = result & 0x20 != 0;
        return result;
    }

    fn sll(self: *CPU, val: u8) u8 {
        // Undocumented: like SLA but sets bit 0
        self.f.c = val & 0x80 != 0;
        const result = (val << 1) | 1;
        self.f.s = result & 0x80 != 0;
        self.f.z = result == 0;
        self.f.h = false;
        self.f.pv = parity(result);
        self.f.x = result & 0x08 != 0;
        self.f.y = result & 0x20 != 0;
        self.f.n = false;
        return result;
    }

    fn srl(self: *CPU, val: u8) u8 {
        self.f.c = val & 1 != 0;
        const result = val >> 1;
        self.f.s = false;
        self.f.z = result == 0;
        self.f.h = false;
        self.f.pv = parity(result);
        self.f.n = false;
        self.f.x = result & 0x08 != 0;
        self.f.y = result & 0x20 != 0;
        return result;
    }

    // Jumps and calls
    fn jr(self: *CPU, bus: anytype, cond: bool) void {
        const d: i8 = @bitCast(self.fetch(bus));
        if (cond) {
            self.pc = @bitCast(@as(i16, @intCast(self.pc)) +% d);
        }
    }

    fn jrCond(self: *CPU, bus: anytype, cond: bool) u8 {
        const d: i8 = @bitCast(self.fetch(bus));
        if (cond) {
            self.pc = @bitCast(@as(i16, @intCast(self.pc)) +% d);
            return 12;
        }
        return 7;
    }

    fn jpCond(self: *CPU, bus: anytype, cond: bool) u8 {
        const addr = self.fetch16(bus);
        if (cond) self.pc = addr;
        return 10;
    }

    fn callCond(self: *CPU, bus: anytype, cond: bool) u8 {
        const addr = self.fetch16(bus);
        if (cond) {
            self.push(bus, self.pc);
            self.pc = addr;
            return 17;
        }
        return 10;
    }

    fn retCond(self: *CPU, bus: anytype, cond: bool) u8 {
        if (cond) {
            self.pc = self.pop(bus);
            return 11;
        }
        return 5;
    }

    fn djnz(self: *CPU, bus: anytype) u8 {
        self.b -%= 1;
        const d: i8 = @bitCast(self.fetch(bus));
        if (self.b != 0) {
            self.pc = @bitCast(@as(i16, @intCast(self.pc)) +% d);
            return 13;
        }
        return 8;
    }

    // Exchange instructions
    fn exAF(self: *CPU) void {
        std.mem.swap(u8, &self.a, &self.a_);
        std.mem.swap(Flags, &self.f, &self.f_);
    }

    fn exx(self: *CPU) void {
        std.mem.swap(u8, &self.b, &self.b_);
        std.mem.swap(u8, &self.c, &self.c_);
        std.mem.swap(u8, &self.d, &self.d_);
        std.mem.swap(u8, &self.e, &self.e_);
        std.mem.swap(u8, &self.h, &self.h_);
        std.mem.swap(u8, &self.l, &self.l_);
    }

    // Block instructions
    fn ldi(self: *CPU, bus: anytype) u8 {
        const n = bus.read(self.getHL());
        bus.write(self.getDE(), n);
        self.setHL(self.getHL() +% 1);
        self.setDE(self.getDE() +% 1);
        self.setBC(self.getBC() -% 1);
        self.f.h = false;
        self.f.pv = self.getBC() != 0;
        self.f.n = false;
        // X = bit 3 of (A + n), Y = bit 1 of (A + n)
        const sum = self.a +% n;
        self.f.x = sum & 0x08 != 0;
        self.f.y = sum & 0x02 != 0;
        return 16;
    }

    fn ldd(self: *CPU, bus: anytype) u8 {
        const n = bus.read(self.getHL());
        bus.write(self.getDE(), n);
        self.setHL(self.getHL() -% 1);
        self.setDE(self.getDE() -% 1);
        self.setBC(self.getBC() -% 1);
        self.f.h = false;
        self.f.pv = self.getBC() != 0;
        self.f.n = false;
        // X = bit 3 of (A + n), Y = bit 1 of (A + n)
        const sum = self.a +% n;
        self.f.x = sum & 0x08 != 0;
        self.f.y = sum & 0x02 != 0;
        return 16;
    }

    fn ldir(self: *CPU, bus: anytype) u8 {
        _ = self.ldi(bus);
        if (self.getBC() != 0) {
            self.pc -%= 2;
            return 21;
        }
        return 16;
    }

    fn lddr(self: *CPU, bus: anytype) u8 {
        _ = self.ldd(bus);
        if (self.getBC() != 0) {
            self.pc -%= 2;
            return 21;
        }
        return 16;
    }

    fn cpi(self: *CPU, bus: anytype) u8 {
        const val = bus.read(self.getHL());
        const result = self.a -% val;
        self.setHL(self.getHL() +% 1);
        self.setBC(self.getBC() -% 1);
        self.f.s = result & 0x80 != 0;
        self.f.z = result == 0;
        self.f.h = (self.a & 0x0F) < (val & 0x0F);
        self.f.pv = self.getBC() != 0;
        self.f.n = true;
        // X = bit 3 of (A - (HL) - H), Y = bit 1 of (A - (HL) - H)
        const h_val: u8 = if (self.f.h) 1 else 0;
        const n = result -% h_val;
        self.f.x = n & 0x08 != 0;
        self.f.y = n & 0x02 != 0;
        return 16;
    }

    fn cpd(self: *CPU, bus: anytype) u8 {
        const val = bus.read(self.getHL());
        const result = self.a -% val;
        self.setHL(self.getHL() -% 1);
        self.setBC(self.getBC() -% 1);
        self.f.s = result & 0x80 != 0;
        self.f.z = result == 0;
        self.f.h = (self.a & 0x0F) < (val & 0x0F);
        self.f.pv = self.getBC() != 0;
        self.f.n = true;
        // X = bit 3 of (A - (HL) - H), Y = bit 1 of (A - (HL) - H)
        const h_val: u8 = if (self.f.h) 1 else 0;
        const n = result -% h_val;
        self.f.x = n & 0x08 != 0;
        self.f.y = n & 0x02 != 0;
        return 16;
    }

    fn cpir(self: *CPU, bus: anytype) u8 {
        _ = self.cpi(bus);
        if (self.getBC() != 0 and !self.f.z) {
            self.pc -%= 2;
            return 21;
        }
        return 16;
    }

    fn cpdr(self: *CPU, bus: anytype) u8 {
        _ = self.cpd(bus);
        if (self.getBC() != 0 and !self.f.z) {
            self.pc -%= 2;
            return 21;
        }
        return 16;
    }

    fn ini(self: *CPU, bus: anytype) u8 {
        bus.write(self.getHL(), bus.ioRead(self.c));
        self.setHL(self.getHL() +% 1);
        self.b -%= 1;
        self.f.z = self.b == 0;
        self.f.n = true;
        return 16;
    }

    fn ind(self: *CPU, bus: anytype) u8 {
        bus.write(self.getHL(), bus.ioRead(self.c));
        self.setHL(self.getHL() -% 1);
        self.b -%= 1;
        self.f.z = self.b == 0;
        self.f.n = true;
        return 16;
    }

    fn inir(self: *CPU, bus: anytype) u8 {
        _ = self.ini(bus);
        if (self.b != 0) {
            self.pc -%= 2;
            return 21;
        }
        return 16;
    }

    fn indr(self: *CPU, bus: anytype) u8 {
        _ = self.ind(bus);
        if (self.b != 0) {
            self.pc -%= 2;
            return 21;
        }
        return 16;
    }

    fn outi(self: *CPU, bus: anytype) u8 {
        bus.ioWrite(self.c, bus.read(self.getHL()));
        self.setHL(self.getHL() +% 1);
        self.b -%= 1;
        self.f.z = self.b == 0;
        self.f.n = true;
        return 16;
    }

    fn outd(self: *CPU, bus: anytype) u8 {
        bus.ioWrite(self.c, bus.read(self.getHL()));
        self.setHL(self.getHL() -% 1);
        self.b -%= 1;
        self.f.z = self.b == 0;
        self.f.n = true;
        return 16;
    }

    fn otir(self: *CPU, bus: anytype) u8 {
        _ = self.outi(bus);
        if (self.b != 0) {
            self.pc -%= 2;
            return 21;
        }
        return 16;
    }

    fn otdr(self: *CPU, bus: anytype) u8 {
        _ = self.outd(bus);
        if (self.b != 0) {
            self.pc -%= 2;
            return 21;
        }
        return 16;
    }

    fn inReg(self: *CPU, bus: anytype) u8 {
        const val = bus.ioRead(self.c);
        self.f.s = val & 0x80 != 0;
        self.f.z = val == 0;
        self.f.h = false;
        self.f.pv = parity(val);
        self.f.n = false;
        self.f.x = val & 0x08 != 0;
        self.f.y = val & 0x20 != 0;
        return val;
    }

    fn daa(self: *CPU) void {
        // DAA implementation based on ZEXALL-compatible behavior
        var correction: u8 = 0;
        var set_carry = false;

        if (self.f.h or (self.a & 0x0F) > 9) {
            correction |= 0x06;
        }
        if (self.f.c or self.a > 0x99) {
            correction |= 0x60;
            set_carry = true;
        }

        const old_a = self.a;
        if (self.f.n) {
            self.a -%= correction;
        } else {
            self.a +%= correction;
        }

        self.f.c = set_carry;
        self.f.s = self.a & 0x80 != 0;
        self.f.z = self.a == 0;
        // H flag: set if there was half-borrow/carry in low nibble correction
        if (self.f.n) {
            self.f.h = self.f.h and ((old_a & 0x0F) < (correction & 0x0F));
        } else {
            self.f.h = (old_a & 0x0F) > 9;
        }
        self.f.pv = parity(self.a);
        self.f.x = self.a & 0x08 != 0;
        self.f.y = self.a & 0x20 != 0;
    }
};

fn parity(val: u8) bool {
    var v = val;
    v ^= v >> 4;
    v ^= v >> 2;
    v ^= v >> 1;
    return v & 1 == 0;
}
