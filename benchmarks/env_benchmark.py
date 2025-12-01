#!/usr/bin/env python3
"""
Benchmark zgbc PokemonRedEnv vs PyBoy pokegym for RL training.

Usage:
    python benchmarks/env_benchmark.py roms/pokered.gb
"""

import argparse
import sys
import time
from pathlib import Path

DEFAULT_STEPS = 1000
FRAME_SKIP = 24  # Standard pokegym frame skip


def benchmark_zgbc_env(rom_path: Path, steps: int) -> float | None:
    """Benchmark zgbc PokemonRedEnv."""
    try:
        bindings_path = Path(__file__).parent.parent / "bindings" / "python" / "src"
        if bindings_path.exists():
            sys.path.insert(0, str(bindings_path))
        
        from zgbc.pokemon_env import PokemonRedEnv
    except ImportError as e:
        print(f"zgbc not available: {e}")
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
        print(f"zgbc error: {e}")
        import traceback
        traceback.print_exc()
        return None


def benchmark_pyboy(rom_path: Path, steps: int) -> float | None:
    """Benchmark PyBoy headless."""
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


def main():
    parser = argparse.ArgumentParser(description="Benchmark zgbc vs PyBoy for RL training")
    parser.add_argument("rom", type=Path, help="Path to Pokemon Red ROM")
    parser.add_argument("--steps", type=int, default=DEFAULT_STEPS, help=f"Steps to run (default: {DEFAULT_STEPS})")
    args = parser.parse_args()
    
    if not args.rom.exists():
        print(f"ROM not found: {args.rom}")
        sys.exit(1)
    
    total_frames = args.steps * FRAME_SKIP
    print(f"=== RL Environment Benchmark ===")
    print(f"ROM: {args.rom.name}")
    print(f"Steps: {args.steps:,} (frame_skip={FRAME_SKIP}, total frames: {total_frames:,})")
    print()
    
    print("Benchmarking PyBoy...")
    pyboy_fps = benchmark_pyboy(args.rom, args.steps)
    
    print("Benchmarking zgbc...")
    zgbc_fps = benchmark_zgbc_env(args.rom, args.steps)
    
    print()
    print("=" * 50)
    print("Results:")
    print("=" * 50)
    
    if pyboy_fps:
        print(f"  PyBoy:   {pyboy_fps:>10,.0f} FPS")
    else:
        print(f"  PyBoy:   N/A")
    
    if zgbc_fps:
        print(f"  zgbc:    {zgbc_fps:>10,.0f} FPS")
    else:
        print(f"  zgbc:    N/A")
    
    if zgbc_fps and pyboy_fps:
        print()
        print(f"  zgbc is {zgbc_fps/pyboy_fps:.1f}x faster than PyBoy")


if __name__ == "__main__":
    main()
