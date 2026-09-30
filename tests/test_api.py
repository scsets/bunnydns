# Filename: test_api.py
# Description: Tests of the Bunny API client against the fake API and its faults.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-09-30 Wed 00:00
# Version: 0.1.0
# Last-Updated: 2026-09-30 Wed 00:00
# Update #: 1

import os
import platform
import signal
import subprocess
import sys
import time
import unittest

from support import API_KEY, PROJECT_DIR, BunnyTestCase, bunnydns, record


class ClientTests(BunnyTestCase):
    def setUp(self):
        super().setUp()
        self.client = bunnydns.BunnyClient(API_KEY, self.fake.url)

    def assert_fails(self, call, message):
        with self.assertRaises(bunnydns.BunnyDNSError) as caught:
            call()
        self.assertEqual(str(caught.exception), message)

    def test_search_keeps_only_exact_names(self):
        # "example.test" is a substring of the decoy "mirror-example.test".
        self.assertEqual(self.client.search_zones("EXAMPLE.test"), [{"Id": 42, "Domain": "example.test"}])
        self.fake.zones[44] = {"Id": 44, "Domain": "Example.Test"}
        self.assertEqual(len(self.client.search_zones("example.test")), 2)
        self.assertIn(("GET", "/dnszone?page=1&perPage=1000&search=example.test&view=0"), self.fake.requests)

    def test_records_are_read_page_by_page(self):
        self.fake.page_size = 2
        self.fake.records[42] = [record(n, "A", f"host{n}", f"192.0.2.{n}") for n in range(1, 6)]
        zone = self.client.get_zone(42, "example.test")
        self.assertEqual([item["Id"] for item in zone["Records"]], [1, 2, 3, 4, 5])
        self.assertEqual(sum(path.startswith("/dnszone/42/records?page=") for _, path in self.fake.requests), 3)

    def test_zone_document_and_record_checks(self):
        self.assert_fails(lambda: self.client.get_zone(43, "example.test"), "Bunny returned an invalid zone document")
        self.fake.records[42] = [record(1, "A", "a", "192.0.2.1"), record(1, "A", "b", "192.0.2.2")]
        self.assert_fails(lambda: self.client.get_zone(42, "example.test"), "Bunny returned duplicate or invalid record IDs")
        self.fake.records[42] = [record(1, "A", "a", "192.0.2.1", Type="A")]
        self.assert_fails(lambda: self.client.get_zone(42, "example.test"), "Bunny returned an invalid record (ID 1)")

    def test_total_changing_between_pages_is_an_error(self):
        self.fake.page_size = 1
        self.fake.total_items_drift = True
        self.fake.records[42] = [record(1, "A", "a", "192.0.2.1"), record(2, "A", "b", "192.0.2.2")]
        self.assert_fails(lambda: self.client.get_zone(42, "example.test"),
                          "the Bunny record list changed while it was read; retry")

    def test_writes_use_bunnys_methods_and_accept_204(self):
        added = self.client.add_record(42, bunnydns.new_record_body({"Type": 0, "Name": "www", "Value": "192.0.2.1"}))
        self.assertIsNone(self.client.update_record(42, added["Id"], {**added, "Ttl": 300}))
        self.assertIsNone(self.client.delete_record(42, added["Id"]))
        self.assertEqual(self.fake.writes(), [("PUT", "/dnszone/42/records"), ("POST", "/dnszone/42/records/1"),
                                              ("DELETE", "/dnszone/42/records/1")])

    def test_error_responses(self):
        body = bunnydns.new_record_body({"Type": 0, "Name": "www", "Value": "192.0.2.1"})
        self.fake.reject_adds = True
        self.assert_fails(lambda: self.client.add_record(42, body), "Invalid address (HTTP 400)")
        self.fake.records[42] = [record(1, "A", "www", "192.0.2.1")]
        self.fake.fail_updates = True
        self.assert_fails(lambda: self.client.update_record(42, 1, body), "Service unavailable (HTTP 503)")
        self.assert_fails(lambda: self.client.delete_record(42, 99), "Not found. (HTTP 404)")
        self.fake.unauthorized = True
        self.assert_fails(lambda: self.client.search_zones("example.test"), "Unauthorized. Check your API key. (HTTP 401)")

    def test_non_json_success_is_an_error(self):
        self.fake.non_json = True
        with self.assertRaisesRegex(bunnydns.BunnyDNSError, r"non-JSON response \(HTTP 200, content-type text/html\); a proxy"):
            self.client.search_zones("example.test")

    def test_connection_failures(self):
        self.fake.drop_connections = True
        with self.assertRaisesRegex(bunnydns.BunnyDNSError, "^cannot reach the Bunny API: "):
            self.client.search_zones("example.test")
        self.fake.close()
        with self.assertRaisesRegex(bunnydns.BunnyDNSError, "^cannot reach the Bunny API: "):
            self.client.search_zones("example.test")

    def test_command_reports_api_errors(self):
        self.fake.unauthorized = True
        result = self.run_cli("list", "example.test")
        self.assertEqual((result.status, result.stderr), (1, "bunnydns: Unauthorized. Check your API key. (HTTP 401)\n"))


class HelperTests(unittest.TestCase):
    def test_key_goes_only_to_bunny_or_loopback(self):
        for url in ("https://api.bunny.net", "http://127.0.0.1:8080", "http://[::1]:8080"):
            self.assertTrue(bunnydns.check_base_url(url))
        for url in ("https://example.com", "http://10.0.0.1", "https://api.bunny.net.example.com", "http://localhost:80"):
            with self.subTest(url), self.assertRaisesRegex(bunnydns.BunnyDNSError, "refusing to send the Bunny API key"):
                bunnydns.check_base_url(url)

    def test_smartos_ca_bundle(self):
        present = {"/opt/local/etc/openssl/certs/ca-certificates.crt"}
        override = bunnydns.ca_bundle_override
        self.assertEqual(override("SunOS", {}, present.__contains__), "/opt/local/etc/openssl/certs/ca-certificates.crt")
        self.assertEqual(override("SunOS", {}, lambda path: True), bunnydns.PKGSRC_CA_BUNDLES[0])  # global zone first
        self.assertIsNone(override("SunOS", {"SSL_CERT_FILE": "/etc/my.pem"}, lambda path: True))
        self.assertIsNone(override("SunOS", {}, lambda path: False))
        self.assertIsNone(override("Darwin", {}, lambda path: True))

    def test_error_messages(self):
        message = bunnydns.api_error_message
        self.assertEqual(message(400, b'{"Message": "Bad value"}'), "Bad value (HTTP 400)")
        self.assertEqual(message(422, b'{"title": "Invalid", "detail": "TTL too low"}'), "TTL too low (HTTP 422)")
        self.assertEqual(message(409, b""), "Conflict. The resource already exists or is in use. (HTTP 409)")
        self.assertEqual(message(500, b"<html>"), "Internal server error. (HTTP 500)")
        self.assertEqual(message(502, b""), "Bunny API request failed (HTTP 502)")

    def test_page_checks(self):
        def pages(*documents):
            return lambda page: documents[page - 1]

        def page(items, current, total, more):
            return {"Items": items, "CurrentPage": current, "TotalItems": total, "HasMoreItems": more}

        collect = bunnydns.collect_pages
        self.assertEqual(collect(pages(page([1], 1, 2, True), page([2], 2, 2, False)), "zone list"), [1, 2])
        cases = {
            "Bunny returned an invalid zone list page": pages(page([1], 2, 1, False)),
            "Bunny zone list pagination made no progress": pages(page([], 1, 1, True)),
            "the Bunny zone list was incomplete; retry": pages(page([1], 1, 2, False)),
        }
        for message, fetch in cases.items():
            with self.subTest(message), self.assertRaises(bunnydns.BunnyDNSError) as caught:
                collect(fetch, "zone list")
            self.assertEqual(str(caught.exception), message)


@unittest.skipIf(platform.system() == "SunOS", "uses the XDG layout")
class SignalTests(BunnyTestCase):
    def test_hup_int_and_term_exit_with_130(self):
        xdg_key = self.root / "xdg" / "bunnydns" / "api-key"
        xdg_key.parent.mkdir(parents=True)
        xdg_key.write_text(API_KEY + "\n")
        xdg_key.chmod(0o600)
        environment = {**os.environ, "XDG_CONFIG_HOME": str(self.root / "xdg"), "PYTHONDONTWRITEBYTECODE": "1"}
        self.fake.delay = 5
        script = ("import signal, sys; sys.path.insert(0, sys.argv[1]); import bunnydns; "
                  "signal.signal(signal.SIGHUP, bunnydns.interrupt); signal.signal(signal.SIGTERM, bunnydns.interrupt); "
                  "sys.exit(bunnydns.main(sys.argv[3:], api_base_url=sys.argv[2]))")
        for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=number.name):
                count = len(self.fake.requests)
                process = subprocess.Popen([sys.executable, "-c", script, str(PROJECT_DIR), self.fake.url,
                                            "list", "example.test"],
                                           env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                deadline = time.monotonic() + 10
                while len(self.fake.requests) == count and time.monotonic() < deadline:
                    time.sleep(0.02)
                process.send_signal(number)
                _, stderr = process.communicate(timeout=10)
                self.assertEqual((process.returncode, stderr), (130, "bunnydns: interrupted\n"))


if __name__ == "__main__":
    unittest.main()
