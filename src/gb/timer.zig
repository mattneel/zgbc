//! Game Boy Timer
//! Handles DIV and TIMA counters.

const std = @import("std");

pub const Timer = struct {
    /// Tick the timer by the given number of cycles
    /// Updates DIV and TIMA, sets interrupt flag on overflow
    pub fn tick(div_counter: *u16, tima: *u8, tma: u8, tac: u8, if_: *u8, cycles: u8) void {
        // Check if timer is enabled (TAC bit 2)
        const enabled = tac & 0x04 != 0;

        // Get the bit position to check based on TAC frequency
        const bit_pos: u4 = switch (@as(u2, @truncate(tac))) {
            0 => 9, // 4096 Hz (every 1024 cycles) - bit 9
            1 => 3, // 262144 Hz (every 16 cycles) - bit 3
            2 => 5, // 65536 Hz (every 64 cycles) - bit 5
            3 => 7, // 16384 Hz (every 256 cycles) - bit 7
        };

        // Process each cycle to catch all falling edges
        var remaining = cycles;
        while (remaining > 0) : (remaining -= 1) {
            const old_bit = (div_counter.* >> bit_pos) & 1;
            div_counter.* +%= 1;
            const new_bit = (div_counter.* >> bit_pos) & 1;

            if (enabled and old_bit == 1 and new_bit == 0) {
                // Falling edge detected - increment TIMA
                const result = @addWithOverflow(tima.*, 1);
                tima.* = result[0];

                if (result[1] == 1) {
                    // Overflow - reload from TMA and set interrupt
                    tima.* = tma;
                    if_.* |= 0x04; // Timer interrupt (bit 2)
                }
            }
        }
    }
};

test "div increments" {
    var div: u16 = 0;
    var tima: u8 = 0;
    var if_: u8 = 0;

    Timer.tick(&div, &tima, 0, 0, &if_, 4);
    try std.testing.expectEqual(@as(u16, 4), div);

    Timer.tick(&div, &tima, 0, 0, &if_, 252);
    try std.testing.expectEqual(@as(u16, 256), div);
}
