//! NES APU (2A03)
//! Audio Processing Unit - 5 channels.

const std = @import("std");

pub const APU = struct {
    // Channels
    pulse1: Pulse = .{ .channel = 0 },
    pulse2: Pulse = .{ .channel = 1 },
    triangle: Triangle = .{},
    noise: Noise = .{},
    dmc: DMC = .{},

    // Frame counter
    frame_counter: u8 = 0,
    frame_step: u8 = 0,
    frame_irq: bool = false,
    irq_inhibit: bool = false,

    // Status
    status: u8 = 0,

    // Output
    sample_buffer: [4096]i16 = [_]i16{0} ** 4096,
    sample_write_idx: usize = 0,
    sample_read_idx: usize = 0,
    cycle_counter: u32 = 0,
    half_cycle: bool = false,

    const SAMPLE_RATE = 44100;
    const CPU_FREQ = 1789773;
    const CYCLES_PER_SAMPLE = CPU_FREQ / SAMPLE_RATE;

    pub fn tick(self: *APU, cycles: u8) void {
        for (0..cycles) |_| {
            self.tickChannel();
        }
    }

    fn tickChannel(self: *APU) void {
        // Triangle ticks every CPU cycle
        self.triangle.tickTimer();

        // Pulse and noise tick every OTHER cycle (half CPU rate)
        self.half_cycle = !self.half_cycle;
        if (self.half_cycle) {
            self.pulse1.tickTimer();
            self.pulse2.tickTimer();
            self.noise.tickTimer();
        }

        // Sample output
        self.cycle_counter += 1;
        if (self.cycle_counter >= CYCLES_PER_SAMPLE) {
            self.cycle_counter -= CYCLES_PER_SAMPLE;
            self.outputSample();
        }
    }

    fn outputSample(self: *APU) void {
        const p1: f32 = @floatFromInt(self.pulse1.output());
        const p2: f32 = @floatFromInt(self.pulse2.output());
        const tri: f32 = @floatFromInt(self.triangle.output());
        const noise: f32 = @floatFromInt(self.noise.output());
        const dmc: f32 = @floatFromInt(self.dmc.output);

        // Mix using NES nonlinear mixing (formulas from nesdev wiki)
        const pulse_out: f32 = if (p1 + p2 > 0) 95.88 / (8128.0 / (p1 + p2) + 100.0) else 0;
        const tnd_out: f32 = if (tri + noise + dmc > 0) 159.79 / (1.0 / (tri / 8227.0 + noise / 12241.0 + dmc / 22638.0) + 100.0) else 0;

        // Scale to full 16-bit range with volume boost
        const sample: i16 = @intFromFloat(std.math.clamp((pulse_out + tnd_out) * 49152.0, -32768.0, 32767.0));

        // Output stereo (same on both channels)
        if (self.sample_write_idx + 1 < self.sample_buffer.len) {
            self.sample_buffer[self.sample_write_idx] = sample; // Left
            self.sample_buffer[self.sample_write_idx + 1] = sample; // Right
            self.sample_write_idx = (self.sample_write_idx + 2) % self.sample_buffer.len;
        }
    }

    pub fn tickFrameCounter(self: *APU) void {
        const mode5 = self.frame_counter & 0x80 != 0;

        if (mode5) {
            // 5-step sequence
            switch (self.frame_step) {
                0, 2 => self.tickEnvelopesAndTriangle(),
                1, 3 => {
                    self.tickEnvelopesAndTriangle();
                    self.tickLengthAndSweep();
                },
                else => {},
            }
            self.frame_step = (self.frame_step + 1) % 5;
        } else {
            // 4-step sequence
            switch (self.frame_step) {
                0, 2 => self.tickEnvelopesAndTriangle(),
                1, 3 => {
                    self.tickEnvelopesAndTriangle();
                    self.tickLengthAndSweep();
                    if (self.frame_step == 3 and !self.irq_inhibit) {
                        self.frame_irq = true;
                    }
                },
                else => {},
            }
            self.frame_step = (self.frame_step + 1) % 4;
        }
    }

    fn tickEnvelopesAndTriangle(self: *APU) void {
        self.pulse1.tickEnvelope();
        self.pulse2.tickEnvelope();
        self.triangle.tickLinearCounter();
        self.noise.tickEnvelope();
    }

    fn tickLengthAndSweep(self: *APU) void {
        self.pulse1.tickLength();
        self.pulse1.tickSweep();
        self.pulse2.tickLength();
        self.pulse2.tickSweep();
        self.triangle.tickLength();
        self.noise.tickLength();
    }

    pub fn readStatus(self: *APU) u8 {
        var status: u8 = 0;
        if (self.pulse1.length_counter > 0) status |= 0x01;
        if (self.pulse2.length_counter > 0) status |= 0x02;
        if (self.triangle.length_counter > 0) status |= 0x04;
        if (self.noise.length_counter > 0) status |= 0x08;
        if (self.dmc.bytes_remaining > 0) status |= 0x10;
        if (self.frame_irq) status |= 0x40;
        if (self.dmc.irq_flag) status |= 0x80;
        self.frame_irq = false;
        return status;
    }

    pub fn writeStatus(self: *APU, val: u8) void {
        self.pulse1.enabled = val & 0x01 != 0;
        self.pulse2.enabled = val & 0x02 != 0;
        self.triangle.enabled = val & 0x04 != 0;
        self.noise.enabled = val & 0x08 != 0;
        self.dmc.enabled = val & 0x10 != 0;

        if (!self.pulse1.enabled) self.pulse1.length_counter = 0;
        if (!self.pulse2.enabled) self.pulse2.length_counter = 0;
        if (!self.triangle.enabled) self.triangle.length_counter = 0;
        if (!self.noise.enabled) self.noise.length_counter = 0;
        if (!self.dmc.enabled) self.dmc.bytes_remaining = 0;

        self.dmc.irq_flag = false;
    }

    pub fn writeFrameCounter(self: *APU, val: u8) void {
        self.frame_counter = val;
        self.irq_inhibit = val & 0x40 != 0;
        if (self.irq_inhibit) self.frame_irq = false;
        if (val & 0x80 != 0) {
            self.tickEnvelopesAndTriangle();
            self.tickLengthAndSweep();
        }
    }

    pub fn writeRegister(self: *APU, addr: u16, val: u8) void {
        switch (addr) {
            0x4000 => self.pulse1.writeControl(val),
            0x4001 => self.pulse1.writeSweep(val),
            0x4002 => self.pulse1.writeTimerLo(val),
            0x4003 => self.pulse1.writeTimerHi(val),
            0x4004 => self.pulse2.writeControl(val),
            0x4005 => self.pulse2.writeSweep(val),
            0x4006 => self.pulse2.writeTimerLo(val),
            0x4007 => self.pulse2.writeTimerHi(val),
            0x4008 => self.triangle.writeControl(val),
            0x400A => self.triangle.writeTimerLo(val),
            0x400B => self.triangle.writeTimerHi(val),
            0x400C => self.noise.writeControl(val),
            0x400E => self.noise.writePeriod(val),
            0x400F => self.noise.writeLength(val),
            0x4010 => self.dmc.writeControl(val),
            0x4011 => self.dmc.writeDirectLoad(val),
            0x4012 => self.dmc.writeSampleAddr(val),
            0x4013 => self.dmc.writeSampleLen(val),
            else => {},
        }
    }

    pub fn readSamples(self: *APU, out: []i16) usize {
        var count: usize = 0;
        while (count < out.len and self.sample_read_idx != self.sample_write_idx) {
            out[count] = self.sample_buffer[self.sample_read_idx];
            self.sample_read_idx = (self.sample_read_idx + 1) % self.sample_buffer.len;
            count += 1;
        }
        return count;
    }
};

const LENGTH_TABLE = [32]u8{
    10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14,
    12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30,
};

const Pulse = struct {
    channel: u1 = 0,
    enabled: bool = false,

    duty: u2 = 0,
    length_halt: bool = false,
    constant_volume: bool = false,
    volume: u4 = 0,

    sweep_enabled: bool = false,
    sweep_period: u3 = 0,
    sweep_negate: bool = false,
    sweep_shift: u3 = 0,
    sweep_reload: bool = false,
    sweep_counter: u8 = 0,

    timer: u16 = 0,
    timer_period: u11 = 0,
    sequence_pos: u3 = 0,
    length_counter: u8 = 0,

    envelope_start: bool = false,
    envelope_counter: u8 = 0,
    envelope_decay: u4 = 0,

    const DUTY_TABLE = [4][8]u8{
        .{ 0, 1, 0, 0, 0, 0, 0, 0 },
        .{ 0, 1, 1, 0, 0, 0, 0, 0 },
        .{ 0, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 0, 0, 1, 1, 1, 1, 1 },
    };

    fn output(self: *Pulse) u8 {
        if (!self.enabled or self.length_counter == 0) return 0;
        if (self.timer_period < 8) return 0;
        if (DUTY_TABLE[self.duty][self.sequence_pos] == 0) return 0;
        return if (self.constant_volume) self.volume else self.envelope_decay;
    }

    fn tickTimer(self: *Pulse) void {
        if (self.timer == 0) {
            self.timer = self.timer_period;
            self.sequence_pos -%= 1;
        } else {
            self.timer -= 1;
        }
    }

    fn tickLength(self: *Pulse) void {
        if (!self.length_halt and self.length_counter > 0) {
            self.length_counter -= 1;
        }
    }

    fn tickEnvelope(self: *Pulse) void {
        if (self.envelope_start) {
            self.envelope_start = false;
            self.envelope_decay = 15;
            self.envelope_counter = self.volume;
        } else if (self.envelope_counter > 0) {
            self.envelope_counter -= 1;
        } else {
            self.envelope_counter = self.volume;
            if (self.envelope_decay > 0) {
                self.envelope_decay -= 1;
            } else if (self.length_halt) {
                self.envelope_decay = 15;
            }
        }
    }

    fn tickSweep(self: *Pulse) void {
        if (self.sweep_reload) {
            self.sweep_counter = self.sweep_period;
            self.sweep_reload = false;
        } else if (self.sweep_counter > 0) {
            self.sweep_counter -= 1;
        } else {
            self.sweep_counter = self.sweep_period;
            if (self.sweep_enabled and self.sweep_shift > 0) {
                const delta = self.timer_period >> self.sweep_shift;
                if (self.sweep_negate) {
                    self.timer_period -|= delta;
                    if (self.channel == 0) self.timer_period -|= 1;
                } else {
                    self.timer_period +|= delta;
                }
            }
        }
    }

    fn writeControl(self: *Pulse, val: u8) void {
        self.duty = @truncate(val >> 6);
        self.length_halt = val & 0x20 != 0;
        self.constant_volume = val & 0x10 != 0;
        self.volume = @truncate(val);
    }

    fn writeSweep(self: *Pulse, val: u8) void {
        self.sweep_enabled = val & 0x80 != 0;
        self.sweep_period = @truncate(val >> 4);
        self.sweep_negate = val & 0x08 != 0;
        self.sweep_shift = @truncate(val);
        self.sweep_reload = true;
    }

    fn writeTimerLo(self: *Pulse, val: u8) void {
        self.timer_period = (self.timer_period & 0x700) | val;
    }

    fn writeTimerHi(self: *Pulse, val: u8) void {
        self.timer_period = (self.timer_period & 0x0FF) | (@as(u11, val & 7) << 8);
        if (self.enabled) {
            self.length_counter = LENGTH_TABLE[val >> 3];
        }
        self.sequence_pos = 0;
        self.envelope_start = true;
    }
};

const Triangle = struct {
    enabled: bool = false,
    control: bool = false,
    linear_load: u7 = 0,
    linear_counter: u8 = 0,
    linear_reload: bool = false,
    timer: u16 = 0,
    timer_period: u11 = 0,
    sequence_pos: u5 = 0,
    length_counter: u8 = 0,

    const SEQUENCE = [32]u8{
        15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    };

    fn output(self: *Triangle) u8 {
        if (!self.enabled or self.length_counter == 0 or self.linear_counter == 0) return 0;
        return SEQUENCE[self.sequence_pos];
    }

    fn tickTimer(self: *Triangle) void {
        if (self.timer == 0) {
            self.timer = self.timer_period;
            if (self.length_counter > 0 and self.linear_counter > 0) {
                self.sequence_pos +%= 1;
            }
        } else {
            self.timer -= 1;
        }
    }

    fn tickLength(self: *Triangle) void {
        if (!self.control and self.length_counter > 0) {
            self.length_counter -= 1;
        }
    }

    fn tickLinearCounter(self: *Triangle) void {
        if (self.linear_reload) {
            self.linear_counter = self.linear_load;
        } else if (self.linear_counter > 0) {
            self.linear_counter -= 1;
        }
        if (!self.control) {
            self.linear_reload = false;
        }
    }

    fn writeControl(self: *Triangle, val: u8) void {
        self.control = val & 0x80 != 0;
        self.linear_load = @truncate(val);
    }

    fn writeTimerLo(self: *Triangle, val: u8) void {
        self.timer_period = (self.timer_period & 0x700) | val;
    }

    fn writeTimerHi(self: *Triangle, val: u8) void {
        self.timer_period = (self.timer_period & 0x0FF) | (@as(u11, val & 7) << 8);
        if (self.enabled) {
            self.length_counter = LENGTH_TABLE[val >> 3];
        }
        self.linear_reload = true;
    }
};

const Noise = struct {
    enabled: bool = false,
    length_halt: bool = false,
    constant_volume: bool = false,
    volume: u4 = 0,
    mode: bool = false,
    period: u4 = 0,
    timer: u16 = 0,
    shift: u15 = 1,
    length_counter: u8 = 0,
    envelope_start: bool = false,
    envelope_counter: u8 = 0,
    envelope_decay: u4 = 0,

    const PERIOD_TABLE = [16]u16{
        4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068,
    };

    fn output(self: *Noise) u8 {
        if (!self.enabled or self.length_counter == 0 or self.shift & 1 != 0) return 0;
        return if (self.constant_volume) self.volume else self.envelope_decay;
    }

    fn tickTimer(self: *Noise) void {
        if (self.timer == 0) {
            self.timer = PERIOD_TABLE[self.period];
            const bit = if (self.mode) @as(u4, 6) else 1;
            const feedback = (self.shift & 1) ^ ((self.shift >> bit) & 1);
            self.shift = (self.shift >> 1) | (@as(u15, @truncate(feedback)) << 14);
        } else {
            self.timer -= 1;
        }
    }

    fn tickLength(self: *Noise) void {
        if (!self.length_halt and self.length_counter > 0) {
            self.length_counter -= 1;
        }
    }

    fn tickEnvelope(self: *Noise) void {
        if (self.envelope_start) {
            self.envelope_start = false;
            self.envelope_decay = 15;
            self.envelope_counter = self.volume;
        } else if (self.envelope_counter > 0) {
            self.envelope_counter -= 1;
        } else {
            self.envelope_counter = self.volume;
            if (self.envelope_decay > 0) {
                self.envelope_decay -= 1;
            } else if (self.length_halt) {
                self.envelope_decay = 15;
            }
        }
    }

    fn writeControl(self: *Noise, val: u8) void {
        self.length_halt = val & 0x20 != 0;
        self.constant_volume = val & 0x10 != 0;
        self.volume = @truncate(val);
    }

    fn writePeriod(self: *Noise, val: u8) void {
        self.mode = val & 0x80 != 0;
        self.period = @truncate(val);
    }

    fn writeLength(self: *Noise, val: u8) void {
        if (self.enabled) {
            self.length_counter = LENGTH_TABLE[val >> 3];
        }
        self.envelope_start = true;
    }
};

const DMC = struct {
    enabled: bool = false,
    irq_enabled: bool = false,
    loop: bool = false,
    rate: u4 = 0,
    output: u8 = 0,
    sample_addr: u16 = 0xC000,
    sample_len: u16 = 0,
    current_addr: u16 = 0,
    bytes_remaining: u16 = 0,
    irq_flag: bool = false,

    fn writeControl(self: *DMC, val: u8) void {
        self.irq_enabled = val & 0x80 != 0;
        self.loop = val & 0x40 != 0;
        self.rate = @truncate(val);
        if (!self.irq_enabled) self.irq_flag = false;
    }

    fn writeDirectLoad(self: *DMC, val: u8) void {
        self.output = val & 0x7F;
    }

    fn writeSampleAddr(self: *DMC, val: u8) void {
        self.sample_addr = 0xC000 | (@as(u16, val) << 6);
    }

    fn writeSampleLen(self: *DMC, val: u8) void {
        self.sample_len = (@as(u16, val) << 4) | 1;
    }
};
