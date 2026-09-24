"""Credential-transport regressions; synthetic fixtures, no network or user state."""
import json
import http.server
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
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


class _MediaHandler(http.server.BaseHTTPRequestHandler):
    """Serves one synthetic track, with or without a Content-Length."""
    def log_message(self, *args):
        pass

    def do_GET(self):
        data = self.server.media
        self.send_response(200)
        if self.path.startswith('/chunked'):
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            for i in range(0, len(data), 65536):
                chunk = data[i:i + 65536]
                self.wfile.write(b'%x\r\n' % len(chunk) + chunk + b'\r\n')
            self.wfile.write(b'0\r\n\r\n')
        else:
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('curl'), 'needs ffmpeg and curl')
class WaveformBoundsTests(unittest.TestCase):
    """A server can make the waveform helper fail, never grow without bound."""

    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), _MediaHandler)
        # The helper hanging up mid-transfer is the behaviour under test.
        cls.server.handle_error = lambda *args: None
        # Thirty seconds of noise: long enough for a real envelope, small
        # enough that the caps below are far under its size and duration.
        cls.server.media = subprocess.run(
            ['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'anoisesrc=d=30:a=0.5',
             '-ac', '1', '-c:a', 'flac', '-f', 'flac', '-'],
            capture_output=True, check=True, timeout=60).stdout
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = 'http://127.0.0.1:%d' % cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ampbar-waveform-')
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name) / 'omarchy/plexamp/waveform'

    def run_waveform(self, path, bin_dir=None, **limits):
        env = dict(os.environ, XDG_STATE_HOME=self.temp.name)
        if bin_dir:
            env['PATH'] = str(bin_dir) + os.pathsep + env['PATH']
        env.update({key: str(value) for key, value in limits.items()})
        result = subprocess.run([str(REPO / 'bin/plexamp-waveform'), '42'], env=env,
                                input=self.base + path + '?X-Plex-Token=' + SERVER_TOKEN + '\n',
                                capture_output=True, text=True, timeout=60)
        self.assertNotIn(SERVER_TOKEN, result.stdout + result.stderr)
        self.assertEqual([p.name for p in self.state.glob('.*')], [])
        return result, json.loads(result.stdout)

    def test_track_within_limits_is_analysed_and_cached(self):
        for path in ('/track', '/chunked'):
            with self.subTest(path=path):
                for cached in self.state.glob('*.json'):
                    cached.unlink()
                result, message = self.run_waveform(path)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(message['stage'], 'waveform')
                self.assertEqual(len(message['peaks']), 120)
                self.assertTrue((self.state / '42.json').exists())

    def test_download_past_the_byte_cap_is_refused(self):
        for path in ('/track', '/chunked'):
            with self.subTest(path=path):
                result, message = self.run_waveform(path, AMPBAR_WAVEFORM_MAX_BYTES=4096)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(message['stage'], 'error')
                self.assertFalse((self.state / '42.json').exists())

    def test_audio_past_the_duration_cap_is_refused(self):
        result, message = self.run_waveform('/track', AMPBAR_WAVEFORM_MAX_SECONDS=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(message['stage'], 'error')
        self.assertFalse((self.state / '42.json').exists())

    def test_decoder_failure_after_partial_output_is_refused(self):
        # ffmpeg killed by its timeout mid-track: Python sees a clean EOF with
        # plenty of samples, so only the pipeline status can reject the result.
        # Ten seconds of PCM, then either the exit status timeout(1) reports or
        # the SIGTERM it sends.
        for name, ending in (('exit 124', 'sys.exit(124)'),
                             ('SIGTERM', 'os.kill(os.getpid(), signal.SIGTERM)')):
            with self.subTest(ending=name):
                bin_dir = Path(self.temp.name) / ('bin-' + name.replace(' ', '-'))
                bin_dir.mkdir()
                fake = bin_dir / 'ffmpeg'
                fake.write_text(f'#!{sys.executable}\n' + textwrap.dedent(f'''
                    import math, os, signal, struct, sys
                    pcm = b''.join(struct.pack('<h', int(8000 * math.sin(i / 5)))
                                   for i in range(40000))
                    sys.stdout.buffer.write(pcm)
                    sys.stdout.flush()
                    {ending}
                '''))
                fake.chmod(0o755)
                result, message = self.run_waveform('/track', bin_dir=bin_dir)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertEqual(message['stage'], 'error')
                self.assertFalse((self.state / '42.json').exists())

    def test_limits_cannot_be_raised_from_the_environment(self):
        source = (REPO / 'bin/plexamp-waveform').read_text()
        self.assertIn('AMPBAR_WAVEFORM_MAX_BYTES < MAX_DOWNLOAD_BYTES', source)
        self.assertIn('AMPBAR_WAVEFORM_MAX_SECONDS < MAX_SECONDS', source)
        # No stage may read the whole response or the decoded audio at once.
        self.assertNotIn('stdin.buffer.read()', source)
        self.assertNotRegex(source, r'curl[^\n]*\|')


if __name__ == '__main__':
    unittest.main()
