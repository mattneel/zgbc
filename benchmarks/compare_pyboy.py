#!/usr/bin/env python3
"""
Compare zgbc vs PyBoy performance for RL training workloads.

This benchmark measures PPU-only mode (graphics enabled, audio disabled)
which is the configuration used for RL training where pixel observations
are needed but audio is not.

Usage:
    python benchmarks/compare_pyboy.py roms/pokered.gb

Requirements:
    pip install pyboy
    ZGBC_LIB environment variable or libzgbc.so in path
"""

import argparse
import sys
import time
from pathlib import Path

DEFAULT_FRAMES = 10_000
WARMUP_FRAMES = 1_000


def benchmark_pyboy(rom_path: Path, frames: int = DEFAULT_FRAMES) -> float | None:
    """Run PyBoy in headless mode, return FPS or None if unavailable."""
    try:
        from pyboy import PyBoy
    except ImportError:
        print("PyBoy not installed. Run: pip install pyboy")
        return None

    # PyBoy headless mode (no window, but still renders screen)
    pyboy = PyBoy(str(rom_path), window="null")
    pyboy.set_emulation_speed(0)  # Uncapped speed

    # Warmup
    for _ in range(WARMUP_FRAMES):
        pyboy.tick()

    # Benchmark
    start = time.perf_counter()
    for _ in range(frames):
        pyboy.tick()
    elapsed = time.perf_counter() - start

    pyboy.stop()

    return frames / elapsed


def benchmark_zgbc(rom_path: Path, frames: int = DEFAULT_FRAMES) -> float | None:
    """Run zgbc in PPU-only mode (RL training config), return FPS."""
    # Try to import from installed package or local path
    try:
        from zgbc import GameBoy
    except ImportError:
        # Try adding local bindings path
        bindings_path = Path(__file__).parent.parent / "bindings" / "python" / "src"
        if bindings_path.exists():
            sys.path.insert(0, str(bindings_path))
            try:
                from zgbc import GameBoy
            except ImportError as e:
                print(f"zgbc bindings not available: {e}")
                print("Build with: zig build lib -Doptimize=ReleaseFast")
                print("Then set ZGBC_LIB=/path/to/libzgbc.so")
                return None
        else:
            print("zgbc bindings not found")
            return None

    try:
        gb = GameBoy(rom_path)
        gb.skip_boot()

        # PPU-only mode: graphics=True (for pixel obs), audio=False
        gb.set_headless(graphics=True, audio=False)

        # Warmup
        gb.run_frames(WARMUP_FRAMES)

        # Benchmark
        start = time.perf_counter()
        gb.run_frames(frames)
        elapsed = time.perf_counter() - start

        return frames / elapsed
    except Exception as e:
        print(f"zgbc error: {e}")
        return None


def main():
    parser = argparse.ArgumentParser(
        description="Compare zgbc vs PyBoy emulation performance"
    )
    parser.add_argument("rom", type=Path, help="Path to Game Boy ROM file")
    parser.add_argument(
        "--frames", type=int, default=DEFAULT_FRAMES,
        help=f"Frames to benchmark (default: {DEFAULT_FRAMES})"
    )
    args = parser.parse_args()

    frames = args.frames

    if not args.rom.exists():
        print(f"ROM not found: {args.rom}")
        sys.exit(1)

    print(f"=== RL Training Benchmark ({frames:,} frames) ===")
    print(f"ROM: {args.rom.name}")
    print(f"Mode: PPU-only (graphics=True, audio=False)")
    print()

    # Run benchmarks
    print("Benchmarking PyBoy...")
    pyboy_fps = benchmark_pyboy(args.rom, frames)

    print("Benchmarking zgbc...")
    zgbc_fps = benchmark_zgbc(args.rom, frames)

    # Results
    print()
    print("=" * 50)
    print("Results (PPU-only / RL training mode):")
    print("=" * 50)

    if pyboy_fps is not None:
        print(f"  PyBoy:  {pyboy_fps:>8,.0f} FPS")
    else:
        print("  PyBoy:  N/A")

    if zgbc_fps is not None:
        print(f"  zgbc:   {zgbc_fps:>8,.0f} FPS")
    else:
        print("  zgbc:   N/A")

    if pyboy_fps is not None and zgbc_fps is not None:
        speedup = zgbc_fps / pyboy_fps
        print()
        if speedup >= 1:
            print(f"  zgbc is {speedup:.2f}x faster than PyBoy")
        else:
            print(f"  PyBoy is {1/speedup:.2f}x faster than zgbc")

    print()
    print("Note: Target is ~6000 FPS to match/beat PyBoy for PufferLib")


if __name__ == "__main__":
    main()

