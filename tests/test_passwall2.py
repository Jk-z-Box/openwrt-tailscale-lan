import json
import os
import pathlib
import shutil
import subprocess
import sys
import unittest

from test_integration import REPO, Router

CHAINS = ['mangle_output', 'nat_output', 'mangle_prerouting', 'dstnat']


class PassWallBypass(unittest.TestCase):
    def setUp(self):
        self.r = Router()
        self.addCleanup(self.r.close)
        self.r.set_config('tslan', {'settings': {'_type': 'settings', 'enabled': '1', 'bypass_passwall2': '1'}})
        self.helper = self.r.root / 'usr/libexec/tslan-passwall2'
        self.helper.parent.mkdir(parents=True)
        shutil.copy(REPO / 'files/usr/libexec/tslan-passwall2', self.helper)
        self.helper.chmod(0o755)
        self.r.put('bin/nft', '#!' + sys.executable + '\nexec(compile(open(' + repr(str(REPO / 'tests/mock_nft.py')) + ').read(), "mock_nft", "exec"))\n')
        (self.r.bin / 'nft').chmod(0o755)
        self.original = {c: [{'handle': i + 10, 'body': 'meta mark 0xff counter return comment "foreign"'}] for i, c in enumerate(CHAINS)}
        self.r.put('nft.json', json.dumps(self.original))

    def run_helper(self, action='sync', extra=None):
        return subprocess.run(['/bin/sh', str(self.helper), action], env=dict(self.r.env, **(extra or {})), capture_output=True, text=True)

    def state(self):
        return json.loads((self.r.root / 'nft.json').read_text())

    def assert_protected(self):
        for chain, rules in self.state().items():
            labels = ['outer', 'tun-out'] if chain.endswith('output') else ['tun-in', 'tail4', 'tail6']
            for rule, label in zip(rules, labels):
                self.assertIn('comment "tslan-pw2-v1:' + label + '"', rule['body'])
            self.assertEqual([r for r in rules if 'tslan-pw2-v1:' not in r['body']], self.original[chain])
            self.assertEqual(len(rules), len(labels) + len(self.original[chain]))

    def test_insert_before_proxy_and_idempotency(self):
        self.assertEqual(self.run_helper().returncode, 0)
        self.assert_protected()
        before = self.state()
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.state(), before)
        self.assertIn('ACTIVE:', self.run_helper('status').stdout)

    def test_restore_after_passwall_rebuild_and_new_rule_prepend(self):
        self.assertEqual(self.run_helper().returncode, 0)
        state = self.state()
        state['mangle_output'] = self.original['mangle_output']
        state['nat_output'].insert(0, {'handle': 100, 'body': 'counter return comment "another-plugin"'})
        self.original['nat_output'].insert(0, state['nat_output'][0])
        self.r.put('nft.json', json.dumps(state))
        self.assertEqual(self.run_helper().returncode, 0)
        self.assert_protected()

    def test_disable_and_pause_remove_only_owned_rules(self):
        for reason in ['disabled', 'paused']:
            with self.subTest(reason=reason):
                self.assertEqual(self.run_helper().returncode, 0)
                if reason == 'disabled':
                    config = self.r.config('tslan')
                    config['settings']['bypass_passwall2'] = '0'
                    self.r.set_config('tslan', config)
                else:
                    self.r.put('var/run/tslan/passwall2.paused', '')
                self.assertEqual(self.run_helper().returncode, 0)
                self.assertEqual(self.state(), self.original)
                config = self.r.config('tslan')
                config['settings']['bypass_passwall2'] = '1'
                self.r.set_config('tslan', config)

    def test_atomic_failure_reports_error_and_retry_recovers(self):
        self.assertNotEqual(self.run_helper(extra={'NFT_FAIL': '1'}).returncode, 0)
        self.assertEqual(self.state(), self.original)
        self.assertIn('ERROR:', self.run_helper('status').stdout)
        self.assertEqual(self.run_helper().returncode, 0)
        self.assert_protected()

    def test_missing_passwall_waits_and_later_recovers(self):
        self.r.put('nft.json', '{}')
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertIn('PENDING:', self.run_helper('status').stdout)
        self.r.put('nft.json', json.dumps(self.original))
        self.assertEqual(self.run_helper().returncode, 0)
        self.assert_protected()

    def test_stale_guard_status_is_not_success(self):
        self.assertEqual(self.run_helper().returncode, 0)
        self.r.put('var/run/tslan/passwall2.checked', '0\n')
        self.assertIn('ERROR:', self.run_helper('status').stdout)

    def test_invalid_option_is_rejected_without_nft_changes(self):
        self.assertEqual(self.run_helper().returncode, 0)
        protected = self.state()
        config = self.r.config('tslan')
        config['settings']['bypass_passwall2'] = '$(touch /tmp/not-allowed)'
        self.r.set_config('tslan', config)
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.state(), protected)
        # Explicit stop/uninstall must still remove rules if config is damaged.
        self.assertEqual(self.run_helper('remove').returncode, 0)
        self.assertEqual(self.state(), self.original)


if __name__ == '__main__':
    unittest.main()
