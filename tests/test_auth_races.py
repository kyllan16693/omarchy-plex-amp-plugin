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


@unittest.skipUnless(shutil.which("node"), "node is required for QML JS fixtures")
class QmlRequestRaceTests(unittest.TestCase):
    def test_session_reset_ignores_late_callbacks(self):
        script = r"""
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const qml = fs.readFileSync(process.argv[1], 'utf8');
const match = qml.match(/^  function apiRequest\([^]*?^  }/m);
assert.ok(match, 'missing QML function apiRequest');
const requests = [];
function Xhr() { requests.push(this); this.readyState = 0; this.status = 0; }
Xhr.DONE = 4;
Xhr.prototype.open = function () {};
Xhr.prototype.setRequestHeader = function () {};
Xhr.prototype.send = function () {};
const context = vm.createContext({
  serverUri: 'http://fixture.invalid:32400', serverToken: 'SYNTHETIC',
  serverName: 'fixture', clientId: 'audit', _sessionGeneration: 0,
  XMLHttpRequest: Xhr, PlexApi: {url() { return 'http://fixture.invalid:32400/test'; }},
});
context.root = context;
vm.runInContext(match[0], context);
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


if __name__ == "__main__":
    unittest.main()
