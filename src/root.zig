//! zgbc - Zig Game Boy Emulator Core
//! Minimal, high-performance emulator for headless execution.

const std = @import("std");

// Re-export core types
pub const GB = @import("gb.zig").GB;
pub const CPU = @import("cpu.zig").CPU;
pub const Flags = @import("cpu.zig").Flags;
pub const MMU = @import("mmu.zig").MMU;
pub const Timer = @import("timer.zig").Timer;
pub const MBC = @import("mbc.zig").MBC;

// SIMD batch processing
pub const simd = @import("simd_batch.zig");
pub const BatchCPU = simd.BatchCPU;
pub const BATCH_SIZE = simd.BATCH_SIZE;

/// Button state for joypad input
pub const Buttons = packed struct(u8) {
    a: bool = false,
    b: bool = false,
    select: bool = false,
    start: bool = false,
    right: bool = false,
    left: bool = false,
    up: bool = false,
    down: bool = false,
};

test {
    std.testing.refAllDecls(@This());
}
