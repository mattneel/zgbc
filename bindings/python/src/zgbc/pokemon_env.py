"""
Native zgbc Pokemon Red environment for RL training.

No PyBoy compatibility layer - direct zgbc calls for maximum performance.

Usage:
    from zgbc.pokemon_env import PokemonRedEnv
    
    env = PokemonRedEnv("roms/pokered.gb", state_path="Bulbasaur.state")
    obs, info = env.reset()
    
    for _ in range(1000):
        action = env.action_space.sample()
        obs, reward, terminated, truncated, info = env.step(action)
"""

from __future__ import annotations

import ctypes
from pathlib import Path
from typing import Any, Optional

import numpy as np

try:
    import gymnasium as gym
    from gymnasium import spaces
except ImportError:
    import gym
    from gym import spaces

from . import GameBoy, Buttons, FRAME_WIDTH, FRAME_HEIGHT

__all__ = ["PokemonRedEnv", "ACTIONS"]

# Pokemon Red RAM addresses
PLAYER_X = 0xD362
PLAYER_Y = 0xD361
MAP_ID = 0xD35E
BADGES = 0xD356
PARTY_COUNT = 0xD163
PARTY_LEVEL_1 = 0xD18C
EVENT_FLAGS_START = 0xD747
EVENT_FLAGS_END = 0xD886

# Actions: indices into button masks
ACTIONS = [
    0,                    # 0: No-op
    Buttons.UP,           # 1: Up
    Buttons.DOWN,         # 2: Down
    Buttons.LEFT,         # 3: Left
    Buttons.RIGHT,        # 4: Right
    Buttons.A,            # 5: A
    Buttons.B,            # 6: B
    Buttons.START,        # 7: Start
    Buttons.SELECT,       # 8: Select
    Buttons.A | Buttons.UP,     # 9: A+Up
    Buttons.A | Buttons.DOWN,   # 10: A+Down
    Buttons.A | Buttons.LEFT,   # 11: A+Left
    Buttons.A | Buttons.RIGHT,  # 12: A+Right
]


class PokemonRedEnv(gym.Env):
    """
    Native zgbc Pokemon Red environment.
    
    Optimized for RL training:
    - PPU always enabled (need pixels for observations)
    - APU always disabled (no audio overhead)
    - Direct memory reads (no proxy objects)
    - Minimal frame buffer copies
    - Pre-allocated numpy arrays
    """
    
    metadata = {"render_modes": ["rgb_array", "human"], "render_fps": 60}
    
    def __init__(
        self,
        rom_path: str | Path,
        *,
        state_path: Optional[str | Path] = None,
        frame_skip: int = 24,
        render_mode: str = "rgb_array",
        max_steps: int = 0,  # 0 = unlimited
    ):
        super().__init__()
        
        self.rom_path = Path(rom_path)
        self.state_path = Path(state_path) if state_path else None
        self.frame_skip = frame_skip
        self.render_mode = render_mode
        self.max_steps = max_steps
        
        # Create emulator
        self._gb = GameBoy(self.rom_path)
        self._gb.set_headless(graphics=True, audio=False)
        self._gb.skip_boot()
        
        # Load initial state if provided
        self._initial_state: Optional[bytes] = None
        if self.state_path and self.state_path.exists():
            self._initial_state = self.state_path.read_bytes()
            self._gb.load_state(self._initial_state)
        
        # Pre-allocate frame buffer (reused every step)
        self._frame_rgba = np.zeros((FRAME_HEIGHT, FRAME_WIDTH, 4), dtype=np.uint8)
        self._frame_rgb = self._frame_rgba[:, :, :3]  # View, no copy
        
        # Spaces
        self.action_space = spaces.Discrete(len(ACTIONS))
        self.observation_space = spaces.Box(
            low=0, high=255,
            shape=(FRAME_HEIGHT, FRAME_WIDTH, 3),
            dtype=np.uint8
        )
        
        # State tracking
        self._step_count = 0
        self._prev_map = 0
        self._prev_x = 0
        self._prev_y = 0
        self._prev_badges = 0
        self._prev_party_level = 0
        self._visited_maps: set[int] = set()
        self._visited_coords: set[tuple[int, int, int]] = set()
    
    def reset(
        self,
        *,
        seed: Optional[int] = None,
        options: Optional[dict[str, Any]] = None,
    ) -> tuple[np.ndarray, dict[str, Any]]:
        super().reset(seed=seed)
        
        if self._initial_state:
            self._gb.load_state(self._initial_state)
        else:
            # Re-init from ROM
            self._gb = GameBoy(self.rom_path)
            self._gb.set_headless(graphics=True, audio=False)
            self._gb.skip_boot()
        
        self._step_count = 0
        self._visited_maps.clear()
        self._visited_coords.clear()
        
        # Capture initial state
        self._update_frame()
        self._prev_map = self._read(MAP_ID)
        self._prev_x = self._read(PLAYER_X)
        self._prev_y = self._read(PLAYER_Y)
        self._prev_badges = self._read(BADGES)
        self._prev_party_level = self._read(PARTY_LEVEL_1)
        
        self._visited_maps.add(self._prev_map)
        self._visited_coords.add((self._prev_map, self._prev_x, self._prev_y))
        
        return self._frame_rgb.copy(), self._get_info()
    
    def step(self, action: int) -> tuple[np.ndarray, float, bool, bool, dict[str, Any]]:
        buttons = ACTIONS[action]
        
        # Hold button for frame_skip frames, release, render final frame
        self._gb.set_input(buttons)
        if self.frame_skip > 1:
            self._gb.set_headless(graphics=False, audio=False)
            self._gb.run_frames(self.frame_skip - 1)
        self._gb.set_headless(graphics=True, audio=False)
        self._gb.frame()
        self._gb.set_input(0)
        
        self._step_count += 1
        
        # Get new state
        self._update_frame()
        cur_map = self._read(MAP_ID)
        cur_x = self._read(PLAYER_X)
        cur_y = self._read(PLAYER_Y)
        cur_badges = self._read(BADGES)
        cur_party_level = self._read(PARTY_LEVEL_1)
        
        # Reward calculation
        reward = 0.0
        
        # Exploration reward
        coord = (cur_map, cur_x, cur_y)
        if coord not in self._visited_coords:
            self._visited_coords.add(coord)
            reward += 0.01
        
        # New map discovery
        if cur_map not in self._visited_maps:
            self._visited_maps.add(cur_map)
            reward += 1.0
        
        # Badge reward
        new_badges = bin(cur_badges).count('1') - bin(self._prev_badges).count('1')
        if new_badges > 0:
            reward += 10.0 * new_badges
        
        # Level up reward
        if cur_party_level > self._prev_party_level:
            reward += 1.0
        
        # Update previous state
        self._prev_map = cur_map
        self._prev_x = cur_x
        self._prev_y = cur_y
        self._prev_badges = cur_badges
        self._prev_party_level = cur_party_level
        
        # Termination
        terminated = False
        truncated = self.max_steps > 0 and self._step_count >= self.max_steps
        
        return self._frame_rgb.copy(), reward, terminated, truncated, self._get_info()
    
    def render(self) -> Optional[np.ndarray]:
        if self.render_mode == "rgb_array":
            return self._frame_rgb.copy()
        return None
    
    def close(self):
        pass
    
    def save_state(self) -> bytes:
        """Save current emulator state."""
        return self._gb.save_state()
    
    def load_state(self, state: bytes) -> None:
        """Load emulator state."""
        self._gb.load_state(state)
    
    def _read(self, addr: int) -> int:
        """Direct memory read."""
        return self._gb.read(addr)
    
    def _update_frame(self) -> None:
        """Update frame buffer in-place."""
        rgba_bytes = self._gb.get_frame_rgba()
        np.copyto(
            self._frame_rgba.ravel(),
            np.frombuffer(rgba_bytes, dtype=np.uint8, count=FRAME_WIDTH * FRAME_HEIGHT * 4)
        )
    
    def _get_info(self) -> dict[str, Any]:
        return {
            "step": self._step_count,
            "map_id": self._prev_map,
            "player_x": self._prev_x,
            "player_y": self._prev_y,
            "badges": bin(self._prev_badges).count('1'),
            "party_level": self._prev_party_level,
            "visited_maps": len(self._visited_maps),
            "visited_coords": len(self._visited_coords),
        }


def make_env(
    rom_path: str | Path,
    state_path: Optional[str | Path] = None,
    **kwargs
) -> PokemonRedEnv:
    """Factory function for vectorized environments."""
    return PokemonRedEnv(rom_path, state_path=state_path, **kwargs)

