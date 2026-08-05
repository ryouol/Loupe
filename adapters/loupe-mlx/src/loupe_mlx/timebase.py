"""Continuous-clock nanoseconds via ctypes — the exact clock the Swift side
reads (``mach_continuous_time``), so recorded event timestamps line up with
system samples without any cross-clock mapping.

``time.monotonic_ns`` is NOT a substitute: CPython backs it with
``mach_absolute_time``-family clocks that stop during sleep.
"""

from __future__ import annotations

import ctypes

_libc = ctypes.CDLL(None)
_libc.mach_continuous_time.restype = ctypes.c_uint64
_libc.mach_timebase_info.restype = ctypes.c_int


class _TimebaseInfo(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_info = _TimebaseInfo()
_libc.mach_timebase_info(ctypes.byref(_info))


def now_ns() -> int:
    """Python ints are arbitrary precision, so the naive multiply is exact."""
    return int(_libc.mach_continuous_time()) * _info.numer // _info.denom
