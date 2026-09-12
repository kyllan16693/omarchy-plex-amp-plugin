#!/usr/bin/env python3
"""Fresh installation + real Quickshell/mpv smoke; no live desktop changes.

Requires Omarchy, Quickshell, mpv, ffmpeg, curl, and jq. Uses a local fake Plex
HTTP server and silent audio. Only shell enable/rescan, the shell-config path,
and mpv's audio output are redirected; the installed QML/helpers run normally.
HOME stays unchanged. All writable XDG paths and installation live in /tmp.
The service runs offscreen; PanelWindow requires a live Wayland/X11 backend,
so this does not exercise visual layout or keyboard/pointer input.
"""

import contextlib
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.parse
import wave


ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ID = "io.github.kyllan.ampbar"
OMARCHY = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"))


def eventually(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = predicate()
            if last:
                return last
        except (OSError, ValueError, subprocess.CalledProcessError):
            pass
        time.sleep(0.1)
    raise AssertionError(f"condition did not become true within {timeout}s; last={last!r}")


class PlexHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        self.server.requests.append(path)
        if path.startswith("/audio/"):
            body = self.server.audio
            content_type = "audio/wav"
        else:
            container = {"size": 0, "Metadata": []}
            if path == "/library/sections":
                container = {"Directory": [{"key": "1", "title": "Smoke music", "type": "artist"}]}
            elif path == "/library/sections/1/all":
                container["totalSize"] = 3
            elif path.startswith("/library/metadata/"):
                keys = path.rsplit("/", 1)[-1].split(",")
                container = {"Metadata": [track for track in self.server.tracks if track["ratingKey"] in keys]}
            elif path == "/identity":
                container = {"machineIdentifier": "smoke-machine", "friendlyName": "Smoke Plex"}
            body = json.dumps({"MediaContainer": container}).encode()
            content_type = "application/json"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(body)


class FreshInstallSmoke(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        missing = [name for name in ("quickshell", "mpv", "ffmpeg", "curl", "jq", "omarchy")
                   if not shutil.which(name)]
        if missing or not (OMARCHY / "shell/Ui").is_dir():
            raise unittest.SkipTest("requires installed Omarchy + " + ", ".join(missing))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ampbar-fresh-")
        self.base = Path(self.temp.name)
        self.env = os.environ.copy()
        for kind in ("CONFIG", "STATE", "CACHE", "RUNTIME"):
            directory = self.base / kind.lower()
            directory.mkdir(mode=0o700)
            self.env[f"XDG_{kind}_HOME" if kind != "RUNTIME" else "XDG_RUNTIME_DIR"] = str(directory)
        self.env.update(QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software",
                        QT_QPA_PLATFORMTHEME="generic", QT_QUICK_CONTROLS_STYLE="Basic",
                        NO_COLOR="1", AMPBAR_SMOKE_BASE=str(self.base))
        # The Qt offscreen instance must not select the user's real display.
        self.env.pop("WAYLAND_DISPLAY", None)
        self.env.pop("DISPLAY", None)
        self.env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
        wrappers = self.base / "wrappers"
        wrappers.mkdir()
        self.env["PATH"] = str(wrappers) + os.pathsep + self.env["PATH"]
        self.dest = self.base / "config/omarchy/plugins" / PLUGIN_ID
        self.config = self.base / "config/omarchy/shell.json"
        self.config.parent.mkdir(parents=True)
        self.write_config(True)
        self.socket = self.base / "runtime/omarchy-ampbar.sock"
        self.shells = []
        self.logs = []
        self.server = None
        # Run the real manifest validator; record enable/rescan without calling
        # the user's shell or changing their shell.json.
        self.script(wrappers / "omarchy", """#!/usr/bin/env python3
import os, subprocess, sys
from pathlib import Path
base = Path(os.environ['AMPBAR_SMOKE_BASE'])
if sys.argv[1:3] == ['plugin', 'validate']:
    if (base / 'fail-validation').exists():
        raise SystemExit(19)
    raise SystemExit(subprocess.call([os.environ['AMPBAR_REAL_VALIDATOR'], *sys.argv[3:]]))
if sys.argv[1:3] == ['plugin', 'enable']:
    with (base / 'shell-calls').open('a') as out:
        out.write('enable ' + sys.argv[3] + '\\n')
    raise SystemExit(0)
raise SystemExit('unexpected omarchy command')
""")
        self.env["AMPBAR_REAL_VALIDATOR"] = shutil.which("omarchy-plugin-validate") or str(OMARCHY / "bin/omarchy-plugin-validate")
        self.script(wrappers / "omarchy-shell", """#!/usr/bin/env python3
import os, sys
from pathlib import Path
assert sys.argv[1:] == ['shell', 'rescanPlugins'], sys.argv
with (Path(os.environ['AMPBAR_SMOKE_BASE']) / 'shell-calls').open('a') as out:
    out.write('rescan\\n')
""")
        # Real mpv decoding/playback and IPC with a null sink: no speaker output.
        real_mpv = shutil.which("mpv")
        self.script(wrappers / "mpv", "#!/usr/bin/env python3\nimport os, sys\nos.execv(" + repr(real_mpv)
                    + ", [" + repr(real_mpv) + ", '--ao=null', *sys.argv[1:]])\n")

    def tearDown(self):
        for process in self.shells:
            if process.poll() is None:
                process.terminate()
                with contextlib.suppress(subprocess.TimeoutExpired):
                    process.wait(timeout=4)
                if process.poll() is None:
                    process.kill()
                    process.wait()
        with contextlib.suppress(OSError):
            self.mpv("quit")
        # Let the detached supervisor exit before deleting its source/config.
        with contextlib.suppress(AssertionError):
            eventually(lambda: not self.socket_alive(), 3)
        if self.server:
            self.server.shutdown()
            self.server.server_close()
        for log in self.logs:
            log.close()
        self.temp.cleanup()

    @staticmethod
    def script(path, content):
        path.write_text(content)
        path.chmod(0o700)

    def run_cmd(self, *command, check=True, timeout=20):
        return subprocess.run(command, env=self.env, text=True, capture_output=True,
                              check=check, timeout=timeout)

    def install(self):
        return self.run_cmd("bash", str(ROOT / "install.sh"))

    def write_config(self, enabled):
        self.config.write_text(json.dumps({"plugins": [PLUGIN_ID],
            "bar": {"layout": {"right": [PLUGIN_ID]}},
            "disabledPlugins": [] if enabled else [PLUGIN_ID]}))

    def socket_alive(self):
        try:
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(0.2)
                client.connect(str(self.socket))
            return True
        except OSError:
            return False

    def mpv(self, *command):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(2)
            client.connect(str(self.socket))
            client.sendall(json.dumps({"command": command, "request_id": 987}).encode() + b"\n")
            if command[0] == "quit":
                return None
            with client.makefile("rb") as reader:
                while line := reader.readline():
                    response = json.loads(line)
                    if response.get("request_id") == 987:
                        self.assertEqual(response["error"], "success", response)
                        return response.get("data")
        raise AssertionError("mpv did not answer")

    def prepare_player(self):
        self.install()
        # Omarchy's real shell.json lives under HOME; the production QML passes
        # that explicit path. Redirect only this argument in the installed test
        # copy, retaining the unmodified engine implementation beside it.
        engine = self.dest / "bin/plexamp-engine"
        engine.rename(engine.with_name("plexamp-engine-real"))
        self.script(engine, """#!/usr/bin/env python3
import os, sys
from pathlib import Path
real = Path(__file__).with_name('plexamp-engine-real')
args = sys.argv[1:4]
if args[0] != 'stop':
    args += [str(Path(os.environ['AMPBAR_SMOKE_BASE']) / 'config/omarchy/shell.json')]
os.execv(str(real), [str(real), *args])
""")
        audio = io.BytesIO()
        with wave.open(audio, "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(8000)
            out.writeframes(bytes(8000 * 2 * 12))
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), PlexHandler)
        self.server.audio = audio.getvalue()
        self.server.requests = []
        self.server.tracks = [{"type": "track", "ratingKey": str(i), "key": f"/library/metadata/{i}",
            "title": f"Smoke track {i}", "duration": 12000, "grandparentTitle": "Smoke artist",
            "Media": [{"Part": [{"key": f"/audio/{i}.wav"}]}]} for i in range(1, 4)]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.uri = f"http://127.0.0.1:{self.server.server_port}"
        self.auth = self.base / "config/omarchy/plexamp/auth.json"
        self.auth.parent.mkdir(mode=0o700)
        self.auth.write_text(json.dumps({"serverUri": self.uri, "serverToken": "smoke-fake-token",
            "accountToken": "smoke-fake-account", "serverName": "Smoke Plex",
            "machineIdentifier": "smoke-machine", "clientIdentifier": "smoke-client"}))
        self.auth.chmod(0o600)
        self.harness = self.base / "harness"
        self.harness.mkdir()
        for name in ("Commons", "Ui"):
            (self.harness / name).symlink_to(OMARCHY / "shell" / name, target_is_directory=True)
        (self.harness / "Ampbar").symlink_to(self.dest, target_is_directory=True)
        (self.harness / "shell.qml").write_text("""import QtQuick
import Quickshell
import Quickshell.Io
import "Ampbar" as Ampbar
import "Ampbar/PlexApi.js" as PlexApi
ShellRoot {
  Ampbar.Service { id: service }
  IpcHandler {
    target: "smoke"
    function status(): string {
      return JSON.stringify({auth: service.authState, ready: service.ready,
        section: service.musicSectionKey, loaded: service.engineHasFile,
        playing: service.isPlaying, position: service.position,
        index: service.queueIndex, queue: service.queue.length,
        error: service.playbackError, waveform: service.waveform.length})
    }
    function playQueue(): void {
      service.request("/library/metadata/1,2,3", {}, function(response) {
        service.playQueue(PlexApi.tracks(service.serverUri, service.serverToken, response), 0, "", "Smoke")
      })
    }
    function action(name: string): void {
      if (name === "pause") service.pause()
      else if (name === "play") service.play()
      else if (name === "next") service.next()
      else if (name === "previous") service.previous()
      else if (name === "stop") service.stop()
      else if (name === "logout") service.logout()
    }
    function seek(position: real): void { service.seek(position) }
  }
}
""")

    def start_shell(self):
        log = (self.base / f"quickshell-{len(self.shells)}.log").open("w+")
        self.logs.append(log)
        process = subprocess.Popen(["quickshell", "--no-color", "-p", str(self.harness)],
            env=self.env, stdout=log, stderr=subprocess.STDOUT, text=True)
        self.shells.append(process)
        try:
            eventually(lambda: self.status().get("ready"), 10)
        except AssertionError:
            log.seek(0)
            raise AssertionError("Quickshell did not become ready:\n" + log.read())
        return process

    def ipc(self, *args):
        return self.run_cmd("quickshell", "ipc", "-p", str(self.harness), "call", "smoke", *args).stdout.strip()

    def status(self):
        return json.loads(self.ipc("status"))

    def test_install_reinstall_and_failed_validation(self):
        self.install()
        required = ["manifest.json", "Service.qml", "Panel.qml", "README.md", "LICENSE", "COPYRIGHT",
                    "THIRD_PARTY_NOTICES.md", "PRIVACY.md", "preview.png"]
        required += [str(path.relative_to(ROOT)) for path in (ROOT / "assets/screenshots").glob("*")]
        required += [str(path.relative_to(ROOT)) for path in (ROOT / "bin").glob("*") if path.is_file()]
        for name in required:
            self.assertEqual((self.dest / name).read_bytes(), (ROOT / name).read_bytes(), name)
        for helper in (self.dest / "bin").iterdir():
            self.assertTrue(os.access(helper, os.X_OK), helper)
        self.assertFalse(any(path.is_symlink() for path in self.dest.rglob("*")))
        self.run_cmd(self.env["AMPBAR_REAL_VALIDATOR"], str(self.dest))
        self.assertEqual((self.base / "shell-calls").read_text().splitlines(), ["rescan", "enable " + PLUGIN_ID])
        stale = self.dest / "stale-file"
        stale.write_text("remove on reinstall")
        self.install()
        self.assertFalse(stale.exists())
        before = {str(path.relative_to(self.dest)): path.read_bytes()
                  for path in self.dest.rglob("*") if path.is_file()}
        (self.base / "fail-validation").touch()
        failed = self.run_cmd("bash", str(ROOT / "install.sh"), check=False)
        self.assertEqual(failed.returncode, 19)
        after = {str(path.relative_to(self.dest)): path.read_bytes()
                 for path in self.dest.rglob("*") if path.is_file()}
        self.assertEqual(before, after, "failed staging modified the active install")

    def test_real_qml_playback_refresh_logout_and_removal(self):
        self.prepare_player()
        shell = self.start_shell()
        eventually(lambda: self.status().get("section") == "1")
        self.ipc("playQueue")
        eventually(lambda: self.status()["loaded"] and self.status()["playing"])
        eventually(lambda: self.status()["position"] > 0.2)
        self.assertEqual(self.mpv("get_property", "playlist-count"), 2)
        self.ipc("action", "pause")
        eventually(lambda: self.mpv("get_property", "pause") is True)
        self.assertFalse(self.status()["playing"])
        self.ipc("action", "play")
        eventually(lambda: self.mpv("get_property", "pause") is False)
        self.ipc("seek", "10.8")
        # Real EOF rolls into the prefetched file and updates QML's queue index.
        eventually(lambda: self.status()["index"] == 1, 7)
        eventually(lambda: self.status()["position"] > 0.2)
        self.assertEqual(self.mpv("get_property", "playlist-count"), 2)
        path_before = self.mpv("get_property", "path")
        position_before = self.mpv("get_property", "time-pos")
        shell.terminate()
        shell.wait(timeout=4)
        self.assertTrue(self.socket_alive(), "shell shutdown stopped detached playback")
        self.assertEqual(self.mpv("get_property", "path"), path_before)
        shell = self.start_shell()
        eventually(lambda: self.status()["index"] == 1 and self.status()["loaded"])
        self.assertGreaterEqual(self.mpv("get_property", "time-pos"), position_before)
        self.ipc("action", "next")
        eventually(lambda: self.status()["index"] == 2)
        self.ipc("action", "stop")
        eventually(lambda: self.mpv("get_property", "idle-active") is True)
        self.assertFalse(self.status()["playing"])
        self.ipc("action", "play")
        eventually(lambda: self.status()["loaded"] and self.status()["playing"])
        self.ipc("action", "logout")
        eventually(lambda: self.status()["auth"] == "logged-out" and not self.socket_alive())
        self.assertFalse(self.auth.exists(), "logout left credentials behind")
        self.assertEqual(self.status()["queue"], 0)
        state = self.base / "state/omarchy/plexamp/state.json"
        eventually(state.exists)
        self.assertNotIn("smoke-fake-token", state.read_text())
        self.assertNotIn("X-Plex-Token", state.read_text())
        self.assertEqual(state.parent.stat().st_mode & 0o777, 0o700)
        shell.terminate()
        shell.wait(timeout=4)
        engine = self.dest / "bin/plexamp-engine"
        self.run_cmd(str(engine), "start", str(self.socket), "0", str(self.config))
        self.mpv("loadfile", self.uri + "/audio/1.wav", "replace")
        self.write_config(False)
        eventually(lambda: not self.socket_alive(), 3)
        self.write_config(True)
        self.run_cmd(str(engine), "start", str(self.socket), "0", str(self.config))
        self.mpv("loadfile", self.uri + "/audio/1.wav", "replace")
        shutil.rmtree(self.dest)
        eventually(lambda: not self.socket_alive(), 7)  # missing manifest gets the config grace period


if __name__ == "__main__":
    unittest.main(verbosity=2)
