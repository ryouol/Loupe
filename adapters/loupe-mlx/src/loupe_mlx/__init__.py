"""Loupe MLX adapter: instrument mlx-lm runs and stream events to the daemon."""

from .adapter import DEFAULT_SOCKET_PATH, LoupeInstrument

__version__ = "0.1.0"
__all__ = ["LoupeInstrument", "DEFAULT_SOCKET_PATH", "__version__"]
