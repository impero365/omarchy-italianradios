#!/usr/bin/env python3
"""The player reaches streams only through the public-address proxy."""

import json
import os
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[1]
PLAYER = PLUGIN / "radio-player"
STATION = "11111111-1111-4111-8111-111111111111"


class SandboxPlayback(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.runtime = Path(self.temp.name)
        real = os.environ.get("XDG_RUNTIME_DIR", "")
        for name in ("pipewire-0", "pipewire-0-manager"):
            target = Path(real) / name
            if target.exists():
                os.symlink(target, self.runtime / name)
        self.env = os.environ.copy()
        self.env["XDG_RUNTIME_DIR"] = str(self.runtime)
        self.env.pop("ALL_PROXY", None)
        self.env.pop("all_proxy", None)

    def tearDown(self):
        subprocess.run([str(PLAYER), "stop"], env=self.env, check=False, capture_output=True, text=True)
        self.stop_command_process()
        self.temp.cleanup()

    def stop_command_process(self):
        pid_file = self.runtime / "mattia.radio" / "player-command.pid"
        try:
            pid = int(pid_file.read_text().split()[0])
        except (OSError, ValueError):
            return
        command = Path(f"/proc/{pid}/cmdline").read_bytes() if Path(f"/proc/{pid}/cmdline").exists() else b""
        if b"radio-playerd" not in command:
            return
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            return
        for _ in range(50):
            try:
                os.kill(pid, 0)
            except OSError:
                return
            time.sleep(0.02)

    def run_player(self, *args, timeout=20):
        completed = subprocess.run(
            [str(PLAYER), *args],
            env=self.env,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        status = json.loads(completed.stdout)
        return completed.returncode, status

    def test_command_process_is_reused(self):
        code, status = self.run_player("status")
        self.assertEqual(code, 0)
        self.assertFalse(status["running"])
        pid_file = self.runtime / "mattia.radio" / "player-command.pid"
        first = pid_file.read_text()
        code, status = self.run_player("status")
        self.assertEqual(code, 0)
        self.assertEqual(pid_file.read_text(), first)
        self.assertFalse((self.runtime / "mattia.radio" / "player.pid").exists())

    def test_literal_loopback_never_starts_the_player(self):
        code, status = self.run_player("play", STATION, "Loop", "http://127.0.0.1:9/stream")
        self.assertEqual(code, 3)
        self.assertFalse(status["running"])
        self.assertFalse((self.runtime / "mattia.radio" / "player.pid").exists())

    def test_localhost_is_refused_by_the_proxy(self):
        accepted = []
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.bind(("127.0.0.1", 0))
        server.listen()
        port = server.getsockname()[1]
        thread = threading.Thread(target=self._accept, args=(server, accepted), daemon=True)
        thread.start()
        try:
            code, status = self.run_player(
                "play", STATION, "Loop", f"http://localhost:{port}/stream", timeout=20
            )
        finally:
            server.close()
        self.assertNotEqual(code, 0)
        self.assertTrue(status["error"])
        self.assertFalse(status["running"] and not status["idle"] and not status["error"])
        log = (self.runtime / "mattia.radio" / "proxy.log").read_text()
        self.assertIn("outcome=forbidden", log)
        thread.join(0.3)
        self.assertEqual(accepted, [])
        code, status = self.run_player("stop")
        self.assertEqual(code, 0)
        self.assertFalse(status["running"])

    def test_sandbox_can_open_the_audio_device(self):
        session = PLUGIN / "radio-session"
        completed = subprocess.run(
            [
                str(session),
                "mpv",
                "--no-config",
                "--ao=pipewire",
                "--no-video",
                "--really-quiet",
                "--length=0.2",
                "av://lavfi:anullsrc=r=48000:cl=mono",
            ],
            env=self.env,
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    @staticmethod
    def _accept(server, accepted):
        server.settimeout(0.5)
        try:
            connection, _ = server.accept()
        except OSError:
            return
        accepted.append(True)
        connection.close()


if __name__ == "__main__":
    unittest.main()
