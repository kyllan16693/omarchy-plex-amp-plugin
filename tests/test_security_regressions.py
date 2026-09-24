"""Credential-transport regressions; synthetic fixtures, no network or user state."""
import json
import http.server
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
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


class _PlexApiHandler(http.server.BaseHTTPRequestHandler):
    """A Plex server that misbehaves in each of the ways the shell must survive."""
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split('?')[0]
        try:
            if path == '/ok':
                body = json.dumps({'MediaContainer': {'size': 1}}).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif path == '/declared':
                # Claims 100 MiB up front, then waits for the client to hang up.
                self.send_response(200)
                self.send_header('Content-Length', str(100 * 1024 * 1024))
                self.end_headers()
                self.wfile.write(b'{')
                self.wfile.flush()
                time.sleep(15)
            elif path == '/endless':
                # Chunked, so no length is ever declared; stops when refused.
                self.send_response(200)
                self.send_header('Transfer-Encoding', 'chunked')
                self.end_headers()
                chunk = b' ' * 65536
                for _ in range(4096):
                    self.wfile.write(b'%x\r\n' % len(chunk) + chunk + b'\r\n')
                    self.wfile.flush()
                    time.sleep(0.001)
            elif path == '/stall':
                # 700 KiB, under the per-request cap, then nothing more.
                self.send_response(200)
                self.send_header('Transfer-Encoding', 'chunked')
                self.end_headers()
                chunk = b' ' * (700 * 1024)
                self.wfile.write(b'%x\r\n' % len(chunk) + chunk + b'\r\n')
                self.wfile.flush()
                time.sleep(15)
            elif path == '/trickle':
                # One byte a fifth of a second: never idle, never finishing.
                self.send_response(200)
                self.send_header('Transfer-Encoding', 'chunked')
                self.end_headers()
                for _ in range(150):
                    self.wfile.write(b'1\r\n \r\n')
                    self.wfile.flush()
                    time.sleep(0.2)
        except (BrokenPipeError, ConnectionResetError):
            pass


@unittest.skipUnless(shutil.which('qml6') or shutil.which('qml'), 'needs the qml runtime')
class PlexApiBoundsTests(unittest.TestCase):
    """Service.qml's real request code, run under Qt against a hostile server."""
    TIMEOUT_MS = 2000
    MAX_BYTES = 1024 * 1024
    MAX_IN_FLIGHT = 2 * 1024 * 1024

    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), _PlexApiHandler)
        cls.server.daemon_threads = True
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = 'http://127.0.0.1:%d' % cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def harness(self, directory, labels, extra=''):
        source = (REPO / 'Service.qml').read_text()
        pieces = []
        for pattern in (r'^  function apiRequest\([^]*?^  }$',
                        r'^  function expireRequests\([^]*?^  }$',
                        r'^  function cancelRequests\([^]*?^  }$',
                        r'^  Timer \{\n    id: requestDeadline[^]*?^  }$'):
            match = re.search(pattern.replace('[^]', r'[\s\S]'), source, re.M)
            self.assertIsNotNone(match, pattern)
            pieces.append(match.group(0))
        shutil.copy(REPO / 'PlexApi.js', directory / 'PlexApi.js')
        (directory / 'harness.qml').write_text(textwrap.dedent('''\
            import QtQuick
            import "PlexApi.js" as PlexApi
            Item {
              id: root
              property string serverUri: %(base)s
              property string serverToken: "SYNTHETIC"
              property string serverName: "fixture"
              property string clientId: "audit"
              property int _sessionGeneration: 0
              readonly property int apiTimeoutMs: %(timeout)d
              readonly property int apiMaxResponseBytes: %(cap)d
              readonly property int apiMaxInFlightBytes: %(budget)d
              property var _pendingRequests: []
              property int outstanding: %(count)d
              // A label is a path plus an optional "#n", so one path can be
              // requested several times at once.
              function report(label, started, outcome) {
                console.log("RESULT " + JSON.stringify({ path: label, ms: Date.now() - started,
                                                         outcome: outcome }))
                if (--outstanding === 0) Qt.quit()
              }
              Component.onCompleted: {
                var labels = %(labels)s
                labels.forEach(function (label) {
                  var started = Date.now()
                  root.apiRequest("GET", label.split("#")[0], {},
                    function (json) { root.report(label, started, "ok " + JSON.stringify(json)) },
                    function (error) { root.report(label, started, "failed " + error) })
                })
              }
            ''') % {'base': json.dumps(self.base), 'timeout': self.TIMEOUT_MS,
                    'cap': self.MAX_BYTES, 'budget': self.MAX_IN_FLIGHT,
                    'count': len(labels), 'labels': json.dumps(labels)}
            + '\n\n'.join(pieces + [extra]) + '\n}\n')
        return directory / 'harness.qml'

    def run_qml(self, labels, extra=''):
        with tempfile.TemporaryDirectory(prefix='ampbar-api-') as temp:
            qml = self.harness(Path(temp), list(labels), extra)
            env = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_FORCE_STDERR_LOGGING='1')
            result = subprocess.run([shutil.which('qml6') or shutil.which('qml'), str(qml)],
                                    env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def run_requests(self, *labels):
        output = self.run_qml(labels)
        results = {}
        for line in output.splitlines():
            if 'RESULT ' in line:
                entry = json.loads(line.split('RESULT ', 1)[1])
                results[entry['path']] = entry
        self.assertEqual(sorted(results), sorted(labels), output)
        return results

    def test_bounded_replies_are_parsed_and_hostile_ones_refused(self):
        results = self.run_requests('/ok', '/declared', '/endless', '/trickle')
        self.assertEqual(results['/ok']['outcome'], 'ok {"MediaContainer":{"size":1}}')
        self.assertEqual(results['/declared']['outcome'], 'failed response from Plex was too large')
        self.assertEqual(results['/endless']['outcome'], 'failed response from Plex was too large')
        self.assertEqual(results['/trickle']['outcome'], 'failed Plex took too long to respond')
        # The deadline is total, not idle: a steady trickle still gets cut off.
        self.assertLess(results['/trickle']['ms'], self.TIMEOUT_MS + 1500)
        for path in ('/declared', '/endless'):
            self.assertLess(results[path]['ms'], self.TIMEOUT_MS)

    def test_replies_under_the_cap_share_one_budget(self):
        # Four 700 KiB replies are each allowed alone, but together they pass
        # the 2 MiB in-flight budget; whichever pushes it over is refused.
        labels = ['/stall#%d' % i for i in range(4)]
        results = self.run_requests(*labels)
        outcomes = [results[label]['outcome'] for label in labels]
        refused = [label for label in labels
                   if results[label]['outcome'] == 'failed response from Plex was too large']
        self.assertTrue(refused, outcomes)
        for label in refused:
            self.assertLess(results[label]['ms'], self.TIMEOUT_MS)
        for label in set(labels) - set(refused):
            self.assertEqual(results[label]['outcome'], 'failed Plex took too long to respond')

    def test_sign_out_aborts_requests_in_flight(self):
        # What clearSession() does: bump the generation, then cancel. Nothing
        # may call back afterwards, and nothing may be left in flight.
        output = self.run_qml(['/trickle#1', '/trickle#2'], extra=textwrap.dedent('''\
              Timer {
                interval: 300
                running: true
                onTriggered: {
                  root._sessionGeneration++
                  root.cancelRequests()
                  console.log("LEFT " + root._pendingRequests.length + " " + requestDeadline.running)
                  Qt.callLater(Qt.quit)
                }
              }'''))
        self.assertIn('LEFT 0 false', output)
        self.assertNotIn('RESULT ', output)

    def test_limits_are_fixed_in_the_service(self):
        source = (REPO / 'Service.qml').read_text()
        self.assertIn('readonly property int apiTimeoutMs: 30000', source)
        self.assertIn('readonly property int apiMaxResponseBytes: 16 * 1024 * 1024', source)
        self.assertIn('readonly property int apiMaxInFlightBytes: 32 * 1024 * 1024', source)
        self.assertIn('xhr.responseType = "arraybuffer"', source)
        # Sign-out and teardown must both abort whatever is still in flight.
        for block in (r'^  function clearSession\(\) \{[\s\S]*?^  }$',
                      r'^  Component\.onDestruction: \{[\s\S]*?^  }$'):
            match = re.search(block, source, re.M)
            self.assertIsNotNone(match, block)
            self.assertIn('cancelRequests()', match.group(0))


if __name__ == '__main__':
    unittest.main()
