#!/usr/bin/env python3
"""Exercise the real terminal answer EOF callback without any app/profile access."""
import os
import pty
import select
import time
pid, terminal = pty.fork()
if pid == 0:
    executable = os.path.abspath('.build/app-trial-check')
    os.execv(executable, [executable, '--eof'])
output = bytearray()
sent = False
deadline = time.monotonic() + 10
status = None
while time.monotonic() < deadline:
    if select.select([terminal], [], [], 0.1)[0]:
        try:
            chunk = os.read(terminal, 4096)
        except OSError:
            chunk = b''
        output.extend(chunk)
        if not sent and b'TEST EOF' in output:
            os.write(terminal, b'\x04')
            sent = True
    ended, value = os.waitpid(pid, os.WNOHANG)
    if ended:
        status = value
        break
assert status is not None, f'owned EOF test process {pid} outcome unverified; no force termination'
os.close(terminal)
assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
assert b'EOF_RECORDED' in output and b'EOF_STOPPED' in output
print('1 terminal EOF callback regression passed (no app or profile access)')
