"""Event sinks for the instrumented generation loop.

`SocketEventWriter` never blocks: events go into a bounded queue drained by
one background thread, and a full queue or missing daemon becomes a counted
drop — dropped telemetry is recoverable, a stalled decode loop is not.
`FileEventWriter` is the recorder/bench sink: same interface, straight to
NDJSON on disk.
"""

from __future__ import annotations

import queue
import socket
import threading

from .events import Envelope, encode_line

_CLOSE = object()


class FileEventWriter:
    """Synchronous NDJSON-to-file sink; flushed per line so a crashed run
    still leaves a decodable prefix."""

    def __init__(self, path: str) -> None:
        self._fh = open(path, "wb")
        self.dropped = 0
        self.connected = True

    def emit(self, envelope: Envelope) -> None:
        self._fh.write(encode_line(envelope) + b"\n")
        self._fh.flush()

    def close(self, timeout: float = 0.0) -> None:
        self._fh.close()
        self.connected = False


class SocketEventWriter:
    def __init__(self, socket_path: str, max_queued: int = 4096) -> None:
        self.socket_path = socket_path
        self.dropped = 0
        self._queue: queue.Queue = queue.Queue(maxsize=max_queued)
        self._connected = False
        self._socket: socket.socket | None = None
        try:
            self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self._socket.connect(socket_path)
            self._connected = True
        except OSError:
            # No daemon listening: every emit becomes a counted drop and the
            # instrumented run proceeds exactly as an uninstrumented one.
            self._socket = None
        self._thread = threading.Thread(
            target=self._drain, name="loupe-event-writer", daemon=True
        )
        self._thread.start()

    @property
    def connected(self) -> bool:
        return self._connected

    def emit(self, envelope: Envelope) -> None:
        try:
            self._queue.put_nowait(envelope)
        except queue.Full:
            self.dropped += 1

    def close(self, timeout: float = 5.0) -> None:
        self._queue.put(_CLOSE)
        self._thread.join(timeout=timeout)
        if self._socket is not None:
            try:
                self._socket.close()
            except OSError:
                pass
        self._connected = False

    def _drain(self) -> None:
        while True:
            item = self._queue.get()
            if item is _CLOSE:
                return
            if self._socket is None:
                self.dropped += 1
                continue
            try:
                self._socket.sendall(encode_line(item) + b"\n")
            except OSError:
                self.dropped += 1
                try:
                    self._socket.close()
                except OSError:
                    pass
                self._socket = None
                self._connected = False
