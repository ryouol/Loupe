from loupe_mlx import DEFAULT_SOCKET_PATH, LoupeInstrument, __version__


def test_package_surface() -> None:
    assert __version__ == "0.1.0"
    assert DEFAULT_SOCKET_PATH.endswith(".sock")
    assert LoupeInstrument is not None
