/*
 * zgbc - High-performance Game Boy emulator
 * C API header
 */

#ifndef ZGBC_H
#define ZGBC_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to a Game Boy instance */
typedef struct zgbc_t zgbc_t;

/* Save state size (call zgbc_save_state_size() for exact value) */
#define ZGBC_SAVE_STATE_SIZE 24760

/* Frame buffer dimensions */
#define ZGBC_SCREEN_WIDTH  160
#define ZGBC_SCREEN_HEIGHT 144
#define ZGBC_FRAME_PIXELS  (ZGBC_SCREEN_WIDTH * ZGBC_SCREEN_HEIGHT)

/* Audio sample rate */
#define ZGBC_SAMPLE_RATE 44100

/* Button bits for zgbc_set_input() */
#define ZGBC_BTN_A      (1 << 0)
#define ZGBC_BTN_B      (1 << 1)
#define ZGBC_BTN_SELECT (1 << 2)
#define ZGBC_BTN_START  (1 << 3)
#define ZGBC_BTN_RIGHT  (1 << 4)
#define ZGBC_BTN_LEFT   (1 << 5)
#define ZGBC_BTN_UP     (1 << 6)
#define ZGBC_BTN_DOWN   (1 << 7)

/* =========================================================
 * Lifecycle
 * ========================================================= */

/* Create a new Game Boy instance */
zgbc_t* zgbc_new(void);

/* Destroy a Game Boy instance */
void zgbc_free(zgbc_t* gb);

/* Load ROM data (copies internally) */
bool zgbc_load_rom(zgbc_t* gb, const uint8_t* data, size_t len);

/* =========================================================
 * Emulation
 * ========================================================= */

/* Run one frame (~70224 cycles) */
void zgbc_frame(zgbc_t* gb);

/* Run multiple frames (optimized batch execution) */
void zgbc_run_frames(zgbc_t* gb, size_t count);

/* Run one CPU step, returns cycles consumed */
uint8_t zgbc_step(zgbc_t* gb);

/* Set joypad input state (use ZGBC_BTN_* constants) */
void zgbc_set_input(zgbc_t* gb, uint8_t buttons);

/* =========================================================
 * Rendering control
 * ========================================================= */

/* Enable/disable graphics rendering (false for headless mode) */
void zgbc_set_render_graphics(zgbc_t* gb, bool enabled);

/* Enable/disable audio rendering (false for headless mode) */
void zgbc_set_render_audio(zgbc_t* gb, bool enabled);

/* =========================================================
 * Video output
 * ========================================================= */

/* Get pointer to frame buffer (160x144 2-bit color indices) */
const uint8_t* zgbc_get_frame_buffer(zgbc_t* gb);

/* Get RGBA frame buffer (converts 2-bit to RGBA, caller provides buffer) */
void zgbc_get_frame_rgba(zgbc_t* gb, uint32_t* out);

/* Get current scanline (0-153) */
uint8_t zgbc_get_ly(zgbc_t* gb);

/* =========================================================
 * Audio output
 * ========================================================= */

/* Read audio samples (stereo i16, 44100 Hz)
 * Returns number of samples read */
size_t zgbc_get_audio_samples(zgbc_t* gb, int16_t* out, size_t max_samples);

/* =========================================================
 * Memory access
 * ========================================================= */

/* Read a byte from memory */
uint8_t zgbc_read(zgbc_t* gb, uint16_t addr);

/* Write a byte to memory */
void zgbc_write(zgbc_t* gb, uint16_t addr, uint8_t val);

/* Get pointer to WRAM (8KB) */
const uint8_t* zgbc_get_wram(zgbc_t* gb);

/* Get WRAM size (always 8192) */
size_t zgbc_get_wram_size(void);

/* Copy full 64KB address space into buffer */
void zgbc_copy_memory(zgbc_t* gb, uint8_t* out, size_t len);

/* =========================================================
 * Battery saves (SRAM)
 * ========================================================= */

/* Get pointer to save RAM */
const uint8_t* zgbc_get_save_data(zgbc_t* gb);

/* Get save RAM size */
size_t zgbc_get_save_size(zgbc_t* gb);

/* Load save data */
void zgbc_load_save_data(zgbc_t* gb, const uint8_t* data, size_t len);

/* =========================================================
 * Save states
 * ========================================================= */

/* Get save state size */
size_t zgbc_save_state_size(void);

/* Create save state (caller provides buffer of zgbc_save_state_size() bytes) */
size_t zgbc_save_state(zgbc_t* gb, uint8_t* out);

/* Load save state */
void zgbc_load_state(zgbc_t* gb, const uint8_t* data);

/* =========================================================
 * State queries
 * ========================================================= */

/* Get total cycles elapsed */
uint64_t zgbc_get_cycles(zgbc_t* gb);

/* Check if CPU is halted */
bool zgbc_is_halted(zgbc_t* gb);

#ifdef __cplusplus
}
#endif

#endif /* ZGBC_H */
