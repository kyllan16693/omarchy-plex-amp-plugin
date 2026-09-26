#!/usr/bin/env python3
"""Exercise sign-out against delayed server probes and late QML HTTP callbacks.

Only synthetic credentials and a fake curl executable are used. No network or
desktop session is needed. Run: python3 -m unittest discover -s tests -v
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[1]


class AuthLogoutRaceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ampbar-auth-race-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.config = self.base / "config" / "omarchy" / "plexamp"
        self.config.mkdir(parents=True)
        self.auth = self.config / "auth.json"
        self.auth.write_text(json.dumps({
            "accountToken": "SYNTHETIC_ACCOUNT_123",
            "serverToken": "SYNTHETIC_SERVER_456",
            "serverUri": "http://fixture.invalid:32400",
            "serverName": "fixture",
            "clientIdentifier": "audit-client",
        }))
        self.auth.chmod(0o600)
        (self.config / "client-id").write_text("audit-client")
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        curl = bin_dir / "curl"
        curl.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys, time
base = pathlib.Path(os.environ['AMPBAR_AUDIT_DIR'])
target = sys.argv[-1]
if '--config' in sys.argv:
    sys.stdin.read()
if '/pins/' in target:
    print(json.dumps({'authToken': 'SYNTHETIC_ACCOUNT_123'}))
elif target.endswith('/pins'):
    print(json.dumps({'id': 1, 'code': 'FAKE', 'expiresIn': 900}))
elif '/resources?' in target:
    print(json.dumps([{'provides': 'server', 'name': 'fixture',
        'accessToken': 'SYNTHETIC_SERVER_456', 'owned': True,
        'connections': [{'uri': 'http://fixture.invalid:32400',
                         'protocol': 'http', 'local': True}]}]))
else:
    (base / 'in-flight').touch()
    deadline = time.monotonic() + 15
    while not (base / 'release').exists() and time.monotonic() < deadline:
        time.sleep(.01)
    print(json.dumps({'MediaContainer': {'machineIdentifier': 'fixture-machine'}}))
""")
        curl.chmod(0o700)
        # Login should neither open a real browser nor wait two seconds per poll.
        for command in ("xdg-open", "sleep"):
            fake = bin_dir / command
            fake.write_text("#!/bin/sh\nexit 0\n")
            fake.chmod(0o700)
        self.env = dict(os.environ, XDG_CONFIG_HOME=str(self.base / "config"),
                        PATH=str(bin_dir) + ":" + os.environ["PATH"],
                        AMPBAR_AUDIT_DIR=str(self.base))

    def helper(self, *args):
        return [str(REPO / "bin" / "plexamp-auth"), *args]

    def assert_logout_cancels(self, *args):
        process = subprocess.Popen(self.helper(*args), env=self.env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        def cleanup_process():
            (self.base / "release").touch()
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

        self.addCleanup(cleanup_process)
        deadline = time.monotonic() + 10
        while not (self.base / "in-flight").exists():
            if process.poll() is not None:
                self.fail("helper exited before reaching the delayed fixture: "
                          + repr(process.communicate()))
            if time.monotonic() > deadline:
                self.fail("helper never reached the delayed fixture")
            time.sleep(.01)
        logout = subprocess.run(self.helper("logout"), env=self.env, text=True,
                                capture_output=True, timeout=5)
        self.assertEqual(logout.returncode, 0, logout.stderr)
        self.assertFalse(self.auth.exists(), "logout did not remove credentials")
        (self.base / "release").touch()
        stdout, stderr = process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0, stdout + stderr)
        self.assertFalse(self.auth.exists(), "late helper recreated credentials")
        self.assertEqual(list(self.config.glob(".auth.*")), [],
                         "cancelled helper left a credentials temp file")
        self.assertNotIn('"stage":"done"', stdout)

    def test_logout_cancels_delayed_manual_server(self):
        self.assert_logout_cancels("server", "http://fixture.invalid:32400")

    def test_logout_cancels_delayed_rediscovery(self):
        self.assert_logout_cancels("rediscover")


class QmlRequestRaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("node"):
            raise RuntimeError("node is required for the QML JS fixtures")

    def test_session_reset_ignores_late_callbacks(self):
        script = r"""
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const qml = fs.readFileSync(process.argv[1], 'utf8');
const pieces = ['apiRequest', 'fetchBounded', 'clipStrings'].map(function (name) {
  const found = qml.match(new RegExp('^  function ' + name + '\\([^]*?^  }', 'm'));
  assert.ok(found, 'missing QML function ' + name);
  return found[0];
});
const requests = [];
function Xhr() { requests.push(this); this.readyState = 0; this.status = 0; this.response = null; }
Xhr.HEADERS_RECEIVED = 2;
Xhr.LOADING = 3;
Xhr.DONE = 4;
Xhr.prototype.open = function () {};
Xhr.prototype.setRequestHeader = function () {};
Xhr.prototype.send = function () {};
Xhr.prototype.abort = function () {};
const context = vm.createContext({
  serverUri: 'http://fixture.invalid:32400', serverToken: 'SYNTHETIC',
  serverName: 'fixture', clientId: 'audit', _sessionGeneration: 0,
  apiTimeoutMs: 30000, apiMaxResponseBytes: 1024, apiMaxInFlightBytes: 2048,
  apiMaxStringLength: 2000,
  _pendingRequests: [],
  requestDeadline: {start() {}, stop() {}}, Qt: {callLater(fn) { fn(); }},
  XMLHttpRequest: Xhr, PlexApi: {url() { return 'http://fixture.invalid:32400/test'; }},
});
context.root = context;
vm.runInContext(pieces.join('\n'), context);
let successes = 0, failures = 0;
function finish(request) {
  request.readyState = Xhr.DONE;
  request.status = 200;
  request.responseText = '{}';
  request.onreadystatechange();
}
context.apiRequest('GET', '/test', {}, () => successes++, () => failures++);
context._sessionGeneration++;  // what clearSession() does on sign-out
finish(requests[0]);
assert.equal(successes + failures, 0, 'stale callback ran after session reset');
context.apiRequest('GET', '/new-session', {}, () => successes++, () => failures++);
finish(requests[1]);
assert.equal(successes, 1, 'new-session callback was incorrectly discarded');
"""
        result = subprocess.run(["node", "-e", script, str(REPO / "Service.qml")],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unanswered_mpv_requests_stay_bounded(self):
        # The position poll registers a callback twice a second; if mpv never
        # answers, only the newest callbacks may be kept.
        script = r"""
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const qml = fs.readFileSync(process.argv[1], 'utf8');
const found = qml.match(/^  function sendCommand\([^]*?^  }/m);
assert.ok(found, 'missing QML function sendCommand');
const written = [];
const context = vm.createContext({
  _requests: {}, _requestSeq: 0, _pending: [],
  engineOnline() { return true; }, ensureEngine() {},
  ipc: {write(line) { written.push(line); }},
});
vm.runInContext(found[0], context);
for (let i = 0; i < 1000; i++) context.sendCommand(['get_property', 'time-pos'], () => {});
const keys = Object.keys(context._requests).map(Number);
assert.equal(keys.length, 32);
assert.deepEqual(keys, Array.from({length: 32}, (_, i) => 969 + i));
assert.equal(written.length, 1000);
"""
        result = subprocess.run(["node", "-e", script, str(REPO / "Service.qml")],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_tint_cache_evicts_the_least_recently_shown_album(self):
        # Album keys are Plex rating keys, integer-like strings that
        # Object.keys would otherwise list in numeric order.
        script = r"""
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const qml = fs.readFileSync(process.argv[1], 'utf8');
const found = qml.match(/^  function rememberTint\([^]*?^  }/m);
assert.ok(found, 'missing QML function rememberTint');
const context = vm.createContext({_tintCache: {}, tintCacheSize: 60});
vm.runInContext(found[0], context);
for (let key = 1000; key < 1060; key++) context.rememberTint(String(key), key);
context.rememberTint('1000', 1000);  // shown again, so now the newest
context.rememberTint('7', 7);        // a low key must still be kept
const keys = Object.keys(context._tintCache);
assert.equal(keys.length, 60);
assert.ok(!keys.includes('album:1001'), 'oldest album was kept');
assert.deepEqual(keys.slice(-2), ['album:1000', 'album:7']);
"""
        result = subprocess.run(["node", "-e", script, str(REPO / "Service.qml")],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_budget_applies_to_replies_that_arrive_whole(self):
        # Qt can deliver a reply entirely with DONE, skipping LOADING, where
        # the shared budget is otherwise enforced.
        script = r"""
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const qml = fs.readFileSync(process.argv[1], 'utf8');
const found = qml.match(/^  function fetchBounded\([^]*?^  }/m);
assert.ok(found, 'missing QML function fetchBounded');
const requests = [];
function Xhr() { requests.push(this); this.readyState = 0; this.status = 0; this.response = null; }
Xhr.HEADERS_RECEIVED = 2; Xhr.LOADING = 3; Xhr.DONE = 4;
Xhr.prototype.open = function () {};
Xhr.prototype.setRequestHeader = function () {};
Xhr.prototype.send = function () {};
Xhr.prototype.abort = function () {};
const context = vm.createContext({
  _sessionGeneration: 0, apiTimeoutMs: 30000, apiMaxInFlightBytes: 2048,
  _pendingRequests: [{bytes: 1500}],  // another reply, still arriving
  requestDeadline: {start() {}, stop() {}}, Qt: {callLater(fn) { fn(); }},
  XMLHttpRequest: Xhr, serverName: 'fixture', clientId: 'audit',
});
context.root = context;
vm.runInContext(found[0], context);
const outcomes = [];
function finishWhole(bytes) {
  const request = requests[requests.length - 1];
  request.readyState = Xhr.DONE; request.status = 200;
  request.response = {byteLength: bytes};
  request.onreadystatechange();
}
context.fetchBounded('GET', 'http://x/a', 'application/json', 1024,
  () => outcomes.push('ok'), (e) => outcomes.push(e));
finishWhole(1000);   // under its own 1024 cap, but 1000 + 1500 > 2048
context.fetchBounded('GET', 'http://x/b', 'application/json', 1024,
  () => outcomes.push('ok'), (e) => outcomes.push(e));
finishWhole(400);    // 400 + 1500 fits
assert.deepEqual(outcomes, ['response from Plex was too large', 'ok']);
"""
        result = subprocess.run(["node", "-e", script, str(REPO / "Service.qml")],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
