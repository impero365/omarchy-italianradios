#!/usr/bin/env python3
"""The player reaches streams only through the public-address proxy."""

import importlib.machinery
import importlib.util
import io
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
OTHER = "22222222-2222-4222-8222-222222222222"


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
        pid_file = self.runtime / "impero365.radio-italia" / "player-command.pid"
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
        pid_file = self.runtime / "impero365.radio-italia" / "player-command.pid"
        first = pid_file.read_text()
        code, status = self.run_player("status")
        self.assertEqual(code, 0)
        self.assertEqual(pid_file.read_text(), first)
        self.assertFalse((self.runtime / "impero365.radio-italia" / "player.pid").exists())

    def test_volume_is_remembered_without_starting_playback(self):
        code, status = self.run_player("volume", "40")
        self.assertEqual(code, 0)
        self.assertEqual(status["volume"], 40)
        self.assertFalse(status["running"])
        self.assertFalse((self.runtime / "impero365.radio-italia" / "player.pid").exists())
        code, status = self.run_player("status")
        self.assertEqual(code, 0)
        self.assertEqual(status["volume"], 40)
        code, status = self.run_player("volume", "140")
        self.assertEqual(code, 3)
        self.assertEqual(status["volume"], 40)

    def test_literal_loopback_never_starts_the_player(self):
        code, status = self.run_player("play", STATION, "Loop", "http://127.0.0.1:9/stream")
        self.assertEqual(code, 3)
        self.assertFalse(status["running"])
        self.assertFalse((self.runtime / "impero365.radio-italia" / "player.pid").exists())

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
            deadline = time.time() + 8
            while time.time() < deadline and not status["error"]:
                time.sleep(0.2)
                code, status = self.run_player("status")
        finally:
            server.close()
        self.assertTrue(status["error"])
        self.assertFalse(status["running"] and not status["idle"] and not status["error"])
        log = (self.runtime / "impero365.radio-italia" / "proxy.log").read_text()
        self.assertIn("outcome=forbidden", log)
        thread.join(0.3)
        self.assertEqual(accepted, [])
        code, status = self.run_player("stop")
        self.assertEqual(code, 0)
        self.assertFalse(status["running"])

    def test_second_station_is_sent_before_the_first_stream_opens(self):
        previous = os.environ.get("XDG_RUNTIME_DIR")
        os.environ["XDG_RUNTIME_DIR"] = str(self.runtime)
        listener = None
        try:
            loader = importlib.machinery.SourceFileLoader(
                "radio_playerd", str(PLUGIN / "radio-playerd")
            )
            spec = importlib.util.spec_from_loader(loader.name, loader)
            playerd = importlib.util.module_from_spec(spec)
            loader.exec_module(playerd)
            player = playerd.Player()
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(player.socket_path))
            calls = []

            def ipc(payload, timeout=3):
                command = payload.get("command") or []
                if command and command[0] == "loadfile":
                    calls.append(command[1])
                return {"error": "success", "data": None}

            player.tools_ready = lambda: True
            player.ensure = lambda: True
            player.alive = lambda: True
            player.ipc = ipc
            player.reply = io.StringIO()
            started = time.monotonic()
            slow = playerd.play(player, STATION, "Slow", "https://slow.example/slow")
            fast = playerd.play(player, OTHER, "Fast", "https://fast.example/fast")
            elapsed = time.monotonic() - started
        finally:
            if listener is not None:
                listener.close()
            if previous is None:
                os.environ.pop("XDG_RUNTIME_DIR", None)
            else:
                os.environ["XDG_RUNTIME_DIR"] = previous
        self.assertEqual(slow, 0)
        self.assertEqual(fast, 0)
        self.assertLess(elapsed, 1.5)
        self.assertEqual(calls, ["https://slow.example/slow", "https://fast.example/fast"])
        lines = player.reply.getvalue().strip().splitlines()
        first = json.loads(lines[0])
        last = json.loads(lines[-1])
        self.assertEqual(last["id"], OTHER)
        self.assertTrue(last["starting"])
        self.assertGreater(last["seq"], first["seq"])

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
