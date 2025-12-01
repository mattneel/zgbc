"""
Drop-in replacement for pokegym.pyboy_binding backed by libzgbc.

Import this module and call ``install()`` before importing
``pokegym.environment`` to transparently replace the original PyBoy binding:

    import zgbc.pokegym as zpoke
    zpoke.install()

    from pokegym.environment import Environment
"""

from __future__ import annotations

from io import BytesIO
import importlib.util
import shutil
import sys
from pathlib import Path
from typing import Iterable, Sequence

import numpy as np

from . import Buttons, FRAME_HEIGHT, FRAME_WIDTH, GameBoy

__all__ = [
    "ACTIONS",
    "make_env",
    "open_state_file",
    "load_pyboy_state",
    "run_action_on_emulator",
    "ensure_state_pack",
    "install",
]


class Down:
    PRESS = Buttons.DOWN
    RELEASE = 0


class Left:
    PRESS = Buttons.LEFT
    RELEASE = 0


class Right:
    PRESS = Buttons.RIGHT
    RELEASE = 0


class Up:
    PRESS = Buttons.UP
    RELEASE = 0


class A:
    PRESS = Buttons.A
    RELEASE = 0


class B:
    PRESS = Buttons.B
    RELEASE = 0


class Start:
    PRESS = Buttons.START
    RELEASE = 0


class Select:
    PRESS = Buttons.SELECT
    RELEASE = 0


class Cut:
    PRESS = Buttons.START
    RELEASE = 0


ACTIONS: Sequence[type] = (Down, Left, Right, Up, A, B, Start, Select)


class MemoryProxy:
    def __init__(self, gb: GameBoy) -> None:
        self.gb = gb
        self.read_byte = gb.read_wram

    def read(self, addr: int) -> int:
        if 0xC000 <= addr <= 0xDFFF:
            return self.read_byte(addr - 0xC000)
        if 0xE000 <= addr <= 0xFDFF:
            return self.read_byte(addr - 0xE000)
        return self.gb.read(addr)

    def write(self, addr: int, value: int) -> None:
        self.gb.write(addr, value)


class PokegymGame:
    """Adapter object that exposes the subset of the PyBoy API Pokegym needs."""

    def __init__(self, rom_path: Path, *, skip_boot: bool = True) -> None:
        self.gb = GameBoy(rom_path)
        self.gb.set_headless(graphics=True, audio=False)
        if skip_boot:
            self.gb.skip_boot()
        self.mem = MemoryProxy(self.gb)

    def frame(self) -> None:
        self.gb.frame()

    def set_input(self, buttons: int) -> None:
        self.gb.set_input(buttons)

    def run_frames(self, count: int, *, render_final: bool) -> None:
        if count <= 0:
            return
        if render_final:
            if count > 1:
                self.gb.set_headless(graphics=False, audio=False)
                self.gb.run_frames(count - 1)
            self.gb.set_headless(graphics=True, audio=False)
            self.gb.frame()
        else:
            self.gb.set_headless(graphics=False, audio=False)
            self.gb.run_frames(count)

    def save_state(self, sink: BytesIO) -> BytesIO:
        self.gb.save_state_into(sink)
        return sink

    def load_state(self, state: BytesIO | bytes | bytearray | memoryview) -> None:
        if hasattr(state, "read"):
            state.seek(0)
            data = state.read()
        else:
            data = bytes(state)
        self.gb.load_state(data)
    def get_memory_value(self, addr: int) -> int:
        return self.mem.read(addr)

    def set_memory_value(self, addr: int, value: int) -> None:
        self.mem.write(addr, value)

    def stop(self, *_args, **_kwargs) -> None:
        self.gb.set_input(0)


class ScreenProxy:
    """Mimics the PyBoy bot-support screen helper."""

    def __init__(self) -> None:
        self._frame = np.zeros((FRAME_HEIGHT, FRAME_WIDTH, 3), dtype=np.uint8)

    def raw_screen_buffer_dims(self) -> tuple[int, int]:
        return FRAME_HEIGHT, FRAME_WIDTH

    def screen_ndarray(self) -> np.ndarray:
        return self._frame

    def capture(self, game: PokegymGame) -> None:
        rgba = np.frombuffer(
            game.gb.get_frame_rgba(), dtype=np.uint8, count=FRAME_WIDTH * FRAME_HEIGHT * 4
        ).reshape((FRAME_HEIGHT, FRAME_WIDTH, 4))
        self._frame = rgba[..., :3]


def make_env(
    gb_path: str | Path,
    headless: bool = True,
    quiet: bool = False,
    save_video: bool = False,
    **kwargs,
):
    """Instantiate the emulator and screen view."""

    del headless, quiet, save_video  # compatibility placeholders

    rom_path = Path(gb_path)
    if not rom_path.exists():
        raise FileNotFoundError(f"ROM not found: {rom_path}")

    skip_boot = kwargs.pop("skip_boot", True)
    game = PokegymGame(rom_path, skip_boot=skip_boot)
    screen = ScreenProxy()
    screen.capture(game)
    return game, screen


def open_state_file(path: str | Path) -> BytesIO:
    """Read a state file into memory (mirrors the PyBoy helper)."""

    return BytesIO(Path(path).read_bytes())


def load_pyboy_state(game: PokegymGame, state: BytesIO) -> None:
    """Reset the BytesIO cursor and load it into the emulator."""

    state.seek(0)
    game.load_state(state)


def run_action_on_emulator(
    game: PokegymGame,
    screen: ScreenProxy,
    action,
    headless: bool = True,
    fast_video: bool = True,
    frame_skip: int = 24,
) -> None:
    """Send a button press to the emulator and advance a few frames."""

    del headless, fast_video  # compatibility placeholders

    if action is Cut:
        _cut_sequence(game, frame_skip)
    else:
        _press(game, action.PRESS, frame_skip)

    screen.capture(game)


def _press(game: PokegymGame, buttons: int, frame_skip: int, release_after: int = 8) -> None:
    if frame_skip <= 0:
        return
    release_after = max(0, min(release_after, frame_skip))
    hold_frames = release_after if release_after > 0 else frame_skip
    hold_frames = min(hold_frames, frame_skip)
    tail_frames = frame_skip - hold_frames

    game.set_input(buttons)
    if hold_frames > 0:
        game.run_frames(hold_frames, render_final=(tail_frames == 0))

    if tail_frames > 0:
        game.set_input(0)
        game.run_frames(tail_frames, render_final=True)
    else:
        game.set_input(0)


def _cut_sequence(game: PokegymGame, frame_skip: int) -> None:
    sequence: Iterable[int] = (
        Buttons.START,
        Buttons.DOWN,
        Buttons.A,
        Buttons.A,
        Buttons.A,
    )
    for buttons in sequence:
        _press(game, buttons, frame_skip)


_STATE_PACK = Path(__file__).with_name("statepack")


def ensure_state_pack(target: str | Path | None = None) -> Path:
    """Ensure the Pokegym installation has at least one state file."""

    source = _STATE_PACK
    if not source.exists():
        raise FileNotFoundError(f"Bundled state pack missing: {source}")

    if target is None:
        target = _default_state_path()
    else:
        target = Path(target)

    target.mkdir(parents=True, exist_ok=True)
    for state_file in source.glob("*.state"):
        dest = target / state_file.name
        if not dest.exists():
            shutil.copyfile(state_file, dest)
    return target


def _default_state_path() -> Path:
    spec = importlib.util.find_spec("pokegym")
    if spec is None or not spec.submodule_search_locations:
        raise RuntimeError("pokegym is not installed")
    root = Path(next(iter(spec.submodule_search_locations)))
    return root / "States"


def install(*, state_dest: str | Path | None = None, replace_existing: bool = False) -> None:
    """
    Register this module under ``pokegym.pyboy_binding`` and install the state pack.
    """

    ensure_state_pack(state_dest)
    module_name = "pokegym.pyboy_binding"
    if not replace_existing and module_name in sys.modules:
        raise RuntimeError(
            "pokegym.pyboy_binding is already imported; import zgbc.pokegym before pokegym"
        )
    sys.modules[module_name] = sys.modules[__name__]
