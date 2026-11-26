"""End-to-end management behavior, without contacting a real router."""
import hashlib
import json
import pathlib
import subprocess
import unittest
from test_integration import Router, REPO

class Management(unittest.TestCase):
    def setUp(self):
        self.r = Router()
        self.addCleanup(self.r.close)
        result = self.r.run('--non-interactive')
        self.assertEqual(result.returncode, 0, result.stdout)

    def cli(self, *args, stdin='', extra=None):
        return subprocess.run(['/bin/sh', str(self.r.root / 'usr/sbin/tslan'), *args],
            env=dict(self.r.env, **(extra or {})), input=stdin, text=True, capture_output=True)

    def ok(self, result):
        self.assertEqual(result.returncode, 0, (result.stdout or "") + (result.stderr or ""))

    def clear_rate(self):
        (self.r.root / 'var/run/tslan/auth-next').unlink(missing_ok=True)

    def test_password_guards_all_manual_mutations_and_uninstall(self):
        password = 'local-Test$Secret 42'
        self.ok(self.cli('passwd', stdin=password+'\n'))
        stored = (self.r.root / 'etc/tslan/password').read_text().strip()
        fmt, salt, digest = stored.split(':')
        self.assertEqual(fmt, 'pbkdf2-sha256-200000')
        self.assertEqual(digest, hashlib.pbkdf2_hmac('sha256',password.encode(),bytes.fromhex(salt),200000,32).hex().upper())
        self.assertEqual((self.r.root / 'etc/tslan/password').stat().st_mode & 0o777, 0o600)
        before = self.r.config('tslan')
        for args in [('stop',), ('lan4','off'), ('web','off'), ('config','hostname','new'), ('passwd','off'), ('uninstall',)]:
            self.clear_rate()
            result = self.cli(*args, stdin='incorrect\n')
            self.assertNotEqual(result.returncode, 0, args)
            self.assertEqual(self.r.config('tslan'), before)
            self.assertTrue((self.r.root / 'etc/tslan/password').exists())
        self.clear_rate()
        self.ok(self.cli('lan4','off', stdin=password+'\n'))
        self.assertEqual(self.r.config('tslan')['settings']['lan_ipv4'], '0')
        self.ok(self.cli('status'))
        self.ok(self.r.control('boot'))  # unattended reboot must not prompt
        self.clear_rate()
        self.ok(self.cli('passwd', stdin=password+'\nreplacement-password\n'))
        self.assertNotEqual(stored, (self.r.root / 'etc/tslan/password').read_text().strip())
        self.ok(self.cli('uninstall', stdin='replacement-password\n'))
        self.assertFalse((self.r.root / 'usr/sbin/tslan').exists())
        self.assertFalse((self.r.root / 'etc/tslan/password').exists())
        self.assertEqual(set(self.r.config('firewall')), {'lan_zone', 'wan_zone'})
        self.assertNotIn(password, (self.r.root / 'commands.log').read_text())

    def test_ipv4_off_preserves_host_and_ipv6_requires_existing_lan(self):
        r = self.r
        r.running()
        self.ok(r.control('boot'))
        baseline = json.loads((r.root/'sysctl.json').read_text())
        network = r.config('network')['lan']
        self.ok(self.cli('lan4', 'off'))
        self.assertNotIn('tslan_lan', r.config('firewall'))
        self.assertEqual(json.loads((r.root/'addresses.json').read_text()), {'4': True, '6': True})
        gate=(r.root/'etc/tslan/forward.nft').read_text()
        self.assertIn('meta nfproto ipv4',gate)
        self.assertIn('meta nfproto ipv6',gate)
        before=r.config('tslan')
        bad=self.cli('lan6','on')
        self.assertNotEqual(bad.returncode,0)
        self.assertIn('Global settings are preserved',bad.stderr)
        self.assertEqual(r.config('tslan'),before)
        baseline['net.ipv6.conf.all.forwarding']='1'
        r.put('sysctl.json',json.dumps(baseline))
        bad=self.cli('lan6','on')
        self.assertNotEqual(bad.returncode,0)
        self.assertIn('ULA/global',bad.stderr)
        self.ok(self.cli('lan6','on',extra={'LAN_IPV6_READY':'1'}))
        fw=r.config('firewall')
        self.assertEqual(fw['tslan_lan6']['family'],'ipv6')
        self.assertEqual(fw['tslan']['masq6'],'1')
        self.assertNotIn('tslan_lan',fw)
        self.assertNotIn('tslan_no_forward6_in',fw)
        self.assertNotIn('meta nfproto ipv6',(r.root/'etc/tslan/forward.nft').read_text())
        self.assertEqual(r.config('network')['lan'],network)
        now=json.loads((r.root/'sysctl.json').read_text())
        self.assertEqual({k:v for k,v in now.items() if 'tailscale0' not in k}, {k:v for k,v in baseline.items() if 'tailscale0' not in k})
        self.ok(self.cli('lan4','on',extra={'LAN_IPV6_READY':'1'}))
        self.assertIn('tslan_lan',r.config('firewall'))
        self.assertIn('tslan_lan6',r.config('firewall'))
        self.ok(self.cli('lan6','off'))
        self.assertNotIn('tslan_lan6',r.config('firewall'))
        self.assertEqual(r.config('firewall')['tslan']['masq6'],'0')
        self.assertIn('tslan_lan',r.config('firewall'))

    def test_visibility_upgrade_preservation_and_failure_rollback(self):
        r=self.r
        self.ok(self.cli('web','off'))
        menu=r.root/'usr/share/luci/menu.d/luci-app-tslan.json'
        self.assertFalse(menu.exists())
        self.ok(self.cli('passwd',stdin='upgrade-password\n'))
        old=r.config('tslan')
        # Upgrade/check/uninstall cannot refresh packages or change config before auth.
        for args in [[], ['--uninstall'], ['--check']]:
            self.clear_rate()
            log=(r.root/'commands.log').read_text()
            result=subprocess.run(['/bin/sh',str(REPO/'install.sh'),*args],env=r.env,input='wrong\n',text=True,capture_output=True)
            self.assertNotEqual(result.returncode,0)
            delta=(r.root/'commands.log').read_text()[len(log):]
            self.assertNotIn('"update"',delta)
            self.assertEqual(r.config('tslan'),old)
        self.clear_rate()
        result=subprocess.run(['/bin/sh',str(REPO/'install.sh'),'--non-interactive'],env=r.env,input='upgrade-password\n',text=True,capture_output=True)
        self.ok(result)
        self.assertFalse(menu.exists())
        self.assertTrue((r.root/'etc/tslan/password').exists())
        oldfw=r.config('firewall'); gate=(r.root/'etc/tslan/forward.nft').read_text()
        bad=self.cli('lan4','off',stdin='upgrade-password\n',extra={'FW_FAIL':'1'})
        self.assertNotEqual(bad.returncode,0)
        self.assertEqual(r.config('tslan'),old)
        self.assertEqual(r.config('firewall'),oldfw)
        self.assertEqual((r.root/'etc/tslan/forward.nft').read_text(),gate)
        self.assertFalse(menu.exists())
        self.ok(self.cli('web','on',stdin='upgrade-password\n'))
        self.assertTrue(menu.exists())
        self.ok(self.cli('passwd','off',stdin='upgrade-password\n'))
        self.ok(self.cli('stop'))

    def test_invalid_setting_is_atomic_and_no_shell_evaluation(self):
        r=self.r; old=r.config('tslan')
        for key,value in [('managed','0'),('hostname','$(touch /tmp/tslan-injected)'),('lan_ipv4','yes'),('lan_network','lan;reboot')]:
            result=self.cli('config',key,value)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(r.config('tslan'),old)
        self.assertFalse((r.root/'var/run/tslan/lock').exists())
        self.ok(self.cli('config','hostname','router-name'))
        self.assertEqual(r.config('tslan')['settings']['hostname'],'router-name')

    def test_rpc_password_validation_allowlist_and_config(self):
        import sys
        r=self.r
        r.put('usr/share/libubox/jshn.sh',(REPO/'tests/mock_jshn.sh').read_text())
        r.put('bin/json_test',f'#!{sys.executable}\n'+(REPO/'tests/mock_json.py').read_text())
        (r.root/'bin/json_test').chmod(0o755)
        self.ok(self.cli('passwd',stdin='rpc-test-password\n'))
        def rpc(method, data=None):
            result=subprocess.run(['/bin/sh',str(r.root/'usr/libexec/rpcd/tslan'),'call',method],
                env=r.env,input=json.dumps(data or {})+'\n',text=True,capture_output=True)
            self.ok(result)
            return json.loads(result.stdout)
        status=rpc('status')
        self.assertTrue(status['password_required'])
        self.assertEqual(status['settings']['lan_ipv4'],'1')
        self.assertNotIn('rpc-test-password',json.dumps(status))
        before=r.config('tslan')
        for data in [
            {'name':'stop'},
            {'name':'set','password':'wrong','config':json.dumps({'enabled':'0'})},
            {'name':'boot','password':'rpc-test-password'},
            {'name':'uninstall','password':'rpc-test-password'},
            {'name':'set','password':'rpc-test-password','config':json.dumps({'managed':'0'})},
            {'name':'set','password':'rpc-test-password','config':json.dumps({'enabled':False})},
        ]:
            self.clear_rate()
            response=rpc('action',data)
            self.assertFalse(response['accepted'],response)
            self.assertEqual(r.config('tslan'),before)
        self.clear_rate()
        request_config=dict(status['settings'],web_visible='0')
        oldlog=(r.root/'commands.log').read_text()
        response=rpc('action',{'name':'set','password':'rpc-test-password','config':json.dumps(request_config)})
        self.assertTrue(response['accepted'])
        # rpcd detaches the job; wait only for its actual completion signal.
        import time
        for _ in range(200):
            if r.config('tslan')['settings']['web_visible']=='0' and not (r.root/'var/run/tslan/lock').exists(): break
            time.sleep(.05)
        self.assertEqual(r.config('tslan')['settings']['web_visible'],'0')
        self.assertEqual((r.root/'var/run/tslan/last-exit').read_text().strip(),'0')
        self.assertFalse(list((r.root/'var/run/tslan/tickets').iterdir()))
        self.assertNotIn('"daemon-init"',(r.root/'commands.log').read_text()[len(oldlog):])
        self.assertNotIn('rpc-test-password',(r.root/'var/run/tslan/job.log').read_text())
        acl=json.loads((REPO/'files/usr/share/rpcd/acl.d/luci-app-tslan.json').read_text())
        self.assertNotIn('uci',acl['luci-app-tslan']['write'])

    def test_install_choices_and_password_set_before_first_use(self):
        r=Router(); self.addCleanup(r.close)
        result=subprocess.run(['/bin/sh',str(REPO/'install.sh'),'--web','off','--password','on','--non-interactive'],
            env=r.env,input='initial-password\n',text=True,capture_output=True)
        self.ok(result)
        self.assertEqual(r.config('tslan')['settings']['web_visible'],'0')
        self.assertTrue((r.root/'etc/tslan/password').exists())
        self.assertFalse((r.root/'usr/share/luci/menu.d/luci-app-tslan.json').exists())
        self.assertNotIn('initial-password',result.stdout+result.stderr)
        result=r.control('stop')
        self.assertNotEqual(result.returncode,0)
