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
from pathlib import Path

DEFAULT_STEPS = 1000
FRAME_SKIP = 24


def benchmark_zgbc_pokegym(rom_path: Path, steps: int) -> float | None:
    """Benchmark zgbc pokegym-compatible environment."""
    try:
        bindings_path = Path(__file__).parent.parent / "bindings" / "python" / "src"
        if bindings_path.exists():
            sys.path.insert(0, str(bindings_path))
        
        from zgbc.pokegym_env import Environment
    except ImportError as e:
        print(f"zgbc pokegym env not available: {e}")
        import traceback
        traceback.print_exc()
        return None
    
    try:
        env = Environment(rom_path)
        obs, info = env.reset()
        
        # Verify observation shape
        assert obs.shape == (72, 80, 4), f"Wrong obs shape: {obs.shape}"
        
        start = time.perf_counter()
        for _ in range(steps):
            action = env.action_space.sample()
            obs, reward, term, trunc, info = env.step(action)
        elapsed = time.perf_counter() - start
        
        return (steps * FRAME_SKIP) / elapsed
    except Exception as e:
        print(f"zgbc error: {e}")
        import traceback
        traceback.print_exc()
        return None


def benchmark_pyboy_pokegym(rom_path: Path, steps: int) -> float | None:
    """Benchmark original pokegym with PyBoy."""
    try:
        from pokegym.environment import Environment
    except ImportError:
        print("pokegym not installed (pip install pokegym)")
        return None
    
    try:
        env = Environment(str(rom_path), headless=True, quiet=True)
        obs, info = env.reset()
        
        # Verify observation shape
        assert obs.shape == (72, 80, 4), f"Wrong obs shape: {obs.shape}"
        
        start = time.perf_counter()
        for _ in range(steps):
            action = env.action_space.sample()
            obs, reward, term, trunc, info = env.step(action)
        elapsed = time.perf_counter() - start
        
        return (steps * FRAME_SKIP) / elapsed
    except Exception as e:
        print(f"pokegym error: {e}")
        import traceback
        traceback.print_exc()
        return None


def main():
    parser = argparse.ArgumentParser(description="Apples-to-apples pokegym benchmark")
    parser.add_argument("rom", type=Path, help="Path to Pokemon Red ROM")
    parser.add_argument("--steps", type=int, default=DEFAULT_STEPS)
    args = parser.parse_args()
    
    if not args.rom.exists():
        print(f"ROM not found: {args.rom}")
        sys.exit(1)
    
    print(f"=== Pokegym Environment Benchmark (Apples-to-Apples) ===")
    print(f"ROM: {args.rom.name}")
    print(f"Steps: {args.steps:,} (frame_skip={FRAME_SKIP})")
    print(f"Obs space: (72, 80, 4), Actions: 8")
    print(f"Reward: Full pokegym reward shaping")
    print()
    
    print("Benchmarking PyBoy + pokegym...")
    pyboy_fps = benchmark_pyboy_pokegym(args.rom, args.steps)
    
    print("Benchmarking zgbc + pokegym-compat...")
    zgbc_fps = benchmark_zgbc_pokegym(args.rom, args.steps)
    
    print()
    print("=" * 50)
    print("Results:")
    print("=" * 50)
    
    if pyboy_fps:
        print(f"  PyBoy + pokegym:   {pyboy_fps:>10,.0f} FPS")
    else:
        print(f"  PyBoy + pokegym:   N/A")
    
    if zgbc_fps:
        print(f"  zgbc + pokegym:    {zgbc_fps:>10,.0f} FPS")
    else:
        print(f"  zgbc + pokegym:    N/A")
    
    if zgbc_fps and pyboy_fps:
        speedup = zgbc_fps / pyboy_fps
        print()
        print(f"  zgbc is {speedup:.2f}x faster than PyBoy")
        print()
        print(f"  Training time reduction: {(1 - 1/speedup) * 100:.0f}%")


if __name__ == "__main__":
    main()
