const std = @import("std");
const zgbc = @import("zgbc");

const rl = @cImport({
    @cDefine("PLATFORM_DESKTOP", "1");
    @cInclude("raylib.h");
});

const Allocator = std.mem.Allocator;

const SystemPref = enum { auto, gb, nes, sms, genesis };
const SystemKind = enum { gb, nes, sms, genesis };

const CliOptions = struct {
    rom_path: []u8,
    system_pref: SystemPref = .auto,
    scale: u32 = 3,
    headless: bool = false,
    audio: bool = true,
    skip_boot: bool = false,
    allocator: Allocator,

    fn parse(allocator: Allocator) !CliOptions {
        var iter = try std.process.ArgIterator.initWithAllocator(allocator);
        defer iter.deinit();

        _ = iter.next(); // Skip executable path

        var rom_path: ?[]const u8 = null;
        var system_pref: SystemPref = .auto;
        var scale_value: u32 = 3;
        var headless = false;
        var audio = true;
        var skip_boot = false;

        while (iter.next()) |raw| {
            if (std.mem.eql(u8, raw, "--help") or std.mem.eql(u8, raw, "-h")) {
                try printUsage();
                return error.ShowedHelp;
            } else if (std.mem.startsWith(u8, raw, "--")) {
                try parseLongOption(raw, &iter, &system_pref, &scale_value, &headless, &audio, &skip_boot);
            } else if (std.mem.startsWith(u8, raw, "-") and raw.len > 1) {
                try parseShortOption(raw, &iter, &system_pref, &scale_value);
            } else {
                if (rom_path != null) {
                    return error.TooManyPositionals;
                }
                rom_path = raw;
            }
        }

        const rom_slice = rom_path orelse return error.MissingRom;
        if (scale_value == 0 or scale_value > 10) {
            return error.InvalidScale;
        }

        return CliOptions{
            .rom_path = try allocator.dupe(u8, rom_slice),
            .system_pref = system_pref,
            .scale = scale_value,
            .headless = headless,
            .audio = audio,
            .skip_boot = skip_boot,
            .allocator = allocator,
        };
    }

    fn deinit(self: *CliOptions) void {
        self.allocator.free(self.rom_path);
    }
};

fn parseLongOption(
    arg: []const u8,
    iter: *std.process.ArgIterator,
    system_pref: *SystemPref,
    scale_value: *u32,
    headless: *bool,
    audio: *bool,
    skip_boot: *bool,
) !void {
    const eq = std.mem.indexOfScalar(u8, arg, '=');
    const name = arg[2..(eq orelse arg.len)];
    const value = if (eq) |idx| arg[idx + 1 ..] else null;

    if (std.mem.eql(u8, name, "system")) {
        const v = value orelse (iter.next() orelse return error.MissingSystemValue);
        system_pref.* = try parseSystemPref(v);
    } else if (std.mem.eql(u8, name, "scale")) {
        const v = value orelse (iter.next() orelse return error.MissingScaleValue);
        scale_value.* = try std.fmt.parseUnsigned(u32, v, 10);
    } else if (std.mem.eql(u8, name, "headless")) {
        headless.* = true;
    } else if (std.mem.eql(u8, name, "no-audio")) {
        audio.* = false;
    } else if (std.mem.eql(u8, name, "skip-boot")) {
        skip_boot.* = true;
    } else {
        return error.UnknownFlag;
    }
}

fn parseShortOption(
    raw: []const u8,
    iter: *std.process.ArgIterator,
    system_pref: *SystemPref,
    scale_value: *u32,
) !void {
    switch (raw[1]) {
        's' => {
            const value = iter.next() orelse return error.MissingSystemValue;
            system_pref.* = try parseSystemPref(value);
        },
        'S' => {
            const value = iter.next() orelse return error.MissingScaleValue;
            scale_value.* = try std.fmt.parseUnsigned(u32, value, 10);
        },
        'h' => {
            try printUsage();
            return error.ShowedHelp;
        },
        else => return error.UnknownFlag,
    }
}

fn parseSystemPref(value: []const u8) !SystemPref {
    if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(value, "gb") or std.ascii.eqlIgnoreCase(value, "gameboy")) return .gb;
    if (std.ascii.eqlIgnoreCase(value, "nes")) return .nes;
    if (std.ascii.eqlIgnoreCase(value, "sms")) return .sms;
    if (std.ascii.eqlIgnoreCase(value, "genesis") or std.ascii.eqlIgnoreCase(value, "md")) return .genesis;
    return error.UnknownSystemFlag;
}

fn printUsage() !void {
    std.debug.print(
        \\zgbc - Multi-system emulator
        \\
        \\Usage: zgbc [options] <rom>
        \\
        \\Options:
        \\  -h, --help              Show this help.
        \\  -s, --system <name>     Force system (auto|gb|nes|sms|genesis).
        \\  -S, --scale <N>         Window scale factor (default 3).
        \\      --headless         Disable rendering (prints FPS).
        \\      --no-audio         Mute playback.
        \\      --skip-boot        Skip the Game Boy boot ROM.
        \\
    , .{});
}

const ScratchBuffer = struct {
    allocator: Allocator,
    data: []u32 = &.{},

    fn init(allocator: Allocator) ScratchBuffer {
        return .{ .allocator = allocator };
    }

    fn ensure(self: *ScratchBuffer, count: usize) ![]u32 {
        if (self.data.len < count) {
            if (self.data.len != 0) {
                self.allocator.free(self.data);
            }
            self.data = try self.allocator.alloc(u32, count);
        }
        return self.data[0..count];
    }

    fn deinit(self: *ScratchBuffer) void {
        if (self.data.len != 0) {
            self.allocator.free(self.data);
        }
    }
};

const FrameSlice = struct {
    width: c_int,
    height: c_int,
    pixels: []const u32,
};

const NativeRenderer = struct {
    texture: rl.Texture2D = undefined,
    has_texture: bool = false,
    scale: c_int,
    width: c_int = 0,
    height: c_int = 0,

    fn init(scale: u32) NativeRenderer {
        return .{ .scale = @intCast(scale) };
    }

    fn deinit(self: *NativeRenderer) void {
        if (self.has_texture) {
            rl.UnloadTexture(self.texture);
        }
    }

    fn present(self: *NativeRenderer, frame: FrameSlice) void {
        self.ensureTexture(frame);
        rl.UpdateTexture(self.texture, @ptrCast(frame.pixels.ptr));

        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);

        const dest = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(frame.width * self.scale),
            .height = @floatFromInt(frame.height * self.scale),
        };
        const source = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(frame.width),
            .height = @floatFromInt(frame.height),
        };

        rl.DrawTexturePro(self.texture, source, dest, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
        rl.EndDrawing();
    }

    fn ensureTexture(self: *NativeRenderer, frame: FrameSlice) void {
        if (!self.has_texture or frame.width != self.width or frame.height != self.height) {
            if (self.has_texture) {
                rl.UnloadTexture(self.texture);
            }
            const image = rl.Image{
                .data = @ptrCast(@constCast(frame.pixels.ptr)),
                .width = frame.width,
                .height = frame.height,
                .mipmaps = 1,
                .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
            };
            self.texture = rl.LoadTextureFromImage(image);
            self.width = frame.width;
            self.height = frame.height;
            self.has_texture = true;
            rl.SetWindowSize(frame.width * self.scale, frame.height * self.scale);
        }
    }
};

const AudioDevice = struct {
    enabled: bool = false,
    stream: rl.AudioStream = undefined,
    sample_rate: c_int = 44100,

    fn init(sample_rate: u32) AudioDevice {
        rl.InitAudioDevice();
        const stream = rl.LoadAudioStream(@intCast(sample_rate), 16, 2);
        rl.PlayAudioStream(stream);
        return .{
            .enabled = true,
            .stream = stream,
            .sample_rate = @intCast(sample_rate),
        };
    }

    fn deinit(self: *AudioDevice) void {
        if (!self.enabled) return;
        rl.UnloadAudioStream(self.stream);
        rl.CloseAudioDevice();
    }

    fn push(self: *AudioDevice, samples: []const i16) void {
        if (!self.enabled or samples.len == 0) return;
        const frames = @as(c_int, @intCast(samples.len / 2));
        if (frames == 0) return;
        if (rl.IsAudioStreamProcessed(self.stream)) {
            rl.UpdateAudioStream(self.stream, @ptrCast(samples.ptr), frames);
        }
    }
};

const Emulator = union(SystemKind) {
    gb: struct { core: zgbc.GB },
    nes: struct { core: zgbc.NES },
    sms: struct { core: zgbc.SMS },
    genesis: struct { core: zgbc.Genesis },

    fn init(system_kind: SystemKind, rom: []const u8, opts: CliOptions) !Emulator {
        return switch (system_kind) {
            .gb => blk: {
                var gb = zgbc.GB{};
                try gb.loadRom(rom);
                if (opts.skip_boot) gb.skipBootRom();
                gb.render_graphics = !opts.headless;
                gb.render_audio = opts.audio;
                break :blk .{ .gb = .{ .core = gb } };
            },
            .nes => blk: {
                var nes = zgbc.NES{};
                nes.loadRom(rom);
                nes.render_graphics = !opts.headless;
                nes.render_audio = opts.audio;
                break :blk .{ .nes = .{ .core = nes } };
            },
            .sms => blk: {
                var sms = zgbc.SMS{};
                sms.loadRom(rom);
                sms.render_graphics = !opts.headless;
                sms.render_audio = opts.audio;
                break :blk .{ .sms = .{ .core = sms } };
            },
            .genesis => blk: {
                var gen = zgbc.Genesis{};
                gen.loadRom(rom);
                break :blk .{ .genesis = .{ .core = gen } };
            },
        };
    }

    fn deinit(_: *Emulator) void {}

    fn kind(self: Emulator) SystemKind {
        return switch (self) {
            .gb => .gb,
            .nes => .nes,
            .sms => .sms,
            .genesis => .genesis,
        };
    }

    fn name(self: Emulator) []const u8 {
        return switch (self) {
            .gb => "Game Boy",
            .nes => "NES",
            .sms => "Sega Master System",
            .genesis => "Sega Genesis",
        };
    }

    fn frame(self: *Emulator) void {
        switch (self.*) {
            .gb => |*state| state.core.frame(),
            .nes => |*state| state.core.frame(),
            .sms => |*state| state.core.frame(),
            .genesis => |*state| state.core.frame(),
        }
    }

    fn setInput(self: *Emulator, mask: u8) void {
        switch (self.*) {
            .gb => |*state| state.core.setInput(mask),
            .nes => |*state| state.core.setInput(mask),
            .sms => |*state| state.core.setInput(mask),
            .genesis => |*state| state.core.setInput(mask),
        }
    }

    fn readAudioSamples(self: *Emulator, out: []i16) usize {
        switch (self.*) {
            .gb => |*state| return state.core.getAudioSamples(out),
            .nes => |*state| return state.core.getAudioSamples(out),
            .sms => |*state| return state.core.getAudioSamples(out),
            .genesis => |*state| return state.core.getAudioSamples(out),
        }
    }
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var cli = CliOptions.parse(allocator) catch |err| switch (err) {
        error.ShowedHelp => return,
        else => {
            std.log.err("argument error: {s}", .{@errorName(err)});
            try printUsage();
            return err;
        },
    };
    defer cli.deinit();

    const rom_data = try readRom(allocator, cli.rom_path);
    defer allocator.free(rom_data);

    const system_kind = try resolveSystem(cli.system_pref, cli.rom_path);
    var emulator = try Emulator.init(system_kind, rom_data, cli);
    defer emulator.deinit();

    if (cli.headless) {
        try runHeadless(&emulator);
        return;
    }

    try runNative(&emulator, &cli, allocator);
}

fn runHeadless(emulator: *Emulator) !void {
    var timer = try std.time.Timer.start();
    var frames: u64 = 0;
    while (true) {
        emulator.frame();
        frames += 1;
        if (timer.read() >= std.time.ns_per_s) {
            std.debug.print("\r{d} FPS", .{frames});
            timer.reset();
            frames = 0;
        }
    }
}

fn runNative(emulator: *Emulator, cli: *const CliOptions, allocator: Allocator) !void {
    var scratch = ScratchBuffer.init(allocator);
    defer scratch.deinit();

    const rom_name = std.fs.path.basename(cli.rom_path);
    const title_text = try std.fmt.allocPrint(allocator, "zgbc | {s} ({s})", .{ emulator.name(), rom_name });
    defer allocator.free(title_text);
    const title = try allocCString(allocator, title_text);
    defer allocator.free(title);

    var frame = try fetchFrame(emulator, &scratch);

    rl.SetConfigFlags(rl.FLAG_VSYNC_HINT);
    rl.InitWindow(frame.width * @as(c_int, @intCast(cli.scale)), frame.height * @as(c_int, @intCast(cli.scale)), title.ptr);
    defer rl.CloseWindow();
    rl.SetExitKey(0);
    rl.SetTargetFPS(60);

    var renderer = NativeRenderer.init(cli.scale);
    defer renderer.deinit();

    var audio_device = AudioDevice{};
    if (cli.audio) {
        audio_device = AudioDevice.init(44100);
    }
    defer audio_device.deinit();

    var audio_buffer: [4096]i16 = undefined;

    renderer.present(frame);

    while (!rl.WindowShouldClose()) {
        const buttons = gatherButtons(emulator.kind());
        emulator.setInput(buttons);

        emulator.frame();

        frame = try fetchFrame(emulator, &scratch);
        renderer.present(frame);

        if (cli.audio) {
            const sample_count = emulator.readAudioSamples(&audio_buffer);
            audio_device.push(audio_buffer[0..sample_count]);
        }
    }
}

fn fetchFrame(emulator: *Emulator, scratch: *ScratchBuffer) !FrameSlice {
    return switch (emulator.*) {
        .gb => |*state| blk: {
            const width: u32 = 160;
            const height: u32 = 144;
            const dst = try scratch.ensure(width * height);
            const src = state.core.getFrameBuffer();
            for (dst, 0..) |*pixel, idx| {
                pixel.* = zgbc.PALETTE[src[idx]];
            }
            break :blk FrameSlice{
                .width = @intCast(width),
                .height = @intCast(height),
                .pixels = dst,
            };
        },
        .nes => |*state| blk: {
            const width = zgbc.nes.SCREEN_WIDTH;
            const height = zgbc.nes.SCREEN_HEIGHT;
            const buf = state.core.getFrameBuffer();
            const slice = buf[0 .. @as(usize, width) * @as(usize, height)];
            break :blk FrameSlice{
                .width = @intCast(width),
                .height = @intCast(height),
                .pixels = slice,
            };
        },
        .sms => |*state| blk: {
            const width = zgbc.sms.system.SCREEN_WIDTH;
            const height = state.core.getScreenHeight();
            const base_ptr = if (height > zgbc.sms.system.SCREEN_HEIGHT)
                state.core.getExtendedFrameBuffer()
            else
                state.core.getFrameBuffer();
            const slice = base_ptr[0 .. @as(usize, width) * @as(usize, height)];
            break :blk FrameSlice{
                .width = @intCast(width),
                .height = @intCast(height),
                .pixels = slice,
            };
        },
        .genesis => |*state| blk: {
            const width = zgbc.genesis.system.SCREEN_WIDTH;
            const height = zgbc.genesis.system.SCREEN_HEIGHT;
            const buf = state.core.getFrameBuffer();
            const slice = buf[0 .. @as(usize, width) * @as(usize, height)];
            break :blk FrameSlice{
                .width = @intCast(width),
                .height = @intCast(height),
                .pixels = slice,
            };
        },
    };
}

fn gatherButtons(kind: SystemKind) u8 {
    return switch (kind) {
        .gb => collectButtons(&gb_button_map),
        .nes => collectButtons(&nes_button_map),
        .sms => collectButtons(&sms_button_map),
        .genesis => collectButtons(&genesis_button_map),
    };
}

fn collectButtons(bindings: []const ButtonBinding) u8 {
    var mask: u8 = 0;
    for (bindings) |binding| {
        if (rl.IsKeyDown(binding.key)) {
            mask |= @as(u8, 1) << binding.bit;
        }
    }
    return mask;
}

const ButtonBinding = struct {
    key: c_int,
    bit: u3,
};

const gb_button_map = [_]ButtonBinding{
    .{ .key = rl.KEY_Z, .bit = 0 },
    .{ .key = rl.KEY_X, .bit = 1 },
    .{ .key = rl.KEY_LEFT_SHIFT, .bit = 2 },
    .{ .key = rl.KEY_ENTER, .bit = 3 },
    .{ .key = rl.KEY_RIGHT, .bit = 4 },
    .{ .key = rl.KEY_LEFT, .bit = 5 },
    .{ .key = rl.KEY_UP, .bit = 6 },
    .{ .key = rl.KEY_DOWN, .bit = 7 },
};

const nes_button_map = [_]ButtonBinding{
    .{ .key = rl.KEY_Z, .bit = 0 },
    .{ .key = rl.KEY_X, .bit = 1 },
    .{ .key = rl.KEY_LEFT_SHIFT, .bit = 2 },
    .{ .key = rl.KEY_ENTER, .bit = 3 },
    .{ .key = rl.KEY_UP, .bit = 4 },
    .{ .key = rl.KEY_DOWN, .bit = 5 },
    .{ .key = rl.KEY_LEFT, .bit = 6 },
    .{ .key = rl.KEY_RIGHT, .bit = 7 },
};

const sms_button_map = [_]ButtonBinding{
    .{ .key = rl.KEY_UP, .bit = 0 },
    .{ .key = rl.KEY_DOWN, .bit = 1 },
    .{ .key = rl.KEY_LEFT, .bit = 2 },
    .{ .key = rl.KEY_RIGHT, .bit = 3 },
    .{ .key = rl.KEY_Z, .bit = 4 },
    .{ .key = rl.KEY_X, .bit = 5 },
};

const genesis_button_map = [_]ButtonBinding{
    .{ .key = rl.KEY_UP, .bit = 0 },
    .{ .key = rl.KEY_DOWN, .bit = 1 },
    .{ .key = rl.KEY_LEFT, .bit = 2 },
    .{ .key = rl.KEY_RIGHT, .bit = 3 },
    .{ .key = rl.KEY_Z, .bit = 4 },
    .{ .key = rl.KEY_X, .bit = 5 },
    .{ .key = rl.KEY_C, .bit = 6 },
    .{ .key = rl.KEY_ENTER, .bit = 7 },
};

fn resolveSystem(pref: SystemPref, path: []const u8) !SystemKind {
    return switch (pref) {
        .auto => detectFromExtension(path) orelse error.UnknownSystem,
        .gb => .gb,
        .nes => .nes,
        .sms => .sms,
        .genesis => .genesis,
    };
}

fn detectFromExtension(path: []const u8) ?SystemKind {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".gb") or std.ascii.eqlIgnoreCase(ext, ".gbc")) return .gb;
    if (std.ascii.eqlIgnoreCase(ext, ".nes")) return .nes;
    if (std.ascii.eqlIgnoreCase(ext, ".sms") or std.ascii.eqlIgnoreCase(ext, ".gg")) return .sms;
    if (std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".gen") or
        std.ascii.eqlIgnoreCase(ext, ".smd") or std.ascii.eqlIgnoreCase(ext, ".bin"))
    {
        return .genesis;
    }
    return null;
}

fn readRom(allocator: Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
}

fn allocCString(allocator: Allocator, text: []const u8) ![:0]u8 {
    const buf = try allocator.allocSentinel(u8, text.len, 0);
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len :0];
}
