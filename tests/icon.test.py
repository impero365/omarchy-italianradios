#!/usr/bin/env python3
"""Station logos are fetched only from public addresses and stored locally."""

import importlib.machinery
import importlib.util
import json
import socket
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

PLUGIN = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("radio_icon", str(PLUGIN / "radio-icon"))
spec = importlib.util.spec_from_loader(loader.name, loader)
icon = importlib.util.module_from_spec(spec)
loader.exec_module(icon)

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 24
LOGO = "https://cdn.example/logo.png"


def load_saved(cache):
    path = Path(cache) / "icons.json"
    return json.loads(path.read_text())


class AddressCheck(unittest.TestCase):
    def test_local_addresses_are_refused_before_a_connection(self):
        created = []
        real_socket = icon.proxy.socket.socket

        def record(*args, **kwargs):
            created.append(args)
            return real_socket(*args, **kwargs)

        with patch.object(icon.proxy.socket, "socket", record):
            for url in (
                "https://127.0.0.1/logo.png",
                "https://10.1.2.3/logo.png",
                "https://192.168.1.1/logo.png",
                "https://169.254.169.254/logo.png",
                "https://[::1]/logo.png",
            ):
                with self.assertRaises(icon.IconDenied):
                    icon.fetch_bytes(url)
        self.assertEqual(created, [])

    def test_a_locally_routed_name_is_refused_before_a_connection(self):
        answers = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443))]
        created = []

        def record(*args, **kwargs):
            created.append(args)
            raise AssertionError("connected")

        with patch.object(icon.proxy.socket, "getaddrinfo", return_value=answers), \
             patch.object(icon.proxy, "route_is_local", return_value=True), \
             patch.object(icon.proxy.socket, "socket", record):
            with self.assertRaises(icon.IconDenied):
                icon.fetch_bytes("https://station.example/logo.png")
        self.assertEqual(created, [])

    def test_a_redirect_to_loopback_does_not_connect(self):
        accepted = []
        host = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        host.bind(("127.0.0.1", 0))
        host.listen()
        port = host.getsockname()[1]
        thread = threading.Thread(target=self._accept_once, args=(host, accepted), daemon=True)
        thread.start()

        def send(url):
            if url == LOGO:
                return 302, {"location": f"https://127.0.0.1:{port}/secret.png"}, b""
            return icon.exchange(url)

        try:
            with self.assertRaises(icon.IconDenied):
                icon.fetch_bytes(LOGO, send=send)
            thread.join(0.3)
            self.assertEqual(accepted, [])
        finally:
            host.close()

    def test_a_cleartext_redirect_to_loopback_does_not_connect(self):
        accepted = []
        host = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        host.bind(("127.0.0.1", 0))
        host.listen()
        port = host.getsockname()[1]
        thread = threading.Thread(target=self._accept_once, args=(host, accepted), daemon=True)
        thread.start()

        def send(url):
            if url == LOGO:
                return 302, {"location": f"http://127.0.0.1:{port}/secret.png"}, b""
            return icon.exchange(url)

        try:
            with self.assertRaises(icon.IconDenied):
                icon.fetch_bytes(LOGO, send=send)
            thread.join(0.3)
            self.assertEqual(accepted, [])
        finally:
            host.close()

    def test_an_http_icon_follows_the_https_image(self):
        start = "http://www.radiomaria.org/favicon.ico"
        middle = "https://www.radiomaria.org/favicon.ico"
        image = "https://www.radiomaria.org/wp-content/uploads/logo.png"
        calls = []

        def send(url):
            calls.append(url)
            if url == start:
                return 301, {"location": middle}, b""
            if url == middle:
                return 302, {"location": image}, b""
            if url == image:
                return 200, {"content-type": "image/png"}, PNG
            raise AssertionError(url)

        kind, body = icon.fetch_bytes(start, send=send)
        self.assertEqual(calls, [start, middle, image])
        self.assertEqual(kind, "png")
        self.assertEqual(body, PNG)

    @staticmethod
    def _accept_once(host, accepted):
        host.settimeout(0.2)
        try:
            connection, _ = host.accept()
        except OSError:
            return
        accepted.append(True)
        connection.close()


class Cache(unittest.TestCase):
    def test_a_public_image_is_stored_under_its_hash(self):
        cache = Path(self.id().replace(".", "-"))
        root = Path("/tmp") / cache.name
        calls = []

        def fetch(url):
            calls.append(url)
            return "png", PNG

        try:
            state = icon.sync(str(root), [LOGO, LOGO], fetch=fetch)
            icon.sync(str(root), [LOGO], fetch=fetch)
            name = state["icons"][LOGO]
            self.assertEqual(calls, [LOGO])
            self.assertTrue(name.endswith(".png"))
            self.assertEqual((root / "icons" / name).read_bytes(), PNG)
            self.assertEqual(load_saved(root)["icons"][LOGO], name)
        finally:
            for path in (root / "icons").glob("*"):
                path.unlink()
            for path in (root / "icons.json",):
                path.unlink(missing_ok=True)
            (root / "icons").rmdir()
            root.rmdir()

    def test_a_non_image_is_blocked_and_not_stored(self):
        cache = Path(self.id().replace(".", "-"))
        root = Path("/tmp") / cache.name

        def fetch(url):
            return "png", b"<html>no</html>"

        try:
            state = icon.sync(str(root), [LOGO, "https://user:pass@cdn.example/logo.png"], fetch=fetch)
            self.assertNotIn(LOGO, state["icons"])
            self.assertIn(LOGO, state["blocked"])
            self.assertEqual(list((root / "icons").iterdir()), [])
            calls = []

            def again(url):
                calls.append(url)
                return "png", PNG

            icon.sync(str(root), [LOGO], fetch=again)
            self.assertEqual(calls, [])
        finally:
            for path in (root / "icons").glob("*"):
                path.unlink()
            (root / "icons.json").unlink(missing_ok=True)
            (root / "icons").rmdir()
            root.rmdir()

    def test_urls_come_from_the_saved_station_files(self):
        cache = Path(self.id().replace(".", "-"))
        root = Path("/tmp") / cache.name
        root.mkdir()
        favorites = root / "favorites.json"
        try:
            (root / "stations.json").write_text(json.dumps({
                "stations": [
                    {"icon": LOGO},
                    {"icon": "https://127.0.0.1/logo.png"},
                    {"icon": "file:///tmp/secret.png"},
                ]
            }))
            favorites.write_text(json.dumps({"stations": [{"icon": "https://cdn.example/other.jpg"}]}))
            seen = []

            def fetch(url):
                seen.append(url)
                if url.endswith(".jpg"):
                    return "jpg", b"\xff\xd8\xff" + b"\x00" * 8
                raise icon.IconDenied()

            icon.sync(str(root), icon.icon_urls(str(root / "stations.json")) + icon.icon_urls(str(favorites)), fetch=fetch)
            self.assertEqual(set(seen), {LOGO, "https://127.0.0.1/logo.png", "https://cdn.example/other.jpg"})
            saved = load_saved(root)
            self.assertIn("https://cdn.example/other.jpg", saved["icons"])
            self.assertIn("https://127.0.0.1/logo.png", saved["blocked"])
            self.assertNotIn(LOGO, saved["icons"])
        finally:
            for path in root.glob("*"):
                if path.is_dir():
                    for child in path.glob("*"):
                        child.unlink()
                    path.rmdir()
                else:
                    path.unlink()
            root.rmdir()


if __name__ == "__main__":
    unittest.main()
