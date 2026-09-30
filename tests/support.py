# Filename: support.py
# Description: Fake Bunny DNS API and shared helpers for the bunnydns tests.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-09-30 Wed 00:00
# Version: 0.1.0
# Last-Updated: 2026-09-30 Wed 00:00
# Update #: 1

"""Test helpers: a fake Bunny API on 127.0.0.1 and a TestCase that uses it.

The tests never contact the real Bunny API: every command runs in-process
through bunnydns.main() with api_base_url pointing at FakeBunny, and the
settings and state directories point into a temporary directory.
"""

import copy
import io
import json
import shutil
import sys
import tempfile
import threading
import time
import unittest
from collections import namedtuple
from contextlib import nullcontext, redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlsplit

PROJECT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_DIR))

import bunnydns  # noqa: E402  (needs the path above)

API_KEY = "test-bunny-api-key"
ZONE_ID = 42


def record(record_id, type_name, name, value, comment="", ttl=300, **extra):
    """A Bunny record as the API returns it."""
    return {
        "Id": record_id, "Type": bunnydns.RECORD_TYPES[type_name], "Ttl": ttl, "Value": value, "Name": name,
        "Weight": 0, "Priority": 0, "Flags": 0, "Tag": "", "Port": 0, "Disabled": False, "Comment": comment,
        **extra,
    }


class FakeBunny:
    """A stateful stand-in for the Bunny DNS API.

    It serves example.test (ID 42) and the decoy mirror-example.test (ID 43),
    which Bunny's substring search also returns.  Tests edit self.records
    directly and read self.requests to see what was called.

    Fault switches, all off by default:
      lowercase_names    store names lowercased, as Bunny may normalize them
      add_value_drift    store this Value instead of the submitted one on add
      drop_routing       forget SmartRoutingType on add and update
      fail_updates       answer updates with 503 and a Message
      total_items_drift  report one more item on every page after the first
      unauthorized       answer everything with 401 and an empty body
      reject_adds        answer adds with 400 and a Message
      non_json           answer everything with a 200 HTML page
      drop_connections   close each connection without answering
      delay              seconds to wait before answering
    """

    def __init__(self, page_size=1000):
        self.page_size = page_size
        self.zones = {ZONE_ID: {"Id": ZONE_ID, "Domain": "example.test"},
                      43: {"Id": 43, "Domain": "mirror-example.test"}}
        self.records = {ZONE_ID: [], 43: []}
        self.requests = []  # (method, path) pairs
        self.headers = []  # the headers of each request, with lowercase names
        self.lowercase_names = self.drop_routing = self.fail_updates = False
        self.total_items_drift = self.unauthorized = self.reject_adds = False
        self.non_json = self.drop_connections = False
        self.add_value_drift = None
        self.delay = 0
        self.lock = threading.Lock()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self.server.fake = self
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, args=(0.01,), daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def writes(self):
        return [request for request in self.requests if request[0] != "GET"]

    def respond(self, method, path, headers, body):
        """Return (status, document); a str document is sent as HTML, None as no body."""
        with self.lock:
            self.requests.append((method, path))
            self.headers.append({name.lower(): value for name, value in headers.items()})
            if self.unauthorized or headers.get("AccessKey") != API_KEY:
                return 401, None
            if self.non_json:
                return 200, "<html><body>Captive portal</body></html>"
            parts = urlsplit(path)
            query = {name: values[0] for name, values in parse_qs(parts.query).items()}
            route = parts.path.strip("/").split("/")
            if route == ["dnszone"] and method == "GET":
                search = query["search"].lower()
                return self._page([zone for zone in self.zones.values() if search in zone["Domain"].lower()], query)
            zone_id = int(route[1]) if len(route) > 1 and route[1].isdigit() else None
            if zone_id not in self.zones:
                return 404, None
            records = self.records[zone_id]
            if len(route) == 2 and method == "GET":
                return 200, {**self.zones[zone_id], "Records": copy.deepcopy(records)}
            if route[2:] == ["records"] and method == "GET":
                return self._page(copy.deepcopy(records), query)
            if route[2:] == ["records"] and method == "PUT":
                return self._add(records, body)
            ids = [item["Id"] for item in records]
            if len(route) == 4 and route[3].isdigit() and int(route[3]) in ids:
                index = ids.index(int(route[3]))
                if method == "POST":
                    if self.fail_updates:
                        return 503, {"Message": "Service unavailable"}
                    records[index] = self._stored({**body, "Id": ids[index]})
                    return 204, None
                if method == "DELETE":
                    del records[index]
                    return 204, None
            return 404, None

    def _page(self, items, query):
        page, size = int(query["page"]), min(int(query["perPage"]), self.page_size)
        start = (page - 1) * size
        total = len(items) + (1 if self.total_items_drift and page > 1 else 0)
        return 200, {"Items": items[start:start + size], "CurrentPage": page,
                     "TotalItems": total, "HasMoreItems": start + size < len(items)}

    def _add(self, records, body):
        if self.reject_adds:
            return 400, {"Message": "Invalid address", "Field": "Value"}
        new = self._stored({"AutoSslIssuance": True, **body, "Id": max([0] + [r["Id"] for r in records]) + 1})
        if self.add_value_drift:
            new["Value"] = self.add_value_drift
        records.append(new)
        return 201, new

    def _stored(self, item):
        if self.lowercase_names:
            item["Name"] = item["Name"].lower()
        if self.drop_routing:
            item.pop("SmartRoutingType", None)
        return item


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # keep test output quiet

    def _dispatch(self):
        fake = self.server.fake
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length)) if length else None
        status, document = fake.respond(self.command, self.path, self.headers, body)
        time.sleep(fake.delay)
        if fake.drop_connections:
            self.close_connection = True
            return
        payload, content_type = b"", "application/json"
        if isinstance(document, str):
            payload, content_type = document.encode(), "text/html"
        elif document is not None:
            payload = json.dumps(document).encode()
        self.send_response(status)
        if payload:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_PUT = do_POST = do_DELETE = _dispatch


class Result(namedtuple("Result", "status stdout stderr")):
    @property
    def output(self):
        return self.stdout + self.stderr


class BunnyTestCase(unittest.TestCase):
    """Gives each test private settings and state directories, a key, and a FakeBunny."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="bunnydns-test."))
        self.addCleanup(shutil.rmtree, self.root)
        self.settings_dir = self.root / "etc"
        self.settings_dir.mkdir()
        self.state_dir = self.root / "state"
        self.key_file = self.settings_dir / "api-key"
        self.key_file.write_text(API_KEY + "\n")
        self.key_file.chmod(0o600)
        self.backup_dir = self.state_dir / "backups"
        site = mock.patch.object(bunnydns, "site_dirs", return_value=(str(self.settings_dir), str(self.state_dir)))
        site.start()
        self.addCleanup(site.stop)
        self.fake = FakeBunny()
        self.addCleanup(self.fake.close)

    @property
    def zone(self):
        return self.fake.records[ZONE_ID]

    def find(self, record_id):
        return next((item for item in self.zone if item["Id"] == record_id), None)

    def run_cli(self, *args, stdin=None):
        """Run bunnydns in-process; STDIN, if given, replaces standard input."""
        stdout, stderr = io.StringIO(), io.StringIO()
        replace_stdin = mock.patch.object(sys, "stdin", io.StringIO(stdin)) if stdin is not None else nullcontext()
        with redirect_stdout(stdout), redirect_stderr(stderr), replace_stdin:
            status = bunnydns.main([str(arg) for arg in args], api_base_url=self.fake.url)
        return Result(status, stdout.getvalue(), stderr.getvalue())

    def settings(self, text):
        (self.settings_dir / "bunnydns.conf").write_text(text)

    def records_file(self, records, name="records.json", **settings):
        path = self.root / name
        path.write_text(json.dumps({"owner": "project-one", "zone": "example.test", "records": records, **settings}))
        return path

    def backups(self):
        return sorted(self.backup_dir.glob("*.json")) if self.backup_dir.exists() else []

    def assert_result(self, result, status, *needles):
        self.assertEqual(result.status, status, result.output)
        for needle in needles:
            self.assertIn(needle, result.output)
