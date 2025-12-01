# zgbc Python Bindings

Python bindings for the zgbc Game Boy emulator.

## Installation

```bash
# Build zgbc first
cd /path/to/zgbc
zig build lib -Doptimize=ReleaseFast

# Install Python bindings
pip install -e bindings/python

# Set library path
export ZGBC_LIB=/path/to/zgbc/zig-out/lib/libzgbc.so
```

## Usage

```python
from zgbc import GameBoy

gb = GameBoy("pokemon_red.gb")
gb.skip_boot()

for _ in range(1000):
    gb.frame()
    screen = gb.get_frame_rgba()
```

## PufferLib / Pokegym

Drop-in replacement for pokegym:

```python
from pokegym import Environment  # Uses zgbc automatically

env = Environment("pokemon_red.gb")
obs, info = env.reset()
```

2.16x faster than PyBoy.

