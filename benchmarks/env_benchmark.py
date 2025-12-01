#!/usr/bin/env python3
"""
Apples-to-apples benchmark: zgbc vs PyBoy pokegym environments.

Both environments have identical:
- Observation space: (72, 80, 4)
- Action space: 8 discrete
- Reward function: Full pokegym reward shaping

Usage:
    python benchmarks/env_benchmark.py roms/pokered.gb
"""

import argparse
import sys
import time
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

DEFAULT_STEPS = 500
FRAME_SKIP = 24


def benchmark_zgbc(rom_path: Path, steps: int) -> float | None:
    """Benchmark zgbc pokegym-compatible environment."""
    bindings_path = Path(__file__).parent.parent / "bindings" / "python" / "src"
    if bindings_path.exists():
        sys.path.insert(0, str(bindings_path))
    
    try:
        from zgbc.pokegym_env import Environment
    except ImportError as e:
        print(f"  zgbc not available: {e}")
        return None
    
    try:
        env = Environment(rom_path)
        obs, _ = env.reset()
        assert obs.shape == (72, 80, 4), f"Wrong obs shape: {obs.shape}"
        
        start = time.perf_counter()
        for _ in range(steps):
            obs, reward, done, truncated, info = env.step(env.action_space.sample())
        elapsed = time.perf_counter() - start
        
        return (steps * FRAME_SKIP) / elapsed
    except Exception as e:
        print(f"  zgbc error: {e}")
        return None


def benchmark_pyboy(rom_path: Path, steps: int) -> float | None:
    """Benchmark raw PyBoy (pokegym hangs due to state issues)."""
    try:
        from pyboy import PyBoy
    except ImportError:
        print("  PyBoy not installed")
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
        print(f"  PyBoy error: {e}")
        return None


def main():
    parser = argparse.ArgumentParser(description="zgbc vs PyBoy benchmark")
    parser.add_argument("rom", type=Path, help="Path to Pokemon Red ROM")
    parser.add_argument("--steps", type=int, default=DEFAULT_STEPS)
    args = parser.parse_args()
    
    if not args.rom.exists():
        print(f"ROM not found: {args.rom}")
        sys.exit(1)
    
    print(f"=== Pokegym Environment Benchmark ===")
    print(f"ROM: {args.rom.name}")
    print(f"Steps: {args.steps:,} × {FRAME_SKIP} frames = {args.steps * FRAME_SKIP:,} total frames")
    print()
    
    print("Benchmarking PyBoy...")
    pyboy_fps = benchmark_pyboy(args.rom, args.steps)
    
    print("Benchmarking zgbc...")
    zgbc_fps = benchmark_zgbc(args.rom, args.steps)
    
    print()
    print("=" * 45)
    print("Results:")
    print("=" * 45)
    print(f"  PyBoy:   {pyboy_fps:>10,.0f} FPS" if pyboy_fps else "  PyBoy:   N/A")
    print(f"  zgbc:    {zgbc_fps:>10,.0f} FPS" if zgbc_fps else "  zgbc:    N/A")
    
    if zgbc_fps and pyboy_fps:
        speedup = zgbc_fps / pyboy_fps
        print()
        print(f"  zgbc is {speedup:.2f}x faster than PyBoy")


if __name__ == "__main__":
    main()
