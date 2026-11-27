"""Exercise the DNS wrapper against the real shell with a fake unshare."""
import pathlib
import subprocess
import unittest
from test_integration import Router, REPO


class IsolatedDNS(unittest.TestCase):
    def setUp(self):
        self.r = Router()
        self.addCleanup(self.r.close)
        self.wrapper = REPO / 'files/usr/libexec/tslan-dns-wrapper'
        self.r.put('tmp/resolv.conf', 'nameserver 127.0.0.1\n')
        (self.r.root / 'etc/resolv.conf').symlink_to('../tmp/resolv.conf')

    def run_wrapper(self):
        return subprocess.run(['/bin/sh', str(self.wrapper), '--port', '41641'], env=self.r.env, capture_output=True, text=True)

    def test_only_real_upstreams_enter_child_namespace(self):
        self.r.put('tmp/resolv.conf.d/resolv.conf.auto', 'nameserver 127.0.0.1\nnameserver 198.18.4.5\nnameserver 1.1.1.1\nnameserver 1.1.1.1\nnameserver 223.5.5.5\n')
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.r.root/'var/run/tslan/isolated-resolv.conf').read_text(), 'nameserver 1.1.1.1\nnameserver 223.5.5.5\n')
        self.assertEqual((self.r.root/'tmp/resolv.conf').read_text(), 'nameserver 127.0.0.1\n')
        calls = (self.r.root/'commands.log').read_text()
        self.assertIn('"unshare", "-m"', calls)
        self.assertIn('"--port", "41641"', calls)

    def test_refuses_unusable_dns_and_unexpected_resolver_layout(self):
        self.r.put('tmp/resolv.conf.d/resolv.conf.auto', 'nameserver 127.0.0.1\nnameserver 198.18.1.5\n')
        self.assertNotEqual(self.run_wrapper().returncode, 0)
        self.r.put('tmp/resolv.conf.d/resolv.conf.auto', 'nameserver 1.1.1.1\n')
        (self.r.root/'etc/resolv.conf').unlink()
        self.r.put('etc/resolv.conf', 'nameserver 8.8.8.8\n')
        self.assertNotEqual(self.run_wrapper().returncode, 0)
        self.assertFalse((self.r.root/'commands.log').exists())
