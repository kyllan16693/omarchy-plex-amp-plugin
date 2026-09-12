"""Credential-transport regressions; synthetic fixtures, no network or user state."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

REPO = Path(__file__).resolve().parents[1]
ACCOUNT_TOKEN = 'SYNTHETIC_ACCOUNT_TOKEN'
SERVER_TOKEN = 'SYNTHETIC_SERVER_TOKEN'


class CredentialTransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ampbar-security-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.config = self.root / 'config/omarchy/plexamp'
        self.config.mkdir(parents=True)
        self.auth = self.config / 'auth.json'
        self.auth.write_text(json.dumps({
            'accountToken': ACCOUNT_TOKEN, 'serverToken': SERVER_TOKEN,
            'serverUri': 'https://plex.example.invalid:32400',
            'serverName': 'Library "one"\nTest',
        }))
        (self.config / 'client-id').write_text('synthetic-client')
        self.log = self.root / 'calls.jsonl'
        self.env = dict(os.environ, XDG_CONFIG_HOME=str(self.root / 'config'),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        AMPBAR_TEST_LOG=str(self.log),
                        AMPBAR_TEST_REAL_JQ=shutil.which('jq'))
        self.make_helper('jq', '''
            import json, os, sys
            with open(os.environ['AMPBAR_TEST_LOG'], 'a') as output:
                output.write(json.dumps({'tool': 'jq', 'argv': sys.argv[1:]}) + '\\n')
            os.execv(os.environ['AMPBAR_TEST_REAL_JQ'], ['jq'] + sys.argv[1:])
        ''')
        self.make_helper('curl', '''
            import json, os, sys
            config = sys.stdin.read() if '--config' in sys.argv else ''
            with open(os.environ['AMPBAR_TEST_LOG'], 'a') as output:
                output.write(json.dumps({'tool': 'curl', 'argv': sys.argv[1:],
                                         'stdin': config, 'env': dict(os.environ)}) + '\\n')
            if '/resources?' in sys.argv[-1]:
                print(json.dumps([{'name': 'Synthetic library', 'provides': 'server',
                    'accessToken': 'SYNTHETIC_SERVER_TOKEN', 'owned': True,
                    'connections': [{'uri': 'https://plex.example.invalid:32400',
                                     'local': True, 'protocol': 'https'}]}]))
            else:
                print(json.dumps({'MediaContainer': {'machineIdentifier': 'fake-machine'}}))
        ''')

    def make_helper(self, name, source):
        target = self.bin / name
        target.write_text(f'#!{sys.executable}\n' + textwrap.dedent(source))
        target.chmod(0o755)

    def run_auth(self, *args):
        return subprocess.run([str(REPO / 'bin/plexamp-auth'), *args], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_transport_private(self, result):
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        for token in (ACCOUNT_TOKEN, SERVER_TOKEN):
            self.assertNotIn(token, result.stdout + result.stderr)
        for call in self.calls():
            for token in (ACCOUNT_TOKEN, SERVER_TOKEN):
                self.assertNotIn(token, json.dumps(call['argv']))
                self.assertNotIn(token, json.dumps(call.get('env', {})))
            if call['tool'] == 'curl':
                self.assertEqual(call['argv'][0], '-q')
                self.assertIn('--config', call['argv'])
                self.assertNotIn('-L', call['argv'])
                self.assertNotIn('--location', call['argv'])
                self.assertTrue(call['stdin'].startswith('header = "X-Plex-Token: '))
        saved = json.loads(self.auth.read_text())
        self.assertEqual(saved['accountToken'], ACCOUNT_TOKEN)
        self.assertEqual(saved['serverToken'], SERVER_TOKEN)
        self.assertEqual(self.auth.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o700)
        self.assertEqual(list(self.config.glob('.auth.*')), [])

    def test_rediscovery_keeps_both_tokens_out_of_process_metadata(self):
        self.assert_transport_private(self.run_auth('rediscover'))
        curls = [call for call in self.calls() if call['tool'] == 'curl']
        self.assertEqual(len(curls), 2)
        self.assertIn(ACCOUNT_TOKEN, curls[0]['stdin'])
        self.assertIn(SERVER_TOKEN, curls[1]['stdin'])

    def test_manual_server_preserves_quoted_metadata(self):
        self.assert_transport_private(self.run_auth('server', 'plex.example.invalid'))
        saved = json.loads(self.auth.read_text())
        self.assertEqual(saved['serverName'], 'Library "one"\nTest')
        self.assertEqual(saved['serverUri'], 'http://plex.example.invalid:32400')

    def test_unsafe_server_addresses_never_reach_curl(self):
        original = self.auth.read_text()
        for address in ('file:///etc/passwd', 'https://user:pass@example.invalid',
                        'http://example.invalid/?X-Plex-Token=secret',
                        'http://example.invalid/#fragment', 'http://host\\path',
                        'http://example.invalid\nheader = "Injected: value"'):
            with self.subTest(address=address):
                result = self.run_auth('server', address)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.auth.read_text(), original)
        self.assertEqual([call for call in self.calls() if call['tool'] == 'curl'], [])

    def test_header_injection_is_rejected_without_network(self):
        data = json.loads(self.auth.read_text())
        data['serverToken'] = 'bad"\nheader="Injected: true'
        data['accountToken'] = 'bad\r\nInjected: true'
        self.auth.write_text(json.dumps(data))
        result = self.run_auth('server', 'example.invalid')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call for call in self.calls() if call['tool'] == 'curl'], [])
        self.assertEqual(json.loads(self.auth.read_text()), data)

    def test_logout_removes_credentials(self):
        result = self.run_auth('logout')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.auth.exists())
        self.assertEqual(json.loads(result.stdout)['stage'], 'logged-out')


if __name__ == '__main__':
    unittest.main()
