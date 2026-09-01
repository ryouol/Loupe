import os
import socket
import threading
import time
import uuid

import pytest
from loupe_mlx.events import Envelope, ModelLoadStart, TransportSummary, decode_line
from loupe_mlx.socket_writer import SocketEventWriter


class UnixLineServer:
    """Minimal in-test stand-in for the daemon's socket listener."""

    def __init__(self) -> None:
        self.path = f"/tmp/loupe-pytest-{uuid.uuid4().hex[:8]}.sock"
        self.lines: list[bytes] = []
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(self.path)
        self._server.listen(1)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self) -> None:
        conn, _ = self._server.accept()
        buffer = b""
        while True:
            chunk = conn.recv(16384)
            if not chunk:
                return
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                self.lines.append(line)

    def wait_for(self, count: int, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        while len(self.lines) < count and time.monotonic() < deadline:
            time.sleep(0.005)


def _envelope(ts: int) -> Envelope:
    return Envelope(ts=ts, run_id="r-w", payload=ModelLoadStart(model_id=f"m{ts}"))


def test_events_arrive_in_order() -> None:
    server = UnixLineServer()
    writer = SocketEventWriter(server.path)
    deadline = time.monotonic() + 2
    while not writer.connected and time.monotonic() < deadline:
        time.sleep(0.005)
    assert writer.connected
    for ts in range(1, 51):
        writer.emit(_envelope(ts))
    server.wait_for(50)
    writer.close()

    decoded = [decode_line(line) for line in server.lines]
    assert [envelope.ts for envelope in decoded] == list(range(1, 51))
    assert writer.dropped == 0


def test_missing_daemon_degrades_to_counted_drops() -> None:
    writer = SocketEventWriter("/tmp/loupe-definitely-not-listening.sock")
    assert not writer.connected
    for ts in range(10):
        writer.emit(_envelope(ts))
    writer.close()
    assert writer.dropped == 10


def test_file_writer_feeds_the_same_instrument(tmp_path) -> None:
    # The recorder/bench path: LoupeInstrument with a file sink must produce
    # a decodable stream starting with session_start + clock_sync, without
    # mlx installed (instrument construction imports nothing heavy).
    from loupe_mlx import LoupeInstrument
    from loupe_mlx.socket_writer import FileEventWriter

    path = tmp_path / "events.ndjson"
    loupe = LoupeInstrument(run_id="r-file", writer=FileEventWriter(str(path)))
    loupe.close()

    lines = path.read_bytes().splitlines()
    decoded = [decode_line(line) for line in lines]
    assert [envelope.event for envelope in decoded] == [
        "session_start",
        "clock_sync",
        "transport_summary",
    ]
    assert all(envelope.run_id == "r-file" for envelope in decoded)
    assert os.stat(path).st_mode & 0o777 == 0o600


def test_file_writer_rejects_symlink_without_touching_target(tmp_path) -> None:
    from loupe_mlx.socket_writer import FileEventWriter

    target = tmp_path / "target.ndjson"
    target.write_bytes(b"keep me")
    link = tmp_path / "output.ndjson"
    link.symlink_to(target)

    with pytest.raises(OSError):
        FileEventWriter(str(link))
    assert target.read_bytes() == b"keep me"


def test_emit_never_blocks_even_when_queue_is_full() -> None:
    # No server drains the queue, so it fills; emits past capacity must
    # return immediately as drops rather than stalling the caller.
    writer = SocketEventWriter("/tmp/loupe-not-listening-either.sock", max_queued=8)
    start = time.monotonic()
    for ts in range(10_000):
        writer.emit(_envelope(ts))
    elapsed = time.monotonic() - start
    writer.close()
    assert elapsed < 1.0, f"10k emits took {elapsed:.2f}s — emit is blocking"
    assert writer.dropped > 0


def test_emit_after_close_is_counted() -> None:
    writer = SocketEventWriter("/tmp/loupe-closed-writer.sock", max_queued=8)
    writer.close()
    before = writer.dropped
    writer.emit(_envelope(1))
    assert writer.dropped == before + 1


def test_writer_reconnects_after_listener_appears() -> None:
    path = f"/tmp/loupe-pytest-{uuid.uuid4().hex[:8]}.sock"
    writer = SocketEventWriter(path)
    writer.emit(_envelope(1))
    time.sleep(0.55)
    server = UnixLineServer.__new__(UnixLineServer)
    server.path = path
    server.lines = []
    server._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server._server.bind(path)
    server._server.listen(1)
    server._thread = threading.Thread(target=server._serve, daemon=True)
    server._thread.start()

    writer.emit(_envelope(2))
    server.wait_for(2)
    writer.close()
    assert [decode_line(line).ts for line in server.lines] == [1, 2]
    assert writer.dropped == 0


def test_delivery_retry_is_bounded_and_counted() -> None:
    writer = SocketEventWriter(
        "/tmp/loupe-bounded-retry-not-listening.sock",
        max_queued=8,
        max_delivery_seconds=0.05,
    )
    writer.emit(_envelope(1))
    deadline = time.monotonic() + 1.0
    while writer.dropped == 0 and time.monotonic() < deadline:
        time.sleep(0.01)
    writer.close()
    assert writer.dropped >= 1


def test_terminal_summary_is_created_after_prior_queue_drops_settle() -> None:
    server = UnixLineServer()
    writer = SocketEventWriter(server.path, max_queued=8)
    deadline = time.monotonic() + 2
    while not writer.connected and time.monotonic() < deadline:
        time.sleep(0.005)
    assert writer.connected

    for ts in range(10_000):
        writer.emit(_envelope(ts))
    writer.finish(
        lambda dropped: Envelope(
            ts=10_001,
            run_id="r-w",
            payload=TransportSummary(
                attempted_events=10_000,
                producer_dropped_events=dropped,
            ),
            seq=10_001,
        )
    )
    server.wait_for(10_001 - writer.dropped)

    summary = decode_line(server.lines[-1]).payload
    assert isinstance(summary, TransportSummary)
    assert summary.producer_dropped_events == writer.dropped
    assert summary.producer_dropped_events > 0
