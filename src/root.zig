//! libzetro - Multi-system Emulator Core
//! Minimal, high-performance emulator for headless execution.

const std = @import("std");

// Core interface
pub const Core = @import("core.zig").Core;

// Game Boy
pub const gb = @import("gb/system.zig");
pub const GB = gb.GB;
pub const SaveState = gb.SaveState;

// Re-export GB internals for backwards compatibility
pub const CPU = @import("gb/cpu.zig").CPU;
pub const Flags = @import("gb/cpu.zig").Flags;
pub const MMU = @import("gb/mmu.zig").MMU;
pub const Timer = @import("gb/timer.zig").Timer;
pub const MBC = @import("gb/mbc.zig").MBC;
pub const PPU = @import("gb/ppu.zig").PPU;
pub const PALETTE = @import("gb/ppu.zig").PALETTE;
pub const APU = @import("gb/apu.zig").APU;

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
