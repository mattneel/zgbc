//! APU (Audio Processing Unit)
//! Generates Game Boy audio: 2 pulse channels, 1 wave channel, 1 noise channel.

const std = @import("std");

pub const APU = struct {
    // Channels
    ch1: PulseChannel = .{ .has_sweep = true },
    ch2: PulseChannel = .{ .has_sweep = false },
    ch3: WaveChannel = .{},
    ch4: NoiseChannel = .{},

    // Control registers
    nr50: u8 = 0, // Volume
    nr51: u8 = 0, // Panning
    nr52: u8 = 0, // Master enable

    // Wave RAM (FF30-FF3F)
    wave_ram: [16]u8 = [_]u8{0} ** 16,

    // Frame sequencer (512 Hz = every 8192 cycles)
    frame_seq_counter: u16 = 0,
    frame_seq_step: u3 = 0,

    // Sample buffer (ring buffer for audio output)
    sample_buffer: [4096]i16 = [_]i16{0} ** 4096,
    sample_write_idx: usize = 0,
    sample_read_idx: usize = 0,

    // Sample timing (44100 Hz output)
    sample_counter: u32 = 0,

    const SAMPLE_RATE = 44100;
    const CPU_FREQ = 4_194_304;
    const CYCLES_PER_SAMPLE = CPU_FREQ / SAMPLE_RATE; // ~95

    pub fn tick(self: *APU, cycles: u8) void {
        if (self.nr52 & 0x80 == 0) return; // APU disabled

        var remaining: u8 = cycles;
        while (remaining > 0) : (remaining -= 1) {
            // Tick channels
            self.ch1.tickFrequency();
            self.ch2.tickFrequency();
            self.ch3.tickFrequency();
            self.ch4.tickFrequency();

            // Frame sequencer (512 Hz)
            self.frame_seq_counter += 1;
            if (self.frame_seq_counter >= 8192) {
                self.frame_seq_counter = 0;
                self.tickFrameSequencer();
            }

            // Generate sample at 44100 Hz
            self.sample_counter += 1;
            if (self.sample_counter >= CYCLES_PER_SAMPLE) {
                self.sample_counter = 0;
                self.generateSample();
            }
        }
    }

    fn tickFrameSequencer(self: *APU) void {
        switch (self.frame_seq_step) {
            0, 4 => {
                self.ch1.tickLength();
                self.ch2.tickLength();
                self.ch3.tickLength();
                self.ch4.tickLength();
            },
            2, 6 => {
                self.ch1.tickLength();
                self.ch2.tickLength();
                self.ch3.tickLength();
                self.ch4.tickLength();
                self.ch1.tickSweep();
            },
            7 => {
                self.ch1.tickEnvelope();
                self.ch2.tickEnvelope();
                self.ch4.tickEnvelope();
            },
            else => {},
        }
        self.frame_seq_step +%= 1;
    }

    fn generateSample(self: *APU) void {
        // Channel outputs are -15 to +15 range
        const ch1_out: i32 = self.ch1.output();
        const ch2_out: i32 = self.ch2.output();
        const ch3_out: i32 = self.ch3.output(&self.wave_ram);
        const ch4_out: i32 = self.ch4.output();

        var left: i32 = 0;
        var right: i32 = 0;

        // Panning (NR51)
        if (self.nr51 & 0x10 != 0) left += ch1_out;
        if (self.nr51 & 0x01 != 0) right += ch1_out;
        if (self.nr51 & 0x20 != 0) left += ch2_out;
        if (self.nr51 & 0x02 != 0) right += ch2_out;
        if (self.nr51 & 0x40 != 0) left += ch3_out;
        if (self.nr51 & 0x04 != 0) right += ch3_out;
        if (self.nr51 & 0x80 != 0) left += ch4_out;
        if (self.nr51 & 0x08 != 0) right += ch4_out;

        // Master volume (NR50) - range 0-7, we use vol+1 = 1-8
        const left_vol: i32 = ((self.nr50 >> 4) & 0x07) + 1;
        const right_vol: i32 = (self.nr50 & 0x07) + 1;

        // Scale: channels sum to max ±60, * 8 = ±480, * 64 = ±30720 (fits i16)
        left = (left * left_vol * 64);
        right = (right * right_vol * 64);

        // Interleaved stereo
        self.sample_buffer[self.sample_write_idx] = @intCast(std.math.clamp(left, -32767, 32767));
        self.sample_write_idx = (self.sample_write_idx + 1) % self.sample_buffer.len;
        self.sample_buffer[self.sample_write_idx] = @intCast(std.math.clamp(right, -32767, 32767));
        self.sample_write_idx = (self.sample_write_idx + 1) % self.sample_buffer.len;
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

    pub fn writeRegister(self: *APU, addr: u16, val: u8) void {
        switch (addr) {
            0xFF10 => self.ch1.nr0 = val,
            0xFF11 => self.ch1.writeNR1(val),
            0xFF12 => self.ch1.nr2 = val,
            0xFF13 => self.ch1.nr3 = val,
            0xFF14 => self.ch1.writeNR4(val),

            0xFF16 => self.ch2.writeNR1(val),
            0xFF17 => self.ch2.nr2 = val,
            0xFF18 => self.ch2.nr3 = val,
            0xFF19 => self.ch2.writeNR4(val),

            0xFF1A => self.ch3.nr0 = val,
            0xFF1B => self.ch3.length = 256 -% @as(u16, val),
            0xFF1C => self.ch3.nr2 = val,
            0xFF1D => self.ch3.nr3 = val,
            0xFF1E => self.ch3.writeNR4(val),

            0xFF20 => self.ch4.length = 64 -% (val & 0x3F),
            0xFF21 => self.ch4.nr2 = val,
            0xFF22 => self.ch4.nr3 = val,
            0xFF23 => self.ch4.writeNR4(val),

            0xFF24 => self.nr50 = val,
            0xFF25 => self.nr51 = val,
            0xFF26 => {
                const was_enabled = self.nr52 & 0x80 != 0;
                self.nr52 = (self.nr52 & 0x0F) | (val & 0x80);
                // Clear all registers when APU is disabled
                if (was_enabled and self.nr52 & 0x80 == 0) {
                    self.ch1 = .{ .has_sweep = true };
                    self.ch2 = .{ .has_sweep = false };
                    self.ch3 = .{};
                    self.ch4 = .{};
                    self.nr50 = 0;
                    self.nr51 = 0;
                }
            },

            0xFF30...0xFF3F => self.wave_ram[addr - 0xFF30] = val,
            else => {},
        }
    }

    pub fn readRegister(self: *APU, addr: u16) u8 {
        return switch (addr) {
            0xFF10 => self.ch1.nr0 | 0x80,
            0xFF11 => self.ch1.nr1 | 0x3F,
            0xFF12 => self.ch1.nr2,
            0xFF13 => 0xFF,
            0xFF14 => self.ch1.nr4 | 0xBF,

            0xFF16 => self.ch2.nr1 | 0x3F,
            0xFF17 => self.ch2.nr2,
            0xFF18 => 0xFF,
            0xFF19 => self.ch2.nr4 | 0xBF,

            0xFF1A => self.ch3.nr0 | 0x7F,
            0xFF1B => 0xFF,
            0xFF1C => self.ch3.nr2 | 0x9F,
            0xFF1D => 0xFF,
            0xFF1E => self.ch3.nr4 | 0xBF,

            0xFF20 => 0xFF,
            0xFF21 => self.ch4.nr2,
            0xFF22 => self.ch4.nr3,
            0xFF23 => self.ch4.nr4 | 0xBF,

            0xFF24 => self.nr50,
            0xFF25 => self.nr51,
            0xFF26 => {
                var status: u8 = self.nr52 | 0x70;
                if (self.ch1.enabled) status |= 0x01;
                if (self.ch2.enabled) status |= 0x02;
                if (self.ch3.enabled) status |= 0x04;
                if (self.ch4.enabled) status |= 0x08;
                return status;
            },

            0xFF30...0xFF3F => self.wave_ram[addr - 0xFF30],
            else => 0xFF,
        };
    }
};

pub const PulseChannel = struct {
    has_sweep: bool = false,
    enabled: bool = false,

    nr0: u8 = 0, // Sweep (ch1 only)
    nr1: u8 = 0, // Duty/length
    nr2: u8 = 0, // Envelope
    nr3: u8 = 0, // Freq low
    nr4: u8 = 0, // Freq high + trigger

    length: u8 = 0,
    volume: u8 = 0,
    frequency: u16 = 0,
    freq_timer: u16 = 0,
    duty_pos: u3 = 0,

    envelope_timer: u8 = 0,
    sweep_timer: u8 = 0,
    sweep_enabled: bool = false,
    shadow_freq: u16 = 0,

    const DUTY_TABLE = [4][8]u1{
        .{ 0, 0, 0, 0, 0, 0, 0, 1 }, // 12.5%
        .{ 1, 0, 0, 0, 0, 0, 0, 1 }, // 25%
        .{ 1, 0, 0, 0, 0, 1, 1, 1 }, // 50%
        .{ 0, 1, 1, 1, 1, 1, 1, 0 }, // 75%
    };

    pub fn writeNR1(self: *PulseChannel, val: u8) void {
        self.nr1 = val;
        self.length = 64 -% (val & 0x3F);
    }

    pub fn writeNR4(self: *PulseChannel, val: u8) void {
        self.nr4 = val;
        if (val & 0x80 != 0) self.trigger();
    }

    fn trigger(self: *PulseChannel) void {
        self.enabled = true;
        if (self.length == 0) self.length = 64;

        self.frequency = @as(u16, self.nr3) | (@as(u16, self.nr4 & 0x07) << 8);
        self.freq_timer = (2048 - self.frequency) * 4;

        self.volume = self.nr2 >> 4;
        self.envelope_timer = self.nr2 & 0x07;

        if (self.has_sweep) {
            self.shadow_freq = self.frequency;
            self.sweep_timer = (self.nr0 >> 4) & 0x07;
            if (self.sweep_timer == 0) self.sweep_timer = 8;
            self.sweep_enabled = self.sweep_timer > 0 or (self.nr0 & 0x07) > 0;
        }

        if (self.nr2 & 0xF8 == 0) self.enabled = false;
    }

    pub fn tickFrequency(self: *PulseChannel) void {
        if (self.freq_timer > 0) {
            self.freq_timer -= 1;
        }
        if (self.freq_timer == 0) {
            self.freq_timer = (2048 - self.frequency) * 4;
            self.duty_pos +%= 1;
        }
    }

    pub fn tickLength(self: *PulseChannel) void {
        if (self.nr4 & 0x40 != 0 and self.length > 0) {
            self.length -= 1;
            if (self.length == 0) self.enabled = false;
        }
    }

    pub fn tickEnvelope(self: *PulseChannel) void {
        const period = self.nr2 & 0x07;
        if (period == 0) return;

        if (self.envelope_timer > 0) self.envelope_timer -= 1;
        if (self.envelope_timer == 0) {
            self.envelope_timer = period;
            if (self.nr2 & 0x08 != 0) {
                if (self.volume < 15) self.volume += 1;
            } else {
                if (self.volume > 0) self.volume -= 1;
            }
        }
    }

    pub fn tickSweep(self: *PulseChannel) void {
        if (!self.has_sweep or !self.sweep_enabled) return;

        if (self.sweep_timer > 0) self.sweep_timer -= 1;
        if (self.sweep_timer == 0) {
            const period = (self.nr0 >> 4) & 0x07;
            self.sweep_timer = if (period > 0) period else 8;

            if (period > 0) {
                const shift: u4 = @intCast(self.nr0 & 0x07);
                const delta = self.shadow_freq >> shift;

                const new_freq = if (self.nr0 & 0x08 != 0)
                    self.shadow_freq -% delta
                else
                    self.shadow_freq +% delta;

                if (new_freq > 2047) {
                    self.enabled = false;
                } else if (shift > 0) {
                    self.shadow_freq = new_freq;
                    self.frequency = new_freq;
                }
            }
        }
    }

    pub fn output(self: *PulseChannel) i8 {
        if (!self.enabled) return 0;
        const duty: u2 = @intCast(self.nr1 >> 6);
        const high = DUTY_TABLE[duty][self.duty_pos] != 0;
        const vol: i8 = @intCast(self.volume);
        return if (high) vol else -vol;
    }
};

pub const WaveChannel = struct {
    enabled: bool = false,
    nr0: u8 = 0,
    nr2: u8 = 0,
    nr3: u8 = 0,
    nr4: u8 = 0,

    length: u16 = 0,
    frequency: u16 = 0,
    freq_timer: u16 = 0,
    sample_idx: u5 = 0,

    pub fn writeNR4(self: *WaveChannel, val: u8) void {
        self.nr4 = val;
        if (val & 0x80 != 0) self.trigger();
    }

    fn trigger(self: *WaveChannel) void {
        self.enabled = self.nr0 & 0x80 != 0;
        if (self.length == 0) self.length = 256;
        self.frequency = @as(u16, self.nr3) | (@as(u16, self.nr4 & 0x07) << 8);
        self.freq_timer = (2048 - self.frequency) * 2;
        self.sample_idx = 0;
    }

    pub fn tickFrequency(self: *WaveChannel) void {
        if (self.freq_timer > 0) {
            self.freq_timer -= 1;
        }
        if (self.freq_timer == 0) {
            self.freq_timer = (2048 - self.frequency) * 2;
            self.sample_idx +%= 1;
        }
    }

    pub fn tickLength(self: *WaveChannel) void {
        if (self.nr4 & 0x40 != 0 and self.length > 0) {
            self.length -= 1;
            if (self.length == 0) self.enabled = false;
        }
    }

    pub fn output(self: *WaveChannel, wave_ram: *const [16]u8) i8 {
        if (!self.enabled or self.nr0 & 0x80 == 0) return 0;

        // Each byte contains 2 samples (4 bits each)
        const byte_idx = self.sample_idx >> 1;
        const nibble: u8 = if (self.sample_idx & 1 == 0)
            wave_ram[byte_idx] >> 4
        else
            wave_ram[byte_idx] & 0x0F;

        // Volume: 0=mute, 1=100%, 2=50%, 3=25%
        const vol_code: u2 = @truncate(self.nr2 >> 5);
        const sample: i8 = switch (vol_code) {
            0 => 0,
            1 => @as(i8, @intCast(nibble)) - 8,
            2 => @as(i8, @intCast(nibble >> 1)) - 4,
            3 => @as(i8, @intCast(nibble >> 2)) - 2,
        };

        return sample;
    }
};

pub const NoiseChannel = struct {
    enabled: bool = false,
    nr2: u8 = 0,
    nr3: u8 = 0,
    nr4: u8 = 0,

    length: u8 = 0,
    volume: u8 = 0,
    freq_timer: u16 = 0,
    lfsr: u16 = 0x7FFF,
    envelope_timer: u8 = 0,

    pub fn writeNR4(self: *NoiseChannel, val: u8) void {
        self.nr4 = val;
        if (val & 0x80 != 0) self.trigger();
    }

    fn trigger(self: *NoiseChannel) void {
        self.enabled = true;
        if (self.length == 0) self.length = 64;
        self.lfsr = 0x7FFF;
        self.volume = self.nr2 >> 4;
        self.envelope_timer = self.nr2 & 0x07;

        const divisor = DIVISORS[self.nr3 & 0x07];
        const shift: u4 = @intCast(self.nr3 >> 4);
        self.freq_timer = divisor << shift;

        if (self.nr2 & 0xF8 == 0) self.enabled = false;
    }

    const DIVISORS = [8]u16{ 8, 16, 32, 48, 64, 80, 96, 112 };

    pub fn tickFrequency(self: *NoiseChannel) void {
        if (self.freq_timer > 0) {
            self.freq_timer -= 1;
        }
        if (self.freq_timer == 0) {
            const divisor = DIVISORS[self.nr3 & 0x07];
            const shift: u4 = @intCast(self.nr3 >> 4);
            self.freq_timer = divisor << shift;

            const xor_bit: u16 = (self.lfsr & 1) ^ ((self.lfsr >> 1) & 1);
            self.lfsr = (self.lfsr >> 1) | (xor_bit << 14);
            if (self.nr3 & 0x08 != 0) {
                // 7-bit mode: also set bit 6
                self.lfsr &= ~@as(u16, 0x40);
                self.lfsr |= xor_bit << 6;
            }
        }
    }

    pub fn tickLength(self: *NoiseChannel) void {
        if (self.nr4 & 0x40 != 0 and self.length > 0) {
            self.length -= 1;
            if (self.length == 0) self.enabled = false;
        }
    }

    pub fn tickEnvelope(self: *NoiseChannel) void {
        const period = self.nr2 & 0x07;
        if (period == 0) return;

        if (self.envelope_timer > 0) self.envelope_timer -= 1;
        if (self.envelope_timer == 0) {
            self.envelope_timer = period;
            if (self.nr2 & 0x08 != 0) {
                if (self.volume < 15) self.volume += 1;
            } else {
                if (self.volume > 0) self.volume -= 1;
            }
        }
    }

    pub fn output(self: *NoiseChannel) i8 {
        if (!self.enabled) return 0;
        const high = (~self.lfsr & 1) != 0;
        const vol: i8 = @intCast(self.volume);
        return if (high) vol else -vol;
    }
};
