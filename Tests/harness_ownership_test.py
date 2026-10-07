"""Pure fake-client regressions; never create processes or send signals."""
import ast
from pathlib import Path
import subprocess
import unittest
from harness_ownership import OwnedClient, Interruption, HarnessFailure, cleanup_summary


class FakeClient:
    def __init__(self, steps, waits=()):
        self.steps = list(steps)
        self.waits = list(waits)
        self.returncode = None
        self.calls = 0

    def communicate(self, timeout):
        self.calls += 1
        step = self.steps.pop(0)
        if isinstance(step, BaseException):
            raise step
        self.returncode = step
        return (b"synthetic", b"")

    def wait(self, timeout):
        step = self.waits.pop(0)
        if isinstance(step, BaseException):
            raise step
        self.returncode = step
        return step


def timeout():
    return subprocess.TimeoutExpired("synthetic", 0.25)


def supervisor(steps, times, waits=()):
    ticks = iter(times)
    events = []
    child = FakeClient(steps, waits)
    owned = OwnedClient(child, Interruption(), events.append, clock=lambda: next(ticks))
    return owned, events


class OwnershipTests(unittest.TestCase):
    def test_harness_never_kills_client_or_uses_run_timeout(self):
        # The candidate check supervisor in update-work.py owns its client until reaped.
        module = ast.parse((Path(__file__).resolve().parents[1] / 'scripts/update-work.py').read_text())
        tree = next(node for node in module.body if isinstance(node, ast.FunctionDef) and node.name == 'run_checks')
        prohibited = [node.func.attr for node in ast.walk(tree)
                      if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                      and node.func.attr in ('kill', 'terminate', 'run')]
        self.assertEqual(prohibited, [], 'timeout must preserve client ownership until reap')

    def test_normal_completion_reaps_without_failure(self):
        owned, events = supervisor([0], [0, 0])
        with owned:
            self.assertEqual(owned.finish(1), (b'synthetic', b''))
        self.assertTrue(owned.reaped)
        self.assertFalse(events)

    def test_timeout_preserves_handle_until_later_exit_and_fails(self):
        owned, events = supervisor([timeout(), timeout(), 0], [0, 0, 2, 3])
        with self.assertRaises(HarnessFailure):
            with owned:
                owned.finish(1)
        self.assertTrue(owned.reaped)
        self.assertEqual(owned.child.calls, 3)
        self.assertEqual(sum(e.startswith('TIMEOUT:') for e in events), 1)
        self.assertTrue(events[-1].startswith('CLIENT_REAPED:'))

    def test_body_exception_waits_without_client_kill(self):
        owned, events = supervisor([timeout(), 0], [0, 0, 1])
        with self.assertRaises(ValueError):
            with owned:
                raise ValueError('synthetic')
        self.assertTrue(owned.reaped)
        self.assertTrue(events[0].startswith('CHECK_FAILED:'))

    def test_keyboard_interrupt_during_drain_retains_ownership(self):
        owned, events = supervisor([KeyboardInterrupt(), timeout(), 0], [0, 0, 1, 2])
        with self.assertRaises(HarnessFailure):
            with owned:
                owned.finish(5)
        self.assertTrue(owned.reaped)
        self.assertTrue(any(e.startswith('INTERRUPTED:') for e in events))

    def test_handler_records_interrupt_without_raising(self):
        owned, events = supervisor([0], [0, 0])
        owned.interruption.receive(15, None)
        with self.assertRaises(HarnessFailure):
            with owned:
                owned.finish(5)
        self.assertTrue(owned.reaped)

    def test_io_failure_waits_and_never_reports_success(self):
        owned, events = supervisor([OSError('secret')], [0, 0], [timeout(), InterruptedError(), 1])
        with self.assertRaises(HarnessFailure):
            with owned:
                owned.finish(5)
        self.assertTrue(owned.reaped)
        self.assertFalse(any('secret' in e for e in events))
        self.assertTrue(any(e.startswith('IO_FAILED:') for e in events))

    def test_unconfirmed_wait_does_not_release_ownership(self):
        owned, events = supervisor([None, 0], [0, 0, 1])
        with self.assertRaises(HarnessFailure):
            with owned:
                owned.finish(5)
        self.assertTrue(owned.reaped)
        self.assertEqual(owned.child.calls, 2)
        self.assertTrue(any(e.startswith('WAIT_UNCONFIRMED:') for e in events))

    def test_cleanup_failure_summary_is_fixed_and_does_not_echo(self):
        result = cleanup_summary(b'{"cleanup":{"kill":"denied"},"secret":"do-not-echo"}')
        self.assertEqual(result, 'CLEANUP_FAILED: signal rejected; no retry')
        self.assertEqual(cleanup_summary(b'{"cleanup":{"waitFailed":true}}'),
                         'CLEANUP_FAILED: wait failed or expired; no retry')
        self.assertEqual(cleanup_summary(b'{"cleanup":{"leaderReaped":true}}'), 'CLEANUP_UNCONFIRMED')
        for data in (b'invalid-secret', b'null', b'[]', b'"secret"', b'x' * 1_048_577):
            self.assertEqual(cleanup_summary(data), 'CLEANUP_UNCONFIRMED')

    def test_interrupt_after_reap_before_context_exit_fails(self):
        owned, events = supervisor([0], [0, 0])
        with self.assertRaises(HarnessFailure):
            with owned:
                owned.finish(5)
                owned.interruption.receive(15, None)
        self.assertTrue(owned.reaped)
        self.assertTrue(any(e.startswith('INTERRUPTED:') for e in events))

    def test_broken_diagnostic_pipe_keeps_ownership(self):
        owned, events = supervisor([timeout(), 0], [0, 0, 2])
        def broken_report(_event):
            raise BrokenPipeError()
        owned.report = broken_report
        with self.assertRaises(HarnessFailure):
            with owned:
                owned.finish(1)
        self.assertTrue(owned.reaped)


if __name__ == '__main__':
    unittest.main()
