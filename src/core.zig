//! Core emulator interface
//! Generic interface that all system implementations must satisfy.

const std = @import("std");

/// Core emulator interface
/// All systems (GB, NES, SNES, etc.) implement this interface.
pub fn Core(comptime System: type) type {
    return struct {
        system: System,

        const Self = @This();

        // =========================================================
        // Lifecycle
        // =========================================================

        /// Load a ROM into the emulator
        pub fn loadRom(self: *Self, data: []const u8) void {
            self.system.loadRom(data);
        }

        // =========================================================
        // Execution
        // =========================================================

        /// Execute one frame
        pub fn frame(self: *Self) void {
            self.system.frame();
        }

        /// Execute one instruction, return cycles consumed
        pub fn step(self: *Self) u8 {
            return self.system.step();
        }

        // =========================================================
        // Input
        // =========================================================

        /// Set controller input state
        pub fn setInput(self: *Self, buttons: u16) void {
            self.system.setInput(@truncate(buttons));
        }

        // =========================================================
        // Output
        // =========================================================

        /// Get frame buffer (system-specific format)
        pub fn getFrameBuffer(self: *Self) []const u8 {
            return self.system.getFrameBuffer();
        }

        /// Get audio samples
        pub fn getAudioSamples(self: *Self, buf: []i16) usize {
            return self.system.getAudioSamples(buf);
        }

        // =========================================================
        // Memory access (for RL observations)
        // =========================================================

        /// Read byte from memory
        pub fn read(self: *Self, addr: u32) u8 {
            return self.system.read(@truncate(addr));
        }

        /// Write byte to memory
        pub fn write(self: *Self, addr: u32, val: u8) void {
            self.system.write(@truncate(addr), val);
        }

        /// Get RAM for bulk observations
        pub fn getRam(self: *Self) []const u8 {
            return self.system.getRam();
        }

        // =========================================================
        // Save states
        // =========================================================

        /// Create a save state snapshot
        pub fn saveState(self: *Self) System.SaveState {
            return self.system.saveState();
        }

        /// Restore from a save state
        pub fn loadState(self: *Self, state: System.SaveState) void {
            self.system.loadState(state);
        }

        // =========================================================
        // Battery saves
        // =========================================================

        /// Get save data (battery-backed RAM)
        pub fn getSaveData(self: *Self) []const u8 {
            return self.system.getSaveData();
        }

        /// Load save data
        pub fn loadSaveData(self: *Self, data: []const u8) void {
            self.system.loadSaveData(data);
        }

        // =========================================================
        // Headless mode
        // =========================================================

        /// Enable/disable graphics rendering
        pub fn setRenderGraphics(self: *Self, enabled: bool) void {
            self.system.render_graphics = enabled;
        }

        /// Enable/disable audio rendering
        pub fn setRenderAudio(self: *Self, enabled: bool) void {
            self.system.render_audio = enabled;
        }
    };
}
