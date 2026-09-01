"""Event sinks for the instrumented generation loop.

`SocketEventWriter` never blocks: events go into a bounded queue drained by
one background thread, and a full queue or missing app becomes a counted
drop — dropped telemetry is recoverable, a stalled decode loop is not.
`FileEventWriter` is the recorder/bench sink: same interface, straight to
NDJSON on disk.
"""

from __future__ import annotations

import os
import queue
import socket
import stat
import threading
import time

from .events import Envelope, encode_line

_CLOSE = object()


class FileEventWriter:
    """Synchronous NDJSON-to-file sink; flushed per line so a crashed run
    still leaves a decodable prefix."""

    def __init__(self, path: str) -> None:
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
        )
        try:
            metadata = os.fstat(descriptor)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.geteuid()
                or metadata.st_nlink != 1
            ):
                raise OSError("output must be one owner-controlled regular file")
            os.fchmod(descriptor, 0o600)
            os.ftruncate(descriptor, 0)
            self._fh = os.fdopen(descriptor, "wb")
        except Exception:
            os.close(descriptor)
            raise
        self.dropped = 0
        self.connected = True
        self._closed = False

    def emit(self, envelope: Envelope) -> None:
        if self._closed:
            self.dropped += 1
            return
        self._fh.write(encode_line(envelope) + b"\n")
        self._fh.flush()

    def close(self, timeout: float = 0.0) -> None:
        if self._closed:
            return
        self._closed = True
        self._fh.close()
        self.connected = False


class SocketEventWriter:
    def __init__(self, socket_path: str, max_queued: int = 4096) -> None:
        self.socket_path = socket_path
        self._dropped = 0
        self._queue: queue.Queue = queue.Queue(maxsize=max(1, min(int(max_queued), 4_096)))
        self._state_lock = threading.Lock()
        self._connected = False
        self._ever_connected = False
        self._closed = False
        self._socket: socket.socket | None = None
        self._next_connect_at = 0.0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._drain, name="loupe-event-writer", daemon=True)
        self._thread.start()

    @property
    def connected(self) -> bool:
        with self._state_lock:
            return self._connected

    @property
    def dropped(self) -> int:
        with self._state_lock:
            return self._dropped

    def emit(self, envelope: Envelope) -> None:
        with self._state_lock:
            if self._closed:
                self._dropped += 1
                return
            # Keep the closed check and enqueue under one lock: otherwise a
            # concurrent close can drain the queue between them, stranding an
            # event after shutdown without counting it.
            try:
                self._queue.put_nowait(envelope)
            except queue.Full:
                self._dropped += 1

    def close(self, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + max(0.0, timeout)
        with self._state_lock:
            if self._closed:
                return
            self._closed = True
            should_drain = self._ever_connected

        # If a listener was never reachable there is nothing useful to wait
        # for during shutdown. While the writer remains open, however, the
        # first queued session_start is retained and retried so a startup race
        # cannot make the entire session undecodable.
        if should_drain:
            try:
                remaining = max(0.0, deadline - time.monotonic())
                self._queue.put(_CLOSE, timeout=remaining)
            except queue.Full:
                pass
            self._thread.join(timeout=max(0.0, deadline - time.monotonic()))

        if self._thread.is_alive():
            self._stop.set()
            self._disconnect()
            self._thread.join(timeout=max(0.25, deadline - time.monotonic()))

        abandoned = 0
        while True:
            try:
                item = self._queue.get_nowait()
            except queue.Empty:
                break
            if item is not _CLOSE:
                abandoned += 1
        self._record_drops(abandoned)
        self._disconnect()

    def _drain(self) -> None:
        while not self._stop.is_set():
            # Connection setup may wait on the OS; keep it off the inference
            # thread just like writes. An empty queue still connects eagerly
            # so `connected` is a useful readiness signal to callers.
            self._connect()
            try:
                item = self._queue.get(timeout=0.1)
            except queue.Empty:
                continue
            if item is _CLOSE:
                self._disconnect()
                return

            delivered = False
            while not self._stop.is_set() and not delivered:
                self._connect()
                with self._state_lock:
                    active_socket = self._socket
                if active_socket is None:
                    self._stop.wait(0.1)
                    continue
                try:
                    active_socket.sendall(encode_line(item) + b"\n")
                    delivered = True
                except OSError:
                    self._disconnect(active_socket)
            if not delivered:
                self._record_drops(1)

    def _connect(self) -> None:
        now = time.monotonic()
        with self._state_lock:
            if self._socket is not None or now < self._next_connect_at:
                return
        candidate: socket.socket | None = None
        try:
            candidate = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            candidate.settimeout(1.0)
            candidate.connect(self.socket_path)
            with self._state_lock:
                if self._stop.is_set():
                    candidate.close()
                    return
                self._socket = candidate
                self._connected = True
                self._ever_connected = True
        except OSError:
            if candidate is not None:
                candidate.close()
            with self._state_lock:
                self._socket = None
                self._connected = False
                self._next_connect_at = now + 0.5

    def _disconnect(self, expected: socket.socket | None = None) -> None:
        with self._state_lock:
            active_socket = self._socket
            if expected is not None and active_socket is not expected:
                return
            self._socket = None
            self._connected = False
        if active_socket is not None:
            try:
                active_socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                active_socket.close()
            except OSError:
                pass

    def _record_drops(self, count: int) -> None:
        if count <= 0:
            return
        with self._state_lock:
            self._dropped += count
