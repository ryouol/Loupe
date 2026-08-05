import time

from loupe_mlx.timebase import now_ns


def test_now_ns_is_positive_and_monotonic() -> None:
    readings = [now_ns() for _ in range(1000)]
    assert readings[0] > 0
    assert readings == sorted(readings)


def test_now_ns_tracks_wall_time_roughly() -> None:
    start = now_ns()
    time.sleep(0.05)
    elapsed = now_ns() - start
    # Generous bounds: scheduler jitter is fine, a wrong timebase ratio is not
    # (an unconverted tick count would be ~2.4x off on Apple Silicon).
    assert 40_000_000 < elapsed < 500_000_000
