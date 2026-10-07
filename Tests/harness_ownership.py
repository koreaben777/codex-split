"""Synthetic-client supervisor. Timeout reports failure but never discards ownership.
No spawn, signal, PID lookup or process-group operation lives in this module.
"""
import json
import subprocess
import time


class HarnessFailure(Exception):
    pass


class Interruption:
    def __init__(self):
        self.requested = False

    def receive(self, _signum, _frame):
        # Do not throw between spawning and storing the owned Popen handle.
        self.requested = True


class OwnedClient:
    def __init__(self, child, interruption, report, clock=time.monotonic):
        self.child = child
        self.interruption = interruption
        self.report = report
        self.clock = clock
        self.failed = False
        self.reaped = False
        self.output = None
        self.events = set()

    def emit(self, event):
        try:
            self.report(event)
        except OSError:
            # Losing the reporting pipe must not lose the owned client.
            self.failed = True

    def note(self, event):
        self.failed = True
        if event not in self.events:
            self.events.add(event)
            self.emit(event)

    def finish(self, seconds):
        deadline = self.clock() + seconds
        while not self.reaped:
            if self.interruption.requested:
                self.note('INTERRUPTED: ownership retained; cleanup unconfirmed; waiting for client exit')
            if self.clock() >= deadline:
                self.note('TIMEOUT: ownership retained; cleanup unconfirmed; waiting for client exit')
            try:
                self.output = self.child.communicate(timeout=0.25)
                # communicate returning is not sufficient for an injected/broken waiter.
                if self.child.returncode is None:
                    self.note('WAIT_UNCONFIRMED: ownership retained; no further test will start')
                    continue
                self.reaped = True
            except subprocess.TimeoutExpired:
                continue
            except (KeyboardInterrupt, InterruptedError):
                self.interruption.requested = True
            except OSError:
                # Do not terminate the client or close its pipes to recover a read error.
                self.note('IO_FAILED: ownership retained; cleanup unconfirmed; waiting for client exit')
                self.wait_after_io_error()
        if self.failed:
            self.emit('CLIENT_REAPED: test failed; server cleanup unconfirmed; preserve fixtures')
        return self.output

    def wait_after_io_error(self):
        while not self.reaped:
            try:
                result = self.child.wait(timeout=0.25)
                if result is not None:
                    self.reaped = True
                else:
                    self.note('WAIT_UNCONFIRMED: ownership retained; no further test will start')
            except subprocess.TimeoutExpired:
                continue
            except (KeyboardInterrupt, InterruptedError):
                self.interruption.requested = True
            except OSError:
                # Stay attached. A failed wait is not evidence of reaping or ownership transfer.
                self.note('WAIT_FAILED: ownership retained; no further test will start')
                time.sleep(0.25)

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        if self.interruption.requested:
            self.note('INTERRUPTED: test failed; preserve fixtures')
        if kind is not None:
            self.note('CHECK_FAILED: ownership retained; waiting for client exit')
        if not self.reaped:
            self.finish(0)
        if kind is None and self.failed:
            raise HarnessFailure()
        return False


def cleanup_summary(output):
    """Fixed classifications from synthetic output; never echo child keys or values."""
    if not isinstance(output, bytes) or len(output) > 1_048_576:
        return 'CLEANUP_UNCONFIRMED'
    for line in output.splitlines():
        try:
            frame = json.loads(line)
        except (ValueError, UnicodeError):
            continue
        if not isinstance(frame, dict) or not isinstance(frame.get('cleanup'), dict):
            continue
        cleanup = frame['cleanup']
        if any(cleanup.get(key) in ('denied', 'error') for key in ('term', 'kill')):
            return 'CLEANUP_FAILED: signal rejected; no retry'
        if cleanup.get('waitFailed') is True or cleanup.get('waitExpired') is True:
            return 'CLEANUP_FAILED: wait failed or expired; no retry'
    return 'CLEANUP_UNCONFIRMED'
