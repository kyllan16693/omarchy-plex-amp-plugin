"""Lifecycle/security regressions using private fixtures, never the desktop.

Run: python -m unittest discover -s tests -p 'test_engine_lifecycle.py' -v
These tests need permission to bind Unix sockets in their own /tmp directory.
The real-mpv check uses a null audio output and locally generated silence.
"""

import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import wave


SOURCE = Path(__file__).resolve().parents[1]
PLUGIN_ID = "io.github.kyllan.ampbar"
REAL_MPV = shutil.which("mpv")
FAKE_MPV = r'''#!/usr/bin/env python3
import json, os, pathlib, socket, sys, time
base = pathlib.Path(os.environ["AMPBAR_TEST_ROOT"])
with (base / "players.jsonl").open("a") as log:
    log.write(json.dumps({"pid": os.getpid(), "supervisor": os.getppid()}) + "\n")
time.sleep(float(os.environ.get("AMPBAR_TEST_START_DELAY", "0")))
target = next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--input-ipc-server="))
server = socket.socket(socket.AF_UNIX)
server.bind(target)
server.listen(32)
server.settimeout(0.2)
try:
    while True:
        try:
            client, _ = server.accept()
        except socket.timeout:
            continue
        with client:
            client.settimeout(0.2)
            try:
                request = client.recv(65536)
            except socket.timeout:
                continue
            if b'"quit"' in request:
                break
finally:
    server.close()
    try:
        os.unlink(target)
    except FileNotFoundError:
        pass
'''


def wait_until(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.025)
    return False


class EngineLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ampbar-engine-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.runtime = self.root / "run"
        self.runtime.mkdir(mode=0o700)
        # Fail explicitly when sandbox restrictions would make a false
        # startup failure look like a product bug.
        probe = socket.socket(socket.AF_UNIX)
        try:
            probe.bind(str(self.runtime / "probe.sock"))
        except PermissionError:
            self.skipTest("sandbox blocks private Unix socket binding")
        finally:
            probe.close()
        (self.runtime / "probe.sock").unlink()
        self.engine = self.bin / "plexamp-engine"
        shutil.copy2(SOURCE / "bin/plexamp-engine", self.engine)
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(json.dumps({"id": PLUGIN_ID}))
        self.config = self.root / "shell.json"
        self.enable()
        self.target = self.runtime / "omarchy-ampbar.sock"
        self.fake = self.bin / "mpv"
        self.fake.write_text(FAKE_MPV)
        self.fake.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.root / "home"),
                        XDG_CONFIG_HOME=str(self.root / "config"),
                        XDG_RUNTIME_DIR=str(self.runtime),
                        AMPBAR_TEST_ROOT=str(self.root),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.children = []
        self.addCleanup(self.clean_players)

    def enable(self):
        self.config.write_text(json.dumps({"bar": {"layout": {
            "right": [{"id": PLUGIN_ID}], "left": [], "center": []}}}))

    def command(self, action):
        return [sys.executable, str(self.engine), action, str(self.target), "70", str(self.config)]

    def run_engine(self, action, **kwargs):
        return subprocess.run(self.command(action), env=self.env,
                              capture_output=True, text=True, timeout=10, **kwargs)

    def launch(self, action="start"):
        child = subprocess.Popen(self.command(action), env=self.env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, start_new_session=True)
        self.children.append(child)
        return child

    def alive(self):
        try:
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(0.2)
                client.connect(str(self.target))
                return True
        except OSError:
            return False

    def players(self):
        log = self.root / "players.jsonl"
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text().splitlines()]

    def clean_players(self):
        self.config.write_text("{}")
        try:
            self.run_engine("stop")
        except subprocess.TimeoutExpired:
            pass
        wait_until(lambda: not self.alive(), 7)
        for child in self.children:
            try:
                child.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                child.kill()
                child.communicate()
        # Only terminate processes whose command line still points into this
        # particular fixture. Never use global mpv/process-name matching.
        for player in self.players():
            for pid in (player["pid"], player["supervisor"]):
                try:
                    argv = Path(f"/proc/{pid}/cmdline").read_bytes()
                    if str(self.root).encode() in argv:
                        os.kill(pid, signal.SIGTERM)
                except (FileNotFoundError, ProcessLookupError):
                    pass

    def assert_started(self):
        result = self.run_engine("start")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.alive())

    def test_concurrent_launches_create_one_player(self):
        children = [self.launch() for _ in range(12)]
        for child in children:
            _, stderr = child.communicate(timeout=10)
            self.assertEqual(child.returncode, 0, stderr)
        self.assertEqual(len(self.players()), 1)
        self.assertTrue(self.alive())

    def test_disable_stops_player(self):
        self.assert_started()
        self.config.write_text("{}")
        self.assertTrue(wait_until(lambda: not self.alive(), 2))

    def test_explicit_disabled_override_stops_player(self):
        self.assert_started()
        self.config.write_text(json.dumps({"plugins": [{"id": PLUGIN_ID}],
                                          "disabledPlugins": [PLUGIN_ID]}))
        self.assertTrue(wait_until(lambda: not self.alive(), 2))

    def test_missing_configuration_stops_after_grace(self):
        self.assert_started()
        self.config.unlink()
        time.sleep(0.8)
        self.assertTrue(self.alive())
        self.assertTrue(wait_until(lambda: not self.alive(), 7))

    def test_malformed_configuration_cannot_enable_plugin(self):
        enabled = runpy.run_path(str(self.engine))["enabled"]
        for config in ({"plugins": {PLUGIN_ID: {}}},
                       {"bar": {"layout": {"right": {PLUGIN_ID: {}}}}}):
            with self.subTest(config=config):
                self.config.write_text(json.dumps(config))
                self.assertIsNot(enabled(self.config), True)

    def test_invalid_json_stops_after_grace(self):
        self.assert_started()
        self.config.write_text("{")
        self.assertTrue(wait_until(lambda: not self.alive(), 7))

    def test_manifest_replacement_and_shell_refresh_preserve_player(self):
        self.assert_started()  # The launcher has already exited.
        original = self.manifest.read_text()
        self.manifest.unlink()
        backup = self.root / "shell.backup"
        self.config.rename(backup)
        time.sleep(0.8)
        self.manifest.write_text(original)
        backup.rename(self.config)
        self.assert_started()
        self.assertEqual(len(self.players()), 1)

    def test_removed_installation_stops_player(self):
        self.assert_started()
        self.manifest.unlink()
        self.assertTrue(wait_until(lambda: not self.alive(), 7))

    def test_stop_cancels_delayed_startup(self):
        self.env["AMPBAR_TEST_START_DELAY"] = "1.0"
        launcher = self.launch()
        self.assertTrue(wait_until(lambda: bool(self.players()), 3))
        result = self.run_engine("stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        launcher.communicate(timeout=10)
        time.sleep(1.2)
        self.assertFalse(self.alive(), "stop returned before an in-flight player started")

    def test_disable_during_startup_cannot_leave_player(self):
        self.env["AMPBAR_TEST_START_DELAY"] = "1.0"
        launcher = self.launch()
        self.assertTrue(wait_until(lambda: bool(self.players()), 3))
        self.config.write_text("{}")
        launcher.communicate(timeout=10)
        time.sleep(1.2)
        self.assertFalse(self.alive())

    def test_legacy_player_is_adopted_and_stopped_on_disable(self):
        legacy = subprocess.Popen([str(self.fake), f"--input-ipc-server={self.target}"],
                                  env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, start_new_session=True)
        self.children.append(legacy)
        self.assertTrue(wait_until(self.alive, 3))
        self.assert_started()
        time.sleep(0.3)  # Let the detached supervisor acquire its lock.
        self.assertEqual(len(self.players()), 1)
        self.config.write_text("{}")
        self.assertTrue(wait_until(lambda: not self.alive(), 2))
        legacy.communicate(timeout=3)
        self.assertEqual(legacy.returncode, 0)

    def test_stale_socket_is_replaced(self):
        with socket.socket(socket.AF_UNIX) as stale:
            stale.bind(str(self.target))
        self.assert_started()

    def test_socket_symlink_is_refused_without_touching_target(self):
        victim = self.root / "victim"
        victim.write_text("unchanged")
        self.target.symlink_to(victim)
        result = self.run_engine("start")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(victim.read_text(), "unchanged")
        self.assertEqual(self.players(), [])

    def test_unsafe_lock_is_refused_without_modifying_target(self):
        victim = self.root / "victim"
        victim.write_text("unchanged")
        victim.chmod(0o640)
        os.link(victim, self.target.with_suffix(".lock"))
        result = self.run_engine("supervise")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(victim.read_text(), "unchanged")
        self.assertEqual(victim.stat().st_mode & 0o777, 0o640)
        self.assertEqual(self.players(), [])

    @unittest.skipUnless(REAL_MPV, "mpv is not installed")
    def test_real_mpv_plays_local_silence_through_launcher_exit(self):
        self.fake.write_text("#!/usr/bin/env python3\n"
                             "import os, sys\n"
                             f"os.execv({REAL_MPV!r}, [{REAL_MPV!r}, '--ao=null'] + sys.argv[1:])\n")
        audio = self.root / "silence.wav"
        with wave.open(str(audio), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(8000)
            wav.writeframes(b"\x00\x00" * 8000 * 10)
        self.assert_started()
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(3)
            client.connect(str(self.target))
            stream = client.makefile("rb")

            def request(command, request_id):
                client.sendall(json.dumps({"command": command, "request_id": request_id}).encode() + b"\n")
                while True:
                    line = stream.readline()
                    self.assertTrue(line, "mpv closed its socket")
                    response = json.loads(line)
                    if response.get("request_id") == request_id:
                        return response

            response = request(["loadfile", str(audio), "replace"], 1)
            self.assertEqual(response["error"], "success")
            time.sleep(1)
            response = request(["get_property", "time-pos"], 2)
            self.assertEqual(response["error"], "success")
            self.assertGreater(response["data"], 0)
            stream.close()
        self.config.write_text("{}")
        self.assertTrue(wait_until(lambda: not self.alive(), 3))


if __name__ == "__main__":
    unittest.main()
