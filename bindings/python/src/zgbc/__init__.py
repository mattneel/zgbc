"""
Idiomatic ctypes wrapper for libzgbc.

Usage:

    from pathlib import Path
    from zgbc import GameBoy, Buttons

    gb = GameBoy()
    gb.load_rom(Path("roms/pokered.gb").read_bytes())
    gb.skip_boot()

    while True:
        gb.set_input(Buttons.A | Buttons.START)
        gb.frame()
        frame_rgba = gb.get_frame_rgba()
        audio = gb.get_audio_samples()
        # ... feed into your renderer/audio device ...
"""

from __future__ import annotations

import ctypes
import os
import sys
from pathlib import Path
from typing import BinaryIO, Optional

__all__ = [
    "GameBoy",
    "Buttons",
    "FRAME_WIDTH",
    "FRAME_HEIGHT",
    "SAMPLE_RATE",
    "load_library",
    "PokemonRedEnv",
]


def __getattr__(name: str):
    """Lazy import for PokemonRedEnv to avoid numpy dependency at import time."""
    if name == "PokemonRedEnv":
        from .pokemon_env import PokemonRedEnv
        return PokemonRedEnv
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")

FRAME_WIDTH = 160
FRAME_HEIGHT = 144
SAMPLE_RATE = 44_100


class Buttons:
    A = 1 << 0
    B = 1 << 1
    SELECT = 1 << 2
    START = 1 << 3
    RIGHT = 1 << 4
    LEFT = 1 << 5
    UP = 1 << 6
    DOWN = 1 << 7


def _default_library_names() -> list[str]:
    if sys.platform.startswith("win"):
        return ["zgbc.dll"]
    if sys.platform == "darwin":
        return ["libzgbc.dylib", "zgbc.dylib"]
    return ["libzgbc.so"]


def load_library(path: Optional[os.PathLike[str] | str] = None) -> ctypes.CDLL:
    """
    Load libzgbc using ctypes.

    If *path* is None, tries LD_LIBRARY_PATH / PATH lookups with common names.
    """

    if path is not None:
        return ctypes.CDLL(os.fspath(path))

    env_path = os.environ.get("ZGBC_LIB")
    if env_path:
        return ctypes.CDLL(env_path)

    last_err: Optional[Exception] = None
    for name in _default_library_names():
        try:
            return ctypes.CDLL(name)
        except OSError as err:  # pragma: no cover - platform dependent
            last_err = err
    raise RuntimeError(
        "Unable to locate libzgbc; set ZGBC_LIB or pass path explicitly"
    ) from last_err


class GameBoy:
    """
    Thin OO wrapper around the C API.

    All heavy lifting stays in the native core; this class just helps loading ROMs,
    running frames, and fetching frame/audio buffers from Python.
    """

    def __init__(
        self,
        rom: Optional[bytes | os.PathLike[str] | str] = None,
        *,
        lib: Optional[ctypes.CDLL] = None,
    ) -> None:
        self._lib = lib or load_library()
        self._lib.zgbc_new.restype = ctypes.c_void_p
        self._lib.zgbc_free.argtypes = [ctypes.c_void_p]
        self._lib.zgbc_load_rom.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_uint8),
            ctypes.c_size_t,
        ]
        self._lib.zgbc_load_rom.restype = ctypes.c_bool
        self._lib.zgbc_frame.argtypes = [ctypes.c_void_p]
        self._lib.zgbc_run_frames.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        self._lib.zgbc_get_frame_rgba.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_uint32),
        ]
        self._lib.zgbc_get_audio_samples.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_int16),
            ctypes.c_size_t,
        ]
        self._lib.zgbc_get_audio_samples.restype = ctypes.c_size_t
        self._lib.zgbc_set_input.argtypes = [ctypes.c_void_p, ctypes.c_uint8]
        self._lib.zgbc_set_render_graphics.argtypes = [ctypes.c_void_p, ctypes.c_bool]
        self._lib.zgbc_set_render_audio.argtypes = [ctypes.c_void_p, ctypes.c_bool]
        self._lib.zgbc_read.argtypes = [ctypes.c_void_p, ctypes.c_uint16]
        self._lib.zgbc_read.restype = ctypes.c_uint8
        self._lib.zgbc_write.argtypes = [
            ctypes.c_void_p,
            ctypes.c_uint16,
            ctypes.c_uint8,
        ]
        self._lib.zgbc_save_state_size.restype = ctypes.c_size_t
        self._lib.zgbc_save_state.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_uint8),
        ]
        self._lib.zgbc_save_state.restype = ctypes.c_size_t
        self._lib.zgbc_load_state.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_uint8),
        ]
        self._lib.zgbc_load_state.restype = None
        self._lib.zgbc_copy_memory.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_uint8),
            ctypes.c_size_t,
        ]
        self._lib.zgbc_copy_memory.restype = None
        self._lib.zgbc_get_wram.argtypes = [ctypes.c_void_p]
        self._lib.zgbc_get_wram.restype = ctypes.POINTER(ctypes.c_uint8)
        self._lib.zgbc_get_wram_size.restype = ctypes.c_size_t

        self._state_size = self._lib.zgbc_save_state_size()
        self._frame_buf = (ctypes.c_uint32 * (FRAME_WIDTH * FRAME_HEIGHT))()
        self._frame_view = memoryview(self._frame_buf).cast("B")
        self._audio_buf = (ctypes.c_int16 * (SAMPLE_RATE // 10))()
        self._audio_view = memoryview(self._audio_buf)
        self._handle = self._lib.zgbc_new()
        if not self._handle:
            raise RuntimeError("zgbc_new() returned NULL")

        self._wram_size = self._lib.zgbc_get_wram_size()
        self._wram_ptr = ctypes.cast(
            self._lib.zgbc_get_wram(self._handle), ctypes.POINTER(ctypes.c_uint8)
        )

        self._rom_image: Optional[ctypes.Array[ctypes.c_uint8]] = None

        if rom is not None:
            self.load_rom(rom)

    def __del__(self) -> None:
        handle, self._handle = getattr(self, "_handle", None), None
        if handle:
            try:
                self._lib.zgbc_free(handle)
            except Exception:  # pragma: no cover - best effort cleanup
                pass

    def close(self) -> None:
        """Explicitly dispose of the emulator handle."""
        self.__del__()

    def __enter__(self) -> "GameBoy":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    # ------------------------------------------------------------------ lifecycle
    def load_rom(self, rom: bytes | os.PathLike[str] | str) -> None:
        data = Path(rom).read_bytes() if isinstance(rom, (str, os.PathLike)) else rom
        self._rom_image = (ctypes.c_uint8 * len(data)).from_buffer_copy(data)
        buf = self._rom_image
        if not self._lib.zgbc_load_rom(self._handle, buf, len(data)):
            raise RuntimeError("zgbc_load_rom() failed")

    def skip_boot(self) -> None:
        # Equivalent to toggling the boot ROM off
        self._lib.zgbc_write(self._handle, ctypes.c_uint16(0xFF50), ctypes.c_uint8(1))

    # ------------------------------------------------------------------ execution
    def frame(self) -> None:
        self._lib.zgbc_frame(self._handle)

    def run_frames(self, count: int) -> None:
        if count <= 0:
            return
        self._lib.zgbc_run_frames(self._handle, ctypes.c_size_t(count))

    def set_input(self, buttons: int) -> None:
        self._lib.zgbc_set_input(self._handle, ctypes.c_uint8(buttons & 0xFF))

    def set_headless(self, graphics: bool, audio: bool) -> None:
        self._lib.zgbc_set_render_graphics(self._handle, graphics)
        self._lib.zgbc_set_render_audio(self._handle, audio)

    # ------------------------------------------------------------------ outputs
    def get_frame_rgba(self) -> memoryview:
        self._lib.zgbc_get_frame_rgba(self._handle, self._frame_buf)
        return self._frame_view

    def get_audio_samples(self, max_samples: int = 2048) -> memoryview:
        max_samples = min(max_samples, len(self._audio_buf))
        count = self._lib.zgbc_get_audio_samples(
            self._handle, self._audio_buf, max_samples
        )
        return self._audio_view[: count]

    # ------------------------------------------------------------------ memory/state helpers
    def read(self, addr: int) -> int:
        """Read a byte from memory."""
        return int(self._lib.zgbc_read(self._handle, ctypes.c_uint16(addr & 0xFFFF)))

    def write(self, addr: int, value: int) -> None:
        """Write a byte into memory."""
        self._lib.zgbc_write(
            self._handle,
            ctypes.c_uint16(addr & 0xFFFF),
            ctypes.c_uint8(value & 0xFF),
        )

    def snapshot_memory(self) -> memoryview:
        """Copy the flat 64KB address space into a new buffer."""
        buf = (ctypes.c_uint8 * 0x10000)()
        self._lib.zgbc_copy_memory(self._handle, buf, ctypes.c_size_t(0x10000))
        return memoryview(buf)

    def read_wram(self, offset: int) -> int:
        return int(self._wram_ptr[offset])

    def save_state_size(self) -> int:
        return int(self._state_size)

    def save_state(self) -> bytes:
        """Return a raw save-state buffer."""
        buf = (ctypes.c_uint8 * self._state_size)()
        written = self._lib.zgbc_save_state(self._handle, buf)
        return bytes(memoryview(buf)[:written])

    def save_state_into(self, sink: BinaryIO) -> None:
        """Write a save state into a file-like object."""
        sink.seek(0)
        sink.write(self.save_state())
        sink.truncate()

    def load_state(self, data: bytes | bytearray | memoryview) -> None:
        """Restore emulator state from raw bytes."""
        if not data:
            raise ValueError("load_state() requires non-empty buffer")
        buf = (ctypes.c_uint8 * len(data)).from_buffer_copy(bytes(data))
        self._lib.zgbc_load_state(self._handle, buf)
