"""Check password input on a real pseudo-terminal without echoing secrets."""
import os
import pathlib
import pty
import select
import subprocess
import tempfile
import termios
import unittest
from test_integration import REPO

AUTH = REPO / 'files/usr/lib/tslan/auth.sh'


class PasswordTerminal(unittest.TestCase):
    def invoke(self, fake_stty):
        with tempfile.TemporaryDirectory() as folder:
            if fake_stty is not None:
                path = pathlib.Path(folder)/'stty'
                path.write_text('#!/bin/sh\n' + fake_stty + '\n')
                path.chmod(0o755)
            master, slave = pty.openpty()
            self.addCleanup(os.close, master)
            self.addCleanup(os.close, slave)
            proc = subprocess.Popen(['/bin/sh', '-c', '. "$1"; read_secret Password', 'sh', str(AUTH)],
                stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ, PATH=folder))
            out, err = proc.communicate(timeout=4)
            self.assertNotEqual(proc.returncode, 0)
            self.assertEqual(out, b'')
            self.assertNotIn(b'Password:', err)
            return err.decode()

    def test_missing_stty_refuses_before_reading(self):
        self.assertIn('coreutils-stty', self.invoke(None))

    def test_cannot_read_terminal_state_refuses_before_reading(self):
        self.assertIn('终端状态', self.invoke('exit 1'))

    def test_cannot_disable_echo_refuses_before_reading(self):
        script = 'if [ "$1" = "-g" ]; then echo saved-state; exit 0; fi\nif [ "$1" = "-echo" ]; then exit 1; fi\nexit 0'
        self.assertIn('关闭终端回显', self.invoke(script))

    def test_success_hides_input_and_restores_echo(self):
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        before = termios.tcgetattr(slave)
        proc = subprocess.Popen(['/bin/sh', '-c', '. "$1"; read_secret Password', 'sh', str(AUTH)],
            stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: proc.poll() is not None or proc.kill())
        prompt = bytearray()
        while not prompt.endswith(b'Password: '):
            ready, _, _ = select.select([proc.stderr], [], [], 4)
            self.assertTrue(ready, 'password prompt not displayed')
            prompt.extend(os.read(proc.stderr.fileno(), 1))
        self.assertFalse(termios.tcgetattr(slave)[3] & termios.ECHO)
        secret = b'pty-validation-secret-2026'
        os.write(master, secret + b'\n')
        out, err = proc.communicate(timeout=4)
        self.assertEqual(proc.returncode, 0, err)
        self.assertEqual(out, secret)
        self.assertEqual(termios.tcgetattr(slave)[3] & termios.ECHO, before[3] & termios.ECHO)
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            self.assertNotIn(secret, os.read(master, 4096))

