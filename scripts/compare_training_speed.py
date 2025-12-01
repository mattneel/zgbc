#!/usr/bin/env python3
"""
Benchmark Pokegym step throughput for PyBoy vs the zgbc shim.

Example:

    python scripts/compare_training_speed.py --rom roms/pokered.gb --steps 300
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import sys
import time
from contextlib import contextmanager
from io import BytesIO
from pathlib import Path
from typing import Dict, Tuple
import shutil


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", type=Path, default=Path("roms/pokered.gb"), help="Path to the GB ROM.")
    parser.add_argument("--steps", type=int, default=300, help="Steps to measure per variant.")
    parser.add_argument("--warmup", type=int, default=30, help="Warm-up steps before timing.")
    parser.add_argument(
        "--state-name",
        type=str,
        default="Bulbasaur.state",
        help="State snapshot to load from pokegym/States.",
    )
    parser.add_argument("--zgbc-lib", type=Path, help="Override libzgbc path (sets ZGBC_LIB).")
    parser.add_argument("--verbose", action="store_true", help="Print extra details.")
    return parser.parse_args()


def clear_pokegym_modules() -> None:
    """Force pokegym to re-import so we can swap bindings."""

    for key in list(sys.modules):
        if key == "pokegym" or key.startswith("pokegym."):
            sys.modules.pop(key, None)


def get_state_dir() -> Path:
    spec = importlib.util.find_spec("pokegym")
    if spec is None or not spec.submodule_search_locations:
        raise RuntimeError("pokegym is not installed")
    return Path(next(iter(spec.submodule_search_locations))) / "States"


def ensure_states(target_dir: Path) -> Path:
    from zgbc.pokegym import ensure_state_pack

    return ensure_state_pack(target_dir)


def ensure_pyboy_state(state_path: Path, rom_path: Path, frames: int = 120) -> Path:
    """
    Generate a PyBoy-compatible .state file if one does not exist or can't be read.
    """

    try:
        if state_path.exists() and state_path.stat().st_size > 0:
            from pyboy import PyBoy

            temp = PyBoy(
                str(rom_path),
                window_type="headless",
                hide_window=True,
                quiet=True,
            )
            with open(state_path, "rb") as fh:
                temp.load_state(BytesIO(fh.read()))
            temp.stop(False)
            return state_path
    except Exception:
        # Fall back to regenerating below.
        pass

    from pyboy import PyBoy

    state_path.parent.mkdir(parents=True, exist_ok=True)
    pyboy = PyBoy(
        str(rom_path),
        window_type="headless",
        hide_window=True,
        quiet=True,
    )
    for _ in range(frames):
        pyboy.tick()
    buf = BytesIO()
    pyboy.save_state(buf)
    with open(state_path, "wb") as fh:
        fh.write(buf.getbuffer())
    pyboy.stop(False)
    return state_path


def run_benchmark(
    variant: str,
    rom_path: Path,
    steps: int,
    warmup: int,
    state_path: Path,
    verbose: bool,
) -> Tuple[float, float]:
    """
    Return (elapsed_seconds, steps_per_second).
    """

    clear_pokegym_modules()

    if variant == "zgbc":
        import zgbc.pokegym as shim

        shim.install(state_dest=state_path.parent, replace_existing=True)
    elif variant == "pyboy":
        # Nothing special: default pokegym binding uses PyBoy.
        pass
    else:
        raise ValueError(f"Unknown variant: {variant}")

    import pokegym.environment as penv

    env = penv.Environment(
        rom_path=str(rom_path),
        state_path=str(state_path),
        headless=True,
        save_video=False,
        quiet=True,
        verbose=False,
    )
    env.reset()

    # Warm-up to let the emulator settle.
    for i in range(warmup):
        env.step(i % env.action_space.n)

    start = time.perf_counter()
    for i in range(steps):
        env.step(i % env.action_space.n)
    elapsed = time.perf_counter() - start

    env.close()

    if verbose:
        print(f"[{variant}] elapsed={elapsed:.3f}s steps={steps}")

    return elapsed, steps / elapsed if elapsed > 0 else float("inf")


@contextmanager
def rom_alias(target: Path, alias_name: str = "pokemon_red.gb") -> Path:
    """
    Ensure pokegym's PyBoy binding can find the ROM at the hardcoded path.
    """

    alias = Path(alias_name).resolve()
    created = False
    if not alias.exists():
        try:
            alias.symlink_to(target)
        except OSError:
            shutil.copyfile(target, alias)
        created = True
    try:
        yield alias
    finally:
        if created and alias.exists():
            alias.unlink()


def main() -> None:
    args = parse_args()

    if args.zgbc_lib:
        os.environ["ZGBC_LIB"] = str(args.zgbc_lib.resolve())

    rom = args.rom.resolve()
    if not rom.exists():
        raise SystemExit(f"ROM not found: {rom}")

    state_root = get_state_dir()
    zgbc_state_dir = ensure_states(state_root)
    zgbc_state = zgbc_state_dir / args.state_name
    if not zgbc_state.exists():
        raise SystemExit(f"zgbc state file missing: {zgbc_state}")

    results: Dict[str, Tuple[float, float]] = {}

    with rom_alias(rom) as alias_path:
        pyboy_state = ensure_pyboy_state(state_root / "pyboy_benchmark.state", alias_path)
        for variant in ("pyboy", "zgbc"):
            state_path = pyboy_state if variant == "pyboy" else zgbc_state
            elapsed, throughput = run_benchmark(
                variant=variant,
                rom_path=alias_path,
                steps=args.steps,
                warmup=args.warmup,
                state_path=state_path,
                verbose=args.verbose,
            )
            results[variant] = (elapsed, throughput)

    py_elapsed, py_fps = results["pyboy"]
    z_elapsed, z_fps = results["zgbc"]
    speedup = z_fps / py_fps if py_fps else float("inf")

    print("\n=== Pokegym Step Throughput ===")
    print(f"PyBoy : {py_fps:8.2f} steps/sec (elapsed {py_elapsed:.2f}s)")
    print(f"zgbc  : {z_fps:8.2f} steps/sec (elapsed {z_elapsed:.2f}s)")
    print(f"Speedup (zgbc / PyBoy): {speedup:.2f}x")


if __name__ == "__main__":
    main()
