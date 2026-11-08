#!/usr/bin/env python3
"""The stream proxy refuses private and local destinations."""

import importlib.machinery
import importlib.util
import ipaddress
import socket
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

PLUGIN = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("radio_proxy", str(PLUGIN / "radio-proxy"))
spec = importlib.util.spec_from_loader(loader.name, loader)
proxy = importlib.util.module_from_spec(spec)
loader.exec_module(proxy)


class AddressPolicy(unittest.TestCase):
    def test_public_addresses_are_allowed(self):
        for text in ("8.8.8.8", "1.1.1.1", "2001:4860:4860::8888", "64:ff9b::808:808"):
            self.assertTrue(proxy.address_allowed(text), text)

    def test_local_and_embedded_local_addresses_are_refused(self):
        for text in (
            "127.0.0.1",
            "10.1.2.3",
            "172.16.0.1",
            "192.168.1.1",
            "169.254.169.254",
            "100.64.0.1",
            "0.0.0.0",
            "224.0.0.1",
            "255.255.255.255",
            "192.0.2.1",
            "198.18.0.1",
            "203.0.113.1",
            "::1",
            "fe80::1",
            "fc00::1",
            "fd12::1",
            "::",
            "64:ff9b::7f00:1",
            "::ffff:127.0.0.1",
            "2002:7f00:1::",
            "2001:db8::1",
        ):
            self.assertFalse(proxy.address_allowed(text), text)

    def test_one_private_answer_refuses_the_name(self):
        answers = [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 80)),
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 80)),
        ]
        with patch.object(proxy.socket, "getaddrinfo", return_value=answers), \
             patch.object(proxy, "route_is_local", return_value=False):
            with self.assertRaises(proxy.ProxyError) as caught:
                proxy.public_endpoints("station.example", 80)
        self.assertEqual(caught.exception.status, b"403 Forbidden")

    def test_a_locally_routed_public_address_is_refused(self):
        answers = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 80))]
        with patch.object(proxy.socket, "getaddrinfo", return_value=answers), \
             patch.object(proxy, "route_is_local", return_value=True):
            with self.assertRaises(proxy.ProxyError) as caught:
                proxy.public_endpoints("station.example", 80)
        self.assertEqual(caught.exception.status, b"403 Forbidden")

    def test_ipv4_is_tried_before_ipv6(self):
        answers = [
            (socket.AF_INET6, socket.SOCK_STREAM, 6, "", ("2001:4860:4860::8888", 80, 0, 0)),
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 80)),
        ]
        with patch.object(proxy.socket, "getaddrinfo", return_value=answers), \
             patch.object(proxy, "route_is_local", return_value=False):
            endpoints = proxy.public_endpoints("station.example", 80)
        self.assertEqual(endpoints[0][3][0], "93.184.216.34")
        self.assertEqual(endpoints[1][3][0], "2001:4860:4860::8888")

    def test_an_unreachable_ipv6_address_leaves_the_ipv4_address(self):
        answers = [
            (socket.AF_INET6, socket.SOCK_STREAM, 6, "", ("2001:4860:4860::8888", 80, 0, 0)),
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 80)),
        ]

        def route(ip):
            if isinstance(ip, ipaddress.IPv6Address):
                raise proxy.RouteUnavailable()
            return False

        with patch.object(proxy.socket, "getaddrinfo", return_value=answers), \
             patch.object(proxy, "route_is_local", side_effect=route):
            endpoints = proxy.public_endpoints("station.example", 80)
        self.assertEqual([endpoint[3][0] for endpoint in endpoints], ["93.184.216.34"])

    def test_connect_uses_the_checked_address(self):
        answers = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 80))]
        created = []

        class FakeSocket:
            def __init__(self, *args):
                created.append(args)
                self.connected = None

            def settimeout(self, _timeout):
                pass

            def connect(self, address):
                self.connected = address

            def close(self):
                pass

        with patch.object(proxy.socket, "getaddrinfo", return_value=answers), \
             patch.object(proxy, "route_is_local", return_value=False), \
             patch.object(proxy.socket, "socket", FakeSocket):
            upstream = proxy.connect_public("station.example", 80)
        self.assertEqual(upstream.connected, ("93.184.216.34", 80))


class LiveProxy(unittest.TestCase):
    def test_loopback_request_is_rejected_without_a_connection(self):
        accepted = []

        def serve(server):
            server.serve_forever(poll_interval=0.05)

        host = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        host.bind(("127.0.0.1", 0))
        host.listen()
        port = host.getsockname()[1]
        thread = threading.Thread(target=self._accept_once, args=(host, accepted), daemon=True)
        thread.start()

        directory = Path(self.id().replace(".", "-"))
        runtime = Path("/tmp") / directory.name
        runtime.mkdir(mode=0o700, exist_ok=True)
        sock_path = runtime / "proxy.sock"
        sock_path.unlink(missing_ok=True)
        server = proxy.ProxyServer(str(sock_path), proxy.ProxyHandler)
        worker = threading.Thread(target=serve, args=(server,), daemon=True)
        worker.start()
        try:
            client = socket.socket(socket.AF_UNIX)
            client.connect(str(sock_path))
            client.sendall(
                f"GET http://127.0.0.1:{port}/stream HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n".encode()
            )
            client.settimeout(2)
            reply = client.recv(256)
            client.close()
            self.assertTrue(reply.startswith(b"HTTP/1.1 403"), reply)
            thread.join(0.3)
            self.assertEqual(accepted, [])
        finally:
            server.shutdown()
            server.server_close()
            host.close()
            sock_path.unlink(missing_ok=True)

    @staticmethod
    def _accept_once(host, accepted):
        host.settimeout(0.2)
        try:
            connection, _ = host.accept()
        except OSError:
            return
        accepted.append(True)
        connection.close()


if __name__ == "__main__":
    unittest.main()
