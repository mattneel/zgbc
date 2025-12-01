"""
Pokegym-compatible environment using zgbc.

Drop-in replacement for pokegym.environment.Environment with identical:
- Observation space: (72, 80, 4) - downscaled RGB + screen memory
- Action space: 8 discrete actions
- Reward function: Full pokegym reward shaping

Usage:
    from zgbc.pokegym_env import Environment
    env = Environment("pokemon_red.gb")
    obs, info = env.reset()
"""

from __future__ import annotations

import ctypes
from collections import defaultdict
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
from . import ram_map

__all__ = ["Environment", "ACTIONS"]

# 8 actions matching pokegym exactly
ACTIONS = [
    Buttons.DOWN,    # 0
    Buttons.LEFT,    # 1
    Buttons.RIGHT,   # 2
    Buttons.UP,      # 3
    Buttons.A,       # 4
    Buttons.B,       # 5
    Buttons.START,   # 6
    Buttons.SELECT,  # 7
]

# Map regions for exploration weighting
POKETOWER = {142, 143, 144, 145, 146, 147, 148}
POKEHIDEOUT = {199, 200, 201, 202, 203, 135}
SILPHCO = {181, 207, 208, 209, 210, 211, 212, 213, 233, 234, 235, 236}


class Environment(gym.Env):
    """
    Pokegym-compatible Pokemon Red environment.
    
    Identical to pokegym.environment.Environment but using zgbc backend.
    """
    
    metadata = {"render_modes": ["rgb_array", "human"], "render_fps": 60}
    
    def __init__(
        self,
        rom_path: str | Path = "pokemon_red.gb",
        state_path: Optional[str | Path] = None,
        headless: bool = True,
        save_video: bool = False,
        quiet: bool = False,
        **kwargs,
    ):
        super().__init__()
        
        self.rom_path = Path(rom_path)
        if not self.rom_path.exists():
            raise FileNotFoundError(f"ROM not found: {rom_path}")
        
        # Create emulator
        self._gb = GameBoy(self.rom_path)
        self._gb.set_headless(graphics=True, audio=False)
        self._gb.skip_boot()
        
        # Load state if provided
        self._initial_state: Optional[bytes] = None
        if state_path:
            state_path = Path(state_path)
            if state_path.exists():
                self._initial_state = state_path.read_bytes()
                self._gb.load_state(self._initial_state)
        
        # Pre-allocate buffers
        self._ram_buf = (ctypes.c_uint8 * 0x10000)()
        self._ram = np.frombuffer(self._ram_buf, dtype=np.uint8)
        self._frame_rgba = np.zeros((FRAME_HEIGHT, FRAME_WIDTH, 4), dtype=np.uint8)
        
        # Screen memory (visited tiles per map)
        self._screen_memory: dict[int, np.ndarray] = defaultdict(
            lambda: np.zeros((255, 255, 1), dtype=np.uint8)
        )
        
        # Observation: (72, 80, 4) - downscaled RGB + screen memory channel
        self.observation_space = spaces.Box(
            low=0, high=255, dtype=np.uint8, shape=(72, 80, 4)
        )
        self.action_space = spaces.Discrete(len(ACTIONS))
        
        # Episode state
        self._reset_state()
    
    def _reset_state(self):
        """Reset episode-specific state."""
        self.time = 0
        self.max_episode_steps = 20480
        self.reward_scale = 4.0
        self.last_reward = None
        
        self.max_level_sum = 0
        self.seen_coords: set[tuple[int, int, int]] = set()
        self.seen_maps: set[int] = set()
        self.total_healing = 0.0
        self.last_hp = 1.0
        self.last_party_size = 1
        self.death_count = 0
        self.is_dead = False
        self.cut = 0
        self.used_cut = 0
        self.hm_count = 0
        
        self.seen_pokemon = np.zeros(152, dtype=np.uint8)
        self.caught_pokemon = np.zeros(152, dtype=np.uint8)
        self.moves_obtained: dict[int, int] = {}
        
        self.seen_start_menu = 0
        self.seen_pokemon_menu = 0
        self.seen_stats_menu = 0
        self.seen_bag_menu = 0
        
        self._screen_memory.clear()
    
    def reset(self, seed=None, options=None, max_episode_steps=20480, reward_scale=4.0):
        if hasattr(super(), 'reset'):
            super().reset(seed=seed)
        
        if self._initial_state:
            self._gb.load_state(self._initial_state)
        
        self._reset_state()
        self.max_episode_steps = max_episode_steps
        self.reward_scale = reward_scale
        
        self._snapshot()
        return self._render_obs(), {}
    
    def step(self, action: int):
        buttons = ACTIONS[action]
        
        # Hold button, run frames, release
        self._gb.set_input(buttons)
        self._gb.set_headless(graphics=False, audio=False)
        self._gb.run_frames(23)  # 24 frame skip total
        self._gb.set_headless(graphics=True, audio=False)
        self._gb.frame()
        self._gb.set_input(0)
        
        self.time += 1
        self._snapshot()
        
        # Calculate reward
        reward = self._compute_reward()
        
        done = self.time >= self.max_episode_steps
        return self._render_obs(), reward, done, done, self._get_info() if done else {}
    
    def _snapshot(self):
        """Snapshot RAM and frame."""
        self._gb.snapshot_memory_into(self._ram_buf)
        rgba = self._gb.get_frame_rgba()
        np.copyto(
            self._frame_rgba.ravel(),
            np.frombuffer(rgba, dtype=np.uint8, count=FRAME_WIDTH * FRAME_HEIGHT * 4)
        )
    
    def _render_obs(self) -> np.ndarray:
        """Render observation: downscaled RGB + screen memory."""
        r, c, map_n = ram_map.position(self._ram)
        
        # Update screen memory
        mmap = self._screen_memory[map_n]
        if 0 <= r <= 254 and 0 <= c <= 254:
            mmap[r, c] = 255
        
        # Downsample frame (144x160 -> 72x80)
        rgb = self._frame_rgba[::2, ::2, :3]
        
        # Get fixed window from screen memory
        window = self._get_fixed_window(mmap, r, c, (72, 80))
        
        # Concatenate RGB + screen memory
        return np.concatenate([rgb, window], axis=2)
    
    def _get_fixed_window(self, arr: np.ndarray, y: int, x: int, size: tuple[int, int]) -> np.ndarray:
        """Get fixed-size window centered on (y, x)."""
        h, w = arr.shape[:2]
        h_w, w_w = size[0] // 2, size[1] // 2
        
        y_min, y_max = max(0, y - h_w), min(h, y + h_w + (size[0] % 2))
        x_min, x_max = max(0, x - w_w), min(w, x + w_w + (size[1] % 2))
        
        window = arr[y_min:y_max, x_min:x_max]
        
        pad_top = h_w - (y - y_min)
        pad_bottom = h_w + (size[0] % 2) - 1 - (y_max - y - 1)
        pad_left = w_w - (x - x_min)
        pad_right = w_w + (size[1] % 2) - 1 - (x_max - x - 1)
        
        return np.pad(window, ((pad_top, pad_bottom), (pad_left, pad_right), (0, 0)), mode="constant")
    
    def _compute_reward(self) -> float:
        """Compute pokegym-compatible reward."""
        ram = self._ram
        
        # Position and exploration
        r, c, map_n = ram_map.position(ram)
        self.seen_coords.add((r, c, map_n))
        
        # Exploration reward with region weighting
        hideout_done = ram_map.read_bit(ram, 0xD81B, 7)
        tower_done = ram_map.read_bit(ram, 0xD7E0, 7)
        flute_gotten = ram_map.read_bit(ram, 0xD76C, 0)
        silph_done = ram_map.read_bit(ram, 0xD838, 7)
        
        if not hideout_done:
            if map_n in POKETOWER:
                exploration_reward = 0
            elif map_n in POKEHIDEOUT:
                exploration_reward = 0.03 * len(self.seen_coords)
            else:
                exploration_reward = 0.02 * len(self.seen_coords)
        elif not tower_done:
            if map_n in POKETOWER:
                exploration_reward = 0.03 * len(self.seen_coords)
            else:
                exploration_reward = 0.02 * len(self.seen_coords)
        elif not flute_gotten:
            exploration_reward = 0.02 * len(self.seen_coords)
        elif not silph_done:
            if map_n in SILPHCO:
                exploration_reward = 0.03 * len(self.seen_coords)
            else:
                exploration_reward = 0.02 * len(self.seen_coords)
        else:
            exploration_reward = 0.02 * len(self.seen_coords)
        
        # Level reward
        party_size, party_levels = ram_map.party(ram)
        level_sum = sum(party_levels)
        self.max_level_sum = max(self.max_level_sum, level_sum)
        level_reward = min(15, self.max_level_sum) + max(0, self.max_level_sum - 15) / 4
        
        # HP and healing
        hp = ram_map.hp(ram)
        hp_delta = hp - self.last_hp
        if hp_delta > 0.5 and party_size == self.last_party_size and not self.is_dead:
            self.total_healing += hp_delta
        if hp <= 0 and self.last_hp > 0:
            self.death_count += 1
            self.is_dead = True
        elif hp > 0.01:
            self.is_dead = False
        self.last_hp = hp
        self.last_party_size = party_size
        healing_reward = self.total_healing
        
        # HM count
        hm = ram_map.get_hm_count(ram)
        if hm >= 1 and self.hm_count == 0:
            self.hm_count = 1
        
        # Check for Cut learned
        if ram_map.read_bit(ram, 0xD803, 0):
            self.cut = 1
        cut_rew = self.cut * 10
        
        # Update pokedex
        for i in range(19):  # 0xD30A - 0xD2F7 = 19 bytes
            caught = int(ram[0xD2F7 + i])
            seen = int(ram[0xD30A + i])
            for j in range(8):
                idx = 8 * i + j
                if idx < 152:
                    self.caught_pokemon[idx] = 1 if caught & (1 << j) else 0
                    self.seen_pokemon[idx] = 1 if seen & (1 << j) else 0
        
        # Update moves
        for base in [0xD16B, 0xD197, 0xD1C3, 0xD1EF, 0xD21B, 0xD247]:
            if ram[base] != 0:
                for j in range(4):
                    move_id = int(ram[base + j + 8])
                    if move_id != 0:
                        self.moves_obtained[move_id] = 1
        
        # Event rewards
        event_reward = ram_map.all_events(ram)
        
        seen_pokemon_reward = self.reward_scale * sum(self.seen_pokemon)
        caught_pokemon_reward = self.reward_scale * sum(self.caught_pokemon)
        moves_obtained_reward = self.reward_scale * len(self.moves_obtained)
        
        reward = self.reward_scale * (
            level_reward +
            healing_reward +
            exploration_reward +
            cut_rew +
            event_reward +
            seen_pokemon_reward +
            caught_pokemon_reward +
            moves_obtained_reward
        )
        
        # Delta reward
        if self.last_reward is None:
            self.last_reward = reward
            return 0.0
        
        delta = reward - self.last_reward
        self.last_reward = reward
        return delta
    
    def _get_info(self) -> dict[str, Any]:
        """Get episode info (only returned on done)."""
        return {
            "badges": ram_map.badges(self._ram),
            "party_size": self.last_party_size,
            "max_level_sum": self.max_level_sum,
            "deaths": self.death_count,
            "seen_coords": len(self.seen_coords),
            "moves_obtained": len(self.moves_obtained),
        }
    
    def render(self):
        return self._render_obs()
    
    def close(self):
        pass

