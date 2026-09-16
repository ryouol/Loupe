"""Loupe MLX adapter: instrument mlx-lm runs and stream events to the app."""

from .adapter import DEFAULT_SOCKET_PATH, LoupeInstrument, __version__

__all__ = ["LoupeInstrument", "DEFAULT_SOCKET_PATH", "__version__"]
