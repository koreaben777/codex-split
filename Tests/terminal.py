"""Only project-built fake processes; no Codex app/CLI or real profile launches."""
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import time

project = Path(__file__).resolve().parent.parent
binary = str(project / '.build/readiness-check')
checks = 0

def session(args, ready, action, expected, marker):
    global checks
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(binary, [binary, *args])
    data = b''
    done = False
    deadline = time.monotonic() + 8
    try:
        while ready not in data and time.monotonic() < deadline:
            if select.select([fd], [], [], .1)[0]:
                data += os.read(fd, 4096)
        assert ready in data, ('not ready', data)
        time.sleep(.05)
        if isinstance(action, bytes):
            os.write(fd, action)
        else:
            os.kill(pid, action)
        while time.monotonic() < deadline:
            if select.select([fd], [], [], .05)[0]:
                try:
                    data += os.read(fd, 4096)
                except OSError:
                    pass
            result, status = os.waitpid(pid, os.WNOHANG)
            if result:
                done = True
                assert os.waitstatus_to_exitcode(status) == expected, (args, status, data)
                assert marker in data, (marker, data)
                if args[0] == "--run":
                    assert b"CLEANED:true" in data, data
                checks += 1
                return
        raise AssertionError(('timeout', args, data))
    finally:
        if not done:
            # Our synthetic test process only; never an operational application.
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(fd)

for response, expected, marker in [(b'yes\n', 0, b'ANSWER:accepted'), (b'no\n', 2, b'ANSWER:denied'),
                                    (b'cancel\n', 2, b'ANSWER:cancelled'), (b'yes\x00not-approved\n', 2, b'ANSWER:cancelled'), (b'\x04', 2, b'ANSWER:cancelled'),
                                    (b'\x03', 2, b'ANSWER:interrupted'), (signal.SIGTERM, 2, b'ANSWER:interrupted'),
                                    (signal.SIGHUP, 2, b'ANSWER:interrupted')]:
    session(['--prompt'], b'Type yes', response, expected, marker)
result = subprocess.run([binary, '--prompt'], input=b'yes\n', stdout=subprocess.PIPE, check=False)
assert result.returncode == 2 and b'ANSWER:cancelled' in result.stdout
checks += 1
with tempfile.TemporaryDirectory(prefix='terminal-', dir=project / '.test-data') as root:
    for sig in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
        session(['--run', root], b'READY', sig, 128 + sig, b'TERMINAL_RESTORED:true')
    session(['--run', root], b'READY', b'\x03', 130, b'TERMINAL_RESTORED:true')
print(f'{checks} PTY/signal integration checks passed')

# The test build injects a signal immediately before the native wait, with no input.
pid, fd = pty.fork()
if pid == 0:
    os.execv(str(project / '.build/native-signal-race'), ['native-signal-race'])
finished = False
try:
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        result, status = os.waitpid(pid, os.WNOHANG)
        if result:
            finished = True
            assert os.waitstatus_to_exitcode(status) == 0, status
            print('1 deterministic signal-boundary regression passed')
            break
        time.sleep(.02)
    assert finished, 'signal-before-wait hung the approval prompt'
finally:
    if not finished:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(fd)
