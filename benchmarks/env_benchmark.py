#!/usr/bin/env python3
"""
Benchmark zgbc native environment vs PyBoy.

Usage:
    python benchmarks/env_benchmark.py roms/pokered.gb
"""

import argparse
import sys
import time
from pathlib import Path

DEFAULT_STEPS = 1000
FRAME_SKIP = 24  # Standard pokegym frame skip


def benchmark_native_env(rom_path: Path, steps: int = DEFAULT_STEPS) -> float | None:
    """Benchmark native zgbc PokemonRedEnv."""
    try:
        # Add local bindings path
        bindings_path = Path(__file__).parent.parent / "bindings" / "python" / "src"
        if bindings_path.exists():
            sys.path.insert(0, str(bindings_path))
        
        from zgbc.pokemon_env import PokemonRedEnv
    except ImportError as e:
        print(f"Native env not available: {e}")
        return None
    
    try:
        env = PokemonRedEnv(rom_path, frame_skip=FRAME_SKIP)
        obs, info = env.reset()
        
        start = time.perf_counter()
        for _ in range(steps):
            action = env.action_space.sample()
            obs, reward, term, trunc, info = env.step(action)
        elapsed = time.perf_counter() - start
        
        frames = steps * FRAME_SKIP
        return frames / elapsed
    except Exception as e:
        print(f"Native env error: {e}")
        import traceback
        traceback.print_exc()
        return None


def benchmark_pyboy(rom_path: Path, steps: int = DEFAULT_STEPS) -> float | None:
    """Benchmark PyBoy headless (for comparison)."""
    try:
        from pyboy import PyBoy
    except ImportError:
        print("PyBoy not installed (pip install pyboy)")
        return None
    
    try:
        pyboy = PyBoy(str(rom_path), window="null")
        pyboy.set_emulation_speed(0)
        
        frames = steps * FRAME_SKIP
        
        start = time.perf_counter()
        for _ in range(frames):
            pyboy.tick()
        elapsed = time.perf_counter() - start
        
        pyboy.stop()
        return frames / elapsed
    except Exception as e:
        print(f"PyBoy error: {e}")
        return None


def benchmark_raw_zgbc(rom_path: Path, steps: int = DEFAULT_STEPS) -> float | None:
    """Benchmark raw zgbc.GameBoy (no env overhead)."""
    try:
        bindings_path = Path(__file__).parent.parent / "bindings" / "python" / "src"
        if bindings_path.exists():
            sys.path.insert(0, str(bindings_path))
        
        from zgbc import GameBoy
    except ImportError as e:
        print(f"zgbc not available: {e}")
        return None
    
    try:
        gb = GameBoy(rom_path)
        gb.set_headless(graphics=True, audio=False)
        gb.skip_boot()
        
        frames = steps * FRAME_SKIP
        
        start = time.perf_counter()
        gb.run_frames(frames)
        elapsed = time.perf_counter() - start
        
        return frames / elapsed
    except Exception as e:
        print(f"Raw zgbc error: {e}")
        return None


def main():
    parser = argparse.ArgumentParser(description="Benchmark zgbc environments")
    parser.add_argument("rom", type=Path, help="Path to Pokemon Red ROM")
    parser.add_argument("--steps", type=int, default=DEFAULT_STEPS, help=f"Steps to run (default: {DEFAULT_STEPS})")
    args = parser.parse_args()
    
    steps = args.steps
    
    if not args.rom.exists():
        print(f"ROM not found: {args.rom}")
        sys.exit(1)
    
    total_frames = steps * FRAME_SKIP
    print(f"=== zgbc Environment Benchmark ===")
    print(f"ROM: {args.rom.name}")
    print(f"Steps: {steps:,} (frame_skip={FRAME_SKIP}, total frames: {total_frames:,})")
    print()
    
    print("Benchmarking PyBoy headless...")
    pyboy_fps = benchmark_pyboy(args.rom, steps)
    
    print("Benchmarking raw zgbc (PPU every frame)...")
    raw_fps = benchmark_raw_zgbc(args.rom, steps)
    
    print("Benchmarking native PokemonRedEnv...")
    native_fps = benchmark_native_env(args.rom, steps)
    
    print()
    print("=" * 55)
    print("Results (frames per second):")
    print("=" * 55)
    
    if pyboy_fps:
        print(f"  PyBoy headless:           {pyboy_fps:>10,.0f} FPS  (baseline)")
    
    if raw_fps:
        print(f"  Raw zgbc (PPU every):     {raw_fps:>10,.0f} FPS", end="")
        if pyboy_fps:
            print(f"  ({raw_fps/pyboy_fps:.1f}x PyBoy)")
        else:
            print()
    
    if native_fps:
        print(f"  Native PokemonRedEnv:     {native_fps:>10,.0f} FPS", end="")
        if pyboy_fps:
            print(f"  ({native_fps/pyboy_fps:.1f}x PyBoy)")
        else:
            print()
    
    if native_fps and pyboy_fps:
        print()
        print(f"  => zgbc native env is {native_fps/pyboy_fps:.1f}x faster than PyBoy for RL training")


if __name__ == "__main__":
    main()
