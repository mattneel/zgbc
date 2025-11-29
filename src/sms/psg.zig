//! SN76489 PSG (Programmable Sound Generator)
//! 3 square wave channels + 1 noise channel.

const std = @import("std");

pub const PSG = struct {
    // Channels
    tone: [3]ToneChannel = [_]ToneChannel{.{}} ** 3,
    noise: NoiseChannel = .{},

    // Latched register
    latched_channel: u2 = 0,
    latched_type: bool = false, // false=freq, true=volume

    // Output buffer (ring buffer)
    sample_buffer: [4096]i16 = [_]i16{0} ** 4096,
    sample_write_idx: usize = 0,
    sample_read_idx: usize = 0,

    // Timing
    cycle_counter: u32 = 0,

    // Low-pass filter state
    prev_sample: i32 = 0,

    const CPU_FREQ = 3579545;
    const SAMPLE_RATE = 44100;
    const CYCLES_PER_SAMPLE = CPU_FREQ / SAMPLE_RATE;

    pub fn write(self: *PSG, val: u8) void {
        if (val & 0x80 != 0) {
            // Latch + data byte
            self.latched_channel = @intCast((val >> 5) & 3);
            self.latched_type = val & 0x10 != 0;

            if (self.latched_channel < 3) {
                if (self.latched_type) {
                    // Volume
                    self.tone[self.latched_channel].volume = @intCast(val & 0x0F);
                } else {
                    // Frequency (low 4 bits)
                    self.tone[self.latched_channel].freq =
                        (self.tone[self.latched_channel].freq & 0x3F0) | (val & 0x0F);
                }
            } else {
                if (self.latched_type) {
                    self.noise.volume = @intCast(val & 0x0F);
                } else {
                    self.noise.ctrl = @intCast(val & 0x07);
                    self.noise.shift = 0x8000; // Reset LFSR
                }
            }
        } else {
            // Data only byte (for frequency high bits)
            if (self.latched_channel < 3 and !self.latched_type) {
                self.tone[self.latched_channel].freq =
                    (self.tone[self.latched_channel].freq & 0x0F) | (@as(u10, val & 0x3F) << 4);
            }
        }
    }

    pub fn tick(self: *PSG, cycles: u8) void {
        // Tick channels every CPU cycle (period is scaled by 16 internally)
        for (0..cycles) |_| {
            self.tone[0].tick();
            self.tone[1].tick();
            self.tone[2].tick();
            self.noise.tick(self.tone[2].freq);
        }

        self.cycle_counter += cycles;
        while (self.cycle_counter >= CYCLES_PER_SAMPLE) {
            self.cycle_counter -= CYCLES_PER_SAMPLE;
            self.outputSample();
        }
    }

    fn outputSample(self: *PSG) void {
        var out: i32 = 0;
        out += self.tone[0].output();
        out += self.tone[1].output();
        out += self.tone[2].output();
        out += self.noise.output();

        // Simple low-pass filter to reduce aliasing
        out = (self.prev_sample + out) >> 1;
        self.prev_sample = out;

        const sample: i16 = @intCast(std.math.clamp(out, -32768, 32767));

        // Ring buffer - write stereo sample
        const next_idx = (self.sample_write_idx + 2) % self.sample_buffer.len;
        if (next_idx != self.sample_read_idx) {
            self.sample_buffer[self.sample_write_idx] = sample;
            self.sample_buffer[self.sample_write_idx + 1] = sample;
            self.sample_write_idx = next_idx;
        }
    }

    pub fn readSamples(self: *PSG, out: []i16) usize {
        var count: usize = 0;
        while (count < out.len and self.sample_read_idx != self.sample_write_idx) {
            out[count] = self.sample_buffer[self.sample_read_idx];
            self.sample_read_idx = (self.sample_read_idx + 1) % self.sample_buffer.len;
            count += 1;
        }
        return count;
    }
};

const ToneChannel = struct {
    freq: u10 = 0,
    volume: u4 = 0xF, // 0=max, F=off
    counter: u16 = 0,
    polarity: bool = false,

    fn tick(self: *ToneChannel) void {
        if (self.counter > 0) {
            self.counter -= 1;
        } else {
            // PSG period is freq * 16 (PSG runs at CPU/16)
            self.counter = @as(u16, self.freq) * 16;
            self.polarity = !self.polarity;
        }
    }

    fn output(self: ToneChannel) i32 {
        if (self.volume == 0xF) return 0;
        if (self.freq < 2) return 0; // Very high frequencies are silent
        const vol = VOLUME_TABLE[self.volume];
        return if (self.polarity) vol else -vol;
    }
};

const NoiseChannel = struct {
    ctrl: u3 = 0,
    volume: u4 = 0xF,
    counter: u16 = 0,
    shift: u16 = 0x8000,

    fn tick(self: *NoiseChannel, tone2_freq: u10) void {
        if (self.counter > 0) {
            self.counter -= 1;
        } else {
            // Reset counter based on control (scaled by 16)
            self.counter = switch (@as(u2, @truncate(self.ctrl & 0x03))) {
                0 => 0x100,
                1 => 0x200,
                2 => 0x400,
                3 => @as(u16, tone2_freq) * 16,
            };

            // Shift LFSR
            const feedback: u1 = if (self.ctrl & 0x04 != 0)
                // White noise: tap bits 0 and 3
                @truncate((self.shift ^ (self.shift >> 3)) & 1)
            else
                // Periodic noise: tap bit 0 only
                @truncate(self.shift & 1);

            self.shift = (self.shift >> 1) | (@as(u16, feedback) << 15);
        }
    }

    fn output(self: NoiseChannel) i32 {
        if (self.volume == 0xF) return 0;
        const vol = VOLUME_TABLE[self.volume];
        return if (self.shift & 1 != 0) vol else -vol;
    }
};

// Volume table: 2dB steps, scaled for 4-channel mixing headroom
const VOLUME_TABLE = [16]i32{
    2047, 1627, 1292, 1026, 815, 647, 514, 408,
    324, 257, 204, 162, 129, 102, 81, 0,
};
