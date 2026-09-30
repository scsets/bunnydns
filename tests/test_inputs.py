# Filename: test_inputs.py
# Description: Tests of records, properties, settings, the key file, and init-key.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-09-30 Wed 00:00
# Version: 0.1.0
# Last-Updated: 2026-09-30 Wed 00:00
# Update #: 1

import os
import platform
import stat
import subprocess
import sys
import unittest
from unittest import mock

from support import API_KEY, PROJECT_DIR, BunnyTestCase, bunnydns

GOOD = {"owner": "project-one", "zone": "Example.COM",
        "records": [{"key": "web", "type": "a", "name": "@", "value": "192.0.2.1"}]}


class RecordsTests(unittest.TestCase):
    def test_normalizes_names_defaults_and_ownership(self):
        records = bunnydns.normalize_records(GOOD)
        self.assertEqual(records["zone"], "example.com")
        self.assertEqual(records["records"], [{
            "Key": "web", "AllowMultiple": False, "Comment": "managed-by:project-one; key=web",
            "Type": 0, "Name": "", "Value": "192.0.2.1", "Ttl": 60, "Priority": 0, "Weight": 0,
            "Port": 0, "Flags": 0, "Tag": "", "Disabled": False,
        }])
        nulls = {**GOOD, "records": [{**GOOD["records"][0], "ttl": None, "tag": None, "disabled": None}]}
        self.assertEqual(bunnydns.normalize_records(nulls)["records"][0]["Ttl"], 60)

    def test_rejects_invalid_documents(self):
        entry = GOOD["records"][0]
        cases = {
            "the records file must contain a JSON object": [],
            "backup_dir is not a known field": {**GOOD, "backup_dir": "/b"},
            "owner must be": {**GOOD, "owner": "Project"},
            "owner must be ": {**GOOD, "owner": "x" * 65},
            "zone is not a valid DNS zone name": {**GOOD, "zone": "localhost"},
            "records must be an array": {**GOOD, "records": {}},
            "records[0] must be an object": {**GOOD, "records": ["web"]},
            "records[0].allow_multi is not a known field": {**GOOD, "records": [{**entry, "allow_multi": True}]},
            "records[0].key must be": {**GOOD, "records": [{**entry, "key": "Web"}]},
            "records[0].type must be one of": {**GOOD, "records": [{**entry, "type": "SPF"}]},
            "records[0].name is required": {**GOOD, "records": [{key: value for key, value in entry.items() if key != "name"}]},
            "records[0].name must be @ or": {**GOOD, "records": [{**entry, "name": "bad name"}]},
            "records[0].value must be a non-empty string": {**GOOD, "records": [{**entry, "value": ""}]},
            "records[0].ttl must be an integer from 1": {**GOOD, "records": [{**entry, "ttl": 0}]},
            "records[0].flags must be an integer from 0 to 255": {**GOOD, "records": [{**entry, "flags": 256}]},
            "records[0].weight must be an integer": {**GOOD, "records": [{**entry, "weight": True}]},
            "records[0].tag must be a string": {**GOOD, "records": [{**entry, "tag": 1}]},
            "records[0].allow_multiple must be true or false": {**GOOD, "records": [{**entry, "allow_multiple": "yes"}]},
            "record keys must be unique": {**GOOD, "records": [entry, entry]},
        }
        for message, document in cases.items():
            with self.subTest(message), self.assertRaises(bunnydns.BunnyDNSError) as caught:
                bunnydns.normalize_records(document)
            self.assertTrue(str(caught.exception).startswith(message), str(caught.exception))

    def test_properties(self):
        parsed = bunnydns.parse_properties("update", ["type=aaaa", "name=@", "ttl=300", "tag=", "disabled=true",
                                                      "value=v=spf1 -all"], list(bunnydns.PROPERTIES))
        self.assertEqual(parsed, {"type": "aaaa", "name": "@", "ttl": 300, "tag": "", "disabled": True,
                                  "value": "v=spf1 -all"})
        self.assertEqual(bunnydns.parse_properties("update", ["ttl=²", "disabled=yes"], ["ttl", "disabled"]),
                         {"ttl": "²", "disabled": "yes"})  # left for convert_property to reject
        self.assertEqual(bunnydns.convert_property("type", "aaaa"), 1)
        self.assertEqual(bunnydns.convert_property("name", "@"), "")


class SiteTests(unittest.TestCase):
    def test_smartos_uses_the_illumos_layout(self):
        self.assertEqual(bunnydns.site_dirs("SunOS", {}, lambda: "global"), ("/opt/custom/etc/bunnydns", "/var/opt/bunnydns"))
        self.assertEqual(bunnydns.site_dirs("SunOS", {}, lambda: "web01"), ("/opt/local/etc/bunnydns", "/var/opt/bunnydns"))

    def test_other_systems_follow_xdg(self):
        def never():
            raise AssertionError("zonename is only for SmartOS")

        self.assertEqual(bunnydns.site_dirs("Darwin", {"HOME": "/Users/u"}, never),
                         ("/Users/u/.config/bunnydns", "/Users/u/.local/state/bunnydns"))
        environ = {"HOME": "/home/u", "XDG_CONFIG_HOME": "/cfg", "XDG_STATE_HOME": "/st"}
        self.assertEqual(bunnydns.site_dirs("Linux", environ, never), ("/cfg/bunnydns", "/st/bunnydns"))
        relative = {"HOME": "/home/u", "XDG_CONFIG_HOME": "cfg", "XDG_STATE_HOME": ""}
        self.assertEqual(bunnydns.site_dirs("Linux", relative, never),
                         ("/home/u/.config/bunnydns", "/home/u/.local/state/bunnydns"))


class SettingsTests(BunnyTestCase):
    def test_defaults_without_a_settings_file(self):
        self.assertEqual(bunnydns.load_settings(), {"key_file": str(self.key_file), "backup_dir": str(self.backup_dir)})

    def test_settings_file(self):
        self.settings("# comment\n\n  key_file = /k/api-key\n")
        self.assertEqual(bunnydns.load_settings(), {"key_file": "/k/api-key", "backup_dir": str(self.backup_dir)})
        for text, message in (("owner=me\n", "line 1: unknown or repeated setting: owner"),
                              ("backup_dir\n", "line 1: backup_dir must be an absolute path"),
                              ("key_file=/a\nkey_file=/b\n", "line 2: unknown or repeated setting: key_file")):
            with self.subTest(text=text):
                self.settings(text)
                with self.assertRaisesRegex(bunnydns.BunnyDNSError, message):
                    bunnydns.load_settings()


class KeyFileTests(BunnyTestCase):
    def assert_key_error(self, path, message):
        with self.assertRaises(bunnydns.BunnyDNSError) as caught:
            bunnydns.read_api_key(str(path))
        self.assertIn(message, str(caught.exception))

    def test_reads_one_protected_line(self):
        self.assertEqual(bunnydns.read_api_key(str(self.key_file)), API_KEY)

    def test_storage_rules(self):
        self.assert_key_error("relative/key", "key_file must be an absolute path")
        self.assert_key_error(self.root / "missing", "no API key; run bunnydns init-key")
        self.assert_key_error(self.root, "must be a regular file")
        link = self.root / "link"
        link.symlink_to(self.key_file)
        self.assert_key_error(link, "must not be a symbolic link")
        self.key_file.chmod(0o640)
        self.assert_key_error(self.key_file, "must have mode 0400 or 0600, not 0640")

    def test_content_rules(self):
        for content, message in ((b"", "is empty"), (b"\n", "is empty"), (b"a\nb\n", "exactly one line"),
                                 (b"key\r\n", "exactly one line"), (b"k\xc3\xa9y\n", "printable ASCII"),
                                 (b"k\tey", "printable ASCII"), (b" key\n", "start or end with a space")):
            with self.subTest(content=content):
                self.key_file.chmod(0o600)
                self.key_file.write_bytes(content)
                self.assert_key_error(self.key_file, message)


class InitKeyTests(BunnyTestCase):
    def init_key(self, secret="new-secret-key"):
        with mock.patch.object(bunnydns, "require_terminal"), \
                mock.patch.object(bunnydns, "read_secret", return_value=secret):
            return self.run_cli("init-key")

    def test_creates_a_private_key_file_in_a_private_directory(self):
        path = self.root / "new" / "api-key"
        self.settings(f"key_file={path}\n")
        self.assert_result(self.init_key(), 0, f"Stored the API key in {path} (mode 0600).")
        self.assertEqual(path.read_text(), "new-secret-key\n")
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        self.assertEqual(bunnydns.read_api_key(str(path)), "new-secret-key")

    def test_refusals(self):
        self.assert_result(self.init_key(), 1, f"{self.key_file} already exists; remove it first")
        self.key_file.unlink()
        self.assert_result(self.init_key(" padded"), 1, "must not start or end with a space")
        self.assertFalse(self.key_file.exists())
        self.assert_result(self.run_cli("init-key", "/some/path"), 2, "too many operands")

    @unittest.skipIf(platform.system() == "SunOS", "uses the XDG layout")
    def test_requires_a_terminal(self):
        # A new session has no controlling terminal, so /dev/tty cannot be opened.
        environment = {**os.environ, "XDG_CONFIG_HOME": str(self.root / "xdg"), "PYTHONDONTWRITEBYTECODE": "1"}
        result = subprocess.run([sys.executable, str(PROJECT_DIR / "bunnydns.py"), "init-key"], env=environment,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, start_new_session=True)
        self.assertEqual((result.returncode, result.stderr), (1, "bunnydns: init-key needs an interactive terminal\n"))
        self.assertFalse((self.root / "xdg").exists())


if __name__ == "__main__":
    unittest.main()
