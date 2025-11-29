//! Sega Genesis module exports

pub const Genesis = @import("system.zig").Genesis;
pub const M68K = @import("cpu.zig").M68K;
pub const VDP = @import("vdp.zig").VDP;
pub const YM2612 = @import("ym2612.zig").YM2612;
pub const PSG = @import("psg.zig").PSG;
pub const Bus = @import("bus.zig").Bus;
pub const Z80 = @import("z80.zig").CPU;

pub const SCREEN_WIDTH = @import("system.zig").SCREEN_WIDTH;
pub const SCREEN_HEIGHT = @import("system.zig").SCREEN_HEIGHT;
