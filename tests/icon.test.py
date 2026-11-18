#!/usr/bin/env python3
"""Station logos are fetched only from public addresses and stored locally."""

import importlib.machinery
import importlib.util
import json
import os
import socket
import stat
import tempfile
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


def make_cache():
    """A private directory this test created. The name is not predictable."""
    root = Path(tempfile.mkdtemp(prefix="radio-icon-"))
    info = root.lstat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid():
        raise RuntimeError("icon test cache is not a private directory")
    return root


def remove_cache(root):
    """Remove root only when it is still the private directory this test created."""
    root = Path(root)
    try:
        info = root.lstat()
    except FileNotFoundError:
        return
    temp_root = Path(tempfile.gettempdir()).resolve()
    owned = (
        stat.S_ISDIR(info.st_mode)
        and not stat.S_ISLNK(info.st_mode)
        and info.st_uid == os.getuid()
        and root.name.startswith("radio-icon-")
        and root.parent.resolve() == temp_root
    )
    if not owned:
        return
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        current = os.fstat(fd)
        if current.st_ino != info.st_ino or current.st_dev != info.st_dev:
            return
        for name in os.listdir(fd):
            _remove_entry(fd, name)
    finally:
        os.close(fd)
    try:
        again = root.lstat()
    except FileNotFoundError:
        return
    if again.st_ino != info.st_ino or again.st_dev != info.st_dev or stat.S_ISLNK(again.st_mode):
        return
    os.rmdir(root)


def _remove_entry(dir_fd, name):
    try:
        info = os.lstat(name, dir_fd=dir_fd)
    except OSError:
        return
    if stat.S_ISLNK(info.st_mode) or stat.S_ISREG(info.st_mode):
        os.unlink(name, dir_fd=dir_fd)
        return
    if not stat.S_ISDIR(info.st_mode):
        return
    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)
    try:
        for entry in os.listdir(child):
            _remove_entry(child, entry)
    finally:
        os.close(child)
    os.rmdir(name, dir_fd=dir_fd)


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
    def setUp(self):
        self.root = make_cache()

    def tearDown(self):
        remove_cache(self.root)

    def test_a_public_image_is_stored_under_its_hash(self):
        root = self.root
        calls = []

        def fetch(url):
            calls.append(url)
            return "png", PNG

        state = icon.sync(str(root), [LOGO, LOGO], fetch=fetch)
        icon.sync(str(root), [LOGO], fetch=fetch)
        name = state["icons"][LOGO]
        self.assertEqual(calls, [LOGO])
        self.assertTrue(name.endswith(".png"))
        self.assertEqual((root / "icons" / name).read_bytes(), PNG)
        self.assertEqual(load_saved(root)["icons"][LOGO], name)

    def test_a_non_image_is_blocked_and_not_stored(self):
        root = self.root

        def fetch(url):
            return "png", b"<html>no</html>"

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

    def test_urls_come_from_the_saved_station_files(self):
        root = self.root
        favorites = root / "favorites.json"
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

    def test_logos_outside_the_current_directory_are_deleted_and_the_cap_holds(self):
        root = self.root
        old = "https://cdn.example/old.png"
        urls = [f"https://cdn.example/{name}.png" for name in ("one", "two", "three")]
        cap = len(PNG) * 2
        original = icon.CACHE_MAX_BYTES
        icon.CACHE_MAX_BYTES = cap

        def fetch(url):
            return "png", PNG

        try:
            icon.sync(str(root), [old], fetch=fetch)
            self.assertIn(old, load_saved(root)["icons"])
            state = icon.sync(str(root), urls, fetch=fetch)
            self.assertNotIn(old, state["icons"])
            self.assertNotIn(old, state["blocked"])
            self.assertEqual(len(state["icons"]), 2)
            stored = list((root / "icons").iterdir())
            self.assertEqual(len(stored), 2)
            self.assertLessEqual(sum(path.stat().st_size for path in stored), cap)
            names = {path.name for path in stored}
            self.assertTrue(all(name in state["icons"].values() for name in names))
        finally:
            icon.CACHE_MAX_BYTES = original

    def test_a_linked_cache_is_left_alone(self):
        decoy = make_cache()
        marker = decoy / "keep.txt"
        marker.write_text("keep")
        link_parent = make_cache()
        link = link_parent / "cache"
        link.symlink_to(decoy)
        try:
            with self.assertRaises(OSError):
                icon.sync(str(link), [LOGO], fetch=lambda url: ("png", PNG))
            self.assertEqual(marker.read_text(), "keep")
            self.assertEqual([path.name for path in decoy.iterdir()], ["keep.txt"])
            self.assertTrue(link.is_symlink())
        finally:
            link.unlink()
            remove_cache(decoy)
            remove_cache(link_parent)

    def test_a_linked_icon_directory_is_left_alone(self):
        decoy = make_cache()
        marker = decoy / "keep.txt"
        marker.write_text("keep")
        icons = self.root / "icons"
        icons.symlink_to(decoy)
        try:
            with self.assertRaises(OSError):
                icon.sync(str(self.root), [LOGO], fetch=lambda url: ("png", PNG))
            self.assertEqual(marker.read_text(), "keep")
            self.assertEqual([path.name for path in decoy.iterdir()], ["keep.txt"])
            self.assertFalse((self.root / "icons.json").exists())
            self.assertTrue(icons.is_symlink())
        finally:
            icons.unlink()
            remove_cache(decoy)

    def test_entries_the_plugin_did_not_create_stay(self):
        root = self.root

        def fetch(url):
            return "png", PNG

        icon.sync(str(root), [LOGO], fetch=fetch)
        icons = root / "icons"
        note = icons / "notes.txt"
        note.write_text("leave me")
        nested = icons / "other"
        nested.mkdir()
        (nested / "inside.txt").write_text("inside")
        alias = icons / "alias"
        alias.symlink_to(note)
        linked_logo = icons / ("cd" * 32 + ".png")
        linked_logo.symlink_to(note)
        old_logo = icons / ("ab" * 32 + ".png")
        old_logo.write_bytes(PNG)
        icon.sync(str(root), [LOGO], fetch=fetch)
        self.assertEqual(note.read_text(), "leave me")
        self.assertEqual((nested / "inside.txt").read_text(), "inside")
        self.assertTrue(alias.is_symlink())
        self.assertTrue(linked_logo.is_symlink())
        self.assertEqual(linked_logo.read_text(), "leave me")
        self.assertFalse(old_logo.exists())
        saved = load_saved(root)["icons"][LOGO]
        self.assertTrue((icons / saved).is_file())

    def test_cleanup_does_not_follow_a_replaced_directory(self):
        decoy = make_cache()
        marker = decoy / "keep.txt"
        marker.write_text("keep")
        try:
            info = self.root.lstat()
            os.rmdir(self.root)
            os.symlink(decoy, self.root)
            remove_cache(self.root)
            self.assertTrue(marker.is_file())
            self.assertEqual(marker.read_text(), "keep")
            self.assertEqual(decoy.lstat().st_ino, decoy.stat().st_ino)
            self.assertTrue(self.root.is_symlink())
            self.assertNotEqual(self.root.lstat().st_ino, info.st_ino)
        finally:
            if self.root.is_symlink():
                self.root.unlink()
            remove_cache(decoy)


if __name__ == "__main__":
    unittest.main()
