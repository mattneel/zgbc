//! SMS System
//! Top-level Sega Master System emulator state.

const CPU = @import("cpu.zig").CPU;
const Bus = @import("bus.zig").Bus;
const VDP = @import("vdp.zig").VDP;
const PSG = @import("psg.zig").PSG;

pub const SCREEN_WIDTH = 256;
pub const SCREEN_HEIGHT = 192; // Can be 224 in extended mode

/// Save state structure
pub const SaveState = extern struct {
    cpu: extern struct {
        a: u8,
        f: u8,
        b: u8,
        c: u8,
        d: u8,
        e: u8,
        h: u8,
        l: u8,
        a_: u8,
        f_: u8,
        b_: u8,
        c_: u8,
        d_: u8,
        e_: u8,
        h_: u8,
        l_: u8,
        ix: u16,
        iy: u16,
        sp: u16,
        pc: u16,
        i: u8,
        r: u8,
        iff1: u8,
        iff2: u8,
        im: u8,
        _pad: u8 = 0,
    },
    vdp: extern struct {
        regs: [11]u8,
        addr: u16,
        code: u8,
        read_buffer: u8,
        latch: u8,
        latch_byte: u8,
        status: u8,
        line_counter: u8,
        v_counter: u8,
        _pad: u8 = 0,
    },
    ram: [8192]u8,
    vram: [16384]u8,
    cram: [32]u8,
    mapper: [4]u8,
};

pub const SMS = struct {
    cpu: CPU = .{},
    bus: Bus = .{},
    vdp: VDP = .{},
    psg: PSG = .{},

    cycles: u64 = 0,

    // Feature flags
    render_graphics: bool = true,
    render_audio: bool = true,

    /// Initialize and wire components
    pub fn init(self: *SMS) void {
        self.bus.vdp = &self.vdp;
        self.bus.psg = &self.psg;
    }

    /// Load ROM
    pub fn loadRom(self: *SMS, data: []const u8) void {
        self.init();
        self.bus.loadRom(data);
        self.cpu = .{};
        self.vdp = .{};
        self.psg = .{};
        self.bus.vdp = &self.vdp;
        self.bus.psg = &self.psg;
    }

    /// Execute one instruction
    pub fn step(self: *SMS) u8 {
        // Wire components if needed
        if (@intFromPtr(self.bus.vdp) != @intFromPtr(&self.vdp)) {
            self.init();
        }

        // Check VDP interrupt (level-triggered)
        self.cpu.irq_pending = self.vdp.irq_pending;

        const cpu_cycles = self.cpu.step(&self.bus);

        // VDP runs at same clock as CPU
        self.vdp.tick(cpu_cycles);

        // PSG
        if (self.render_audio) {
            self.psg.tick(cpu_cycles);
        }

        self.cycles += cpu_cycles;
        return cpu_cycles;
    }

    /// Execute one frame
    pub fn frame(self: *SMS) void {
        const start_frame = self.vdp.frame;
        while (self.vdp.frame == start_frame) {
            _ = self.step();
        }
    }

    /// Set controller input
    pub fn setInput(self: *SMS, buttons: u8) void {
        // Input format: Up=0, Down=1, Left=2, Right=3, B1=4, B2=5 (active high)
        // SMS joypad is active low
        self.bus.joypad1 = ~buttons;
    }

    /// Get RAM for observations
    pub fn getRam(self: *SMS) []const u8 {
        return &self.bus.ram;
    }

    /// Get frame buffer
    pub fn getFrameBuffer(self: *SMS) *const [SCREEN_WIDTH * SCREEN_HEIGHT]u32 {
        // Return first 192 lines for standard mode
        return @ptrCast(&self.vdp.frame_buffer);
    }

    /// Get extended frame buffer (for 224-line mode)
    pub fn getExtendedFrameBuffer(self: *SMS) *const [SCREEN_WIDTH * 224]u32 {
        return @ptrCast(&self.vdp.frame_buffer);
    }

    /// Get current screen height
    pub fn getScreenHeight(self: *SMS) u16 {
        return self.vdp.screen_height;
    }

    /// Read memory
    pub fn read(self: *SMS, addr: u16) u8 {
        return self.bus.read(addr);
    }

    /// Write memory
    pub fn write(self: *SMS, addr: u16, val: u8) void {
        self.bus.write(addr, val);
    }

    /// Get audio samples
    pub fn getAudioSamples(self: *SMS, out: []i16) usize {
        return self.psg.readSamples(out);
    }

    /// Get save data (cart RAM)
    pub fn getSaveData(self: *SMS) []const u8 {
        return &self.bus.cart_ram;
    }

    /// Load save data
    pub fn loadSaveData(self: *SMS, data: []const u8) void {
        const len = @min(data.len, self.bus.cart_ram.len);
        @memcpy(self.bus.cart_ram[0..len], data[0..len]);
    }

    /// Save state
    pub fn saveState(self: *SMS) SaveState {
        return SaveState{
            .cpu = .{
                .a = self.cpu.a,
                .f = @bitCast(self.cpu.f),
                .b = self.cpu.b,
                .c = self.cpu.c,
                .d = self.cpu.d,
                .e = self.cpu.e,
                .h = self.cpu.h,
                .l = self.cpu.l,
                .a_ = self.cpu.a_,
                .f_ = @bitCast(self.cpu.f_),
                .b_ = self.cpu.b_,
                .c_ = self.cpu.c_,
                .d_ = self.cpu.d_,
                .e_ = self.cpu.e_,
                .h_ = self.cpu.h_,
                .l_ = self.cpu.l_,
                .ix = self.cpu.ix,
                .iy = self.cpu.iy,
                .sp = self.cpu.sp,
                .pc = self.cpu.pc,
                .i = self.cpu.i,
                .r = self.cpu.r,
                .iff1 = @intFromBool(self.cpu.iff1),
                .iff2 = @intFromBool(self.cpu.iff2),
                .im = self.cpu.im,
            },
            .vdp = .{
                .regs = self.vdp.regs,
                .addr = self.vdp.addr,
                .code = self.vdp.code,
                .read_buffer = self.vdp.read_buffer,
                .latch = @intFromBool(self.vdp.latch),
                .latch_byte = self.vdp.latch_byte,
                .status = self.vdp.status,
                .line_counter = self.vdp.line_counter,
                .v_counter = self.vdp.v_counter,
            },
            .ram = self.bus.ram,
            .vram = self.vdp.vram,
            .cram = self.vdp.cram,
            .mapper = self.bus.mapper,
        };
    }

    /// Load state
    pub fn loadState(self: *SMS, state: SaveState) void {
        self.cpu.a = state.cpu.a;
        self.cpu.f = @bitCast(state.cpu.f);
        self.cpu.b = state.cpu.b;
        self.cpu.c = state.cpu.c;
        self.cpu.d = state.cpu.d;
        self.cpu.e = state.cpu.e;
        self.cpu.h = state.cpu.h;
        self.cpu.l = state.cpu.l;
        self.cpu.a_ = state.cpu.a_;
        self.cpu.f_ = @bitCast(state.cpu.f_);
        self.cpu.b_ = state.cpu.b_;
        self.cpu.c_ = state.cpu.c_;
        self.cpu.d_ = state.cpu.d_;
        self.cpu.e_ = state.cpu.e_;
        self.cpu.h_ = state.cpu.h_;
        self.cpu.l_ = state.cpu.l_;
        self.cpu.ix = state.cpu.ix;
        self.cpu.iy = state.cpu.iy;
        self.cpu.sp = state.cpu.sp;
        self.cpu.pc = state.cpu.pc;
        self.cpu.i = state.cpu.i;
        self.cpu.r = state.cpu.r;
        self.cpu.iff1 = state.cpu.iff1 != 0;
        self.cpu.iff2 = state.cpu.iff2 != 0;
        self.cpu.im = @truncate(state.cpu.im);

        self.vdp.regs = state.vdp.regs;
        self.vdp.addr = @truncate(state.vdp.addr);
        self.vdp.code = @truncate(state.vdp.code);
        self.vdp.read_buffer = state.vdp.read_buffer;
        self.vdp.latch = state.vdp.latch != 0;
        self.vdp.latch_byte = state.vdp.latch_byte;
        self.vdp.status = state.vdp.status;
        self.vdp.line_counter = state.vdp.line_counter;
        self.vdp.v_counter = state.vdp.v_counter;

        self.bus.ram = state.ram;
        self.vdp.vram = state.vram;
        self.vdp.cram = state.cram;
        self.bus.mapper = state.mapper;
    }
};
