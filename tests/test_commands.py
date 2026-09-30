# Filename: test_commands.py
# Description: End-to-end tests of every bunnydns command against a fake Bunny API.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-09-30 Wed 00:00
# Version: 0.1.0
# Last-Updated: 2026-09-30 Wed 00:00
# Update #: 1

import copy
import io
import json
import os
import stat
import sys
import unittest
from unittest import mock

from support import API_KEY, PROJECT_DIR, BunnyTestCase, record

# The zone and records most tests start from: www is an identical unmanaged
# record to adopt, the TXT record is already ours, and "other" is another owner's.
BASE_ZONE = [
    record(101, "A", "www", "192.0.2.10"),
    record(102, "TXT", "", "service-verification=ready", "managed-by:project-one; key=site-verification"),
    record(103, "A", "other", "198.51.100.20", "managed-by:other-project; key=other-origin"),
]
BASE_RECORDS = [
    {"key": "web-origin", "type": "A", "name": "www", "value": "192.0.2.10", "ttl": 300},
    {"key": "site-verification", "type": "TXT", "name": "@", "value": "service-verification=ready", "ttl": 300},
    {"key": "api-origin", "type": "A", "name": "api", "value": "192.0.2.11"},
]
ADVANCED = {
    "Accelerated": True, "AcceleratedPullZoneId": 777, "MonitorType": 2, "SmartRoutingType": 1,
    "GeolocationLatitude": 41.9, "GeolocationLongitude": 12.5, "LatencyZone": "EU",
    "EnviromentalVariables": [{"Name": "REGION", "Value": "eu"}], "AutoSslIssuance": True,
}


def comment(key, owner="project-one"):
    return f"managed-by:{owner}; key={key}"


class GeneralTests(BunnyTestCase):
    def test_no_arguments_print_usage(self):
        result = self.run_cli()
        self.assertEqual(result.status, 2)
        self.assertTrue(result.stderr.startswith("usage: bunnydns list [-H] [-o field,...] zone\n"))
        self.assertEqual(self.fake.requests, [])

    def test_version_and_help(self):
        self.assertEqual(self.run_cli("version").stdout, "bunnydns 0.1.0\n")
        self.assert_result(self.run_cli("help"), 0, "usage: bunnydns list", "Properties: type, name, value",
                           f"Settings: {self.settings_dir}/bunnydns.conf",
                           f"key_file={self.key_file} backup_dir={self.backup_dir}")

    def test_usage_errors_exit_2(self):
        cases = [
            (["frobnicate"], "unknown command: frobnicate", "usage: bunnydns list"),
            (["help", "extra"], "too many operands", "usage: bunnydns help"),
            (["list"], "missing operands", "usage: bunnydns list [-H] [-o field,...] zone"),
            (["list", "-x", "example.test"], "option -x not recognized", "usage: bunnydns list"),
            (["list", "-o", "id,bogus", "example.test"], "unknown field: bogus", "usage: bunnydns list"),
            (["update", "example.test", "101"], "missing operands", "usage: bunnydns update"),
            (["update", "example.test", "101", "ttl"], "invalid property: ttl", "usage: bunnydns update"),
            (["update", "example.test", "101", "colour=red"], "invalid property: colour=red", ""),
            (["update", "example.test", "101", "ttl=1", "ttl=2"], "property given twice: ttl", ""),
            (["add", "example.test", "A", "www", "192.0.2.1", "type=AAAA"], "invalid property: type=AAAA", ""),
            (["apply", "-f"], "option -f requires argument", "usage: bunnydns apply [-n] [-f file]"),
            (["verify", "extra"], "too many operands", "usage: bunnydns verify"),
        ]
        for args, message, usage in cases:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.status, 2, result.output)
                self.assertIn(f"bunnydns: {message}", result.stderr)
                self.assertIn(usage, result.stderr)
        class Terminal(io.StringIO):
            def isatty(self):
                return True

        with mock.patch.object(sys, "stdin", Terminal()):
            self.assert_result(self.run_cli("apply"), 2, "no records: use -f file or standard input")
        self.assertEqual(self.fake.requests, [])

    def test_validate(self):
        self.assert_result(self.run_cli("validate", "-f", self.records_file(BASE_RECORDS)), 0,
                           "records.json: 3 valid record(s) for example.test.")
        self.assert_result(self.run_cli("validate", stdin=json.dumps({"owner": "o", "zone": "a.test", "records": []})), 0,
                           "standard input: 0 valid record(s) for a.test.")
        self.assert_result(self.run_cli("validate", "-f", PROJECT_DIR / "records.example.json"), 0)
        self.assert_result(self.run_cli("validate", "-f", self.root / "missing.json"), 1, "missing.json: No such file")
        self.assert_result(self.run_cli("validate", stdin="{"), 1, "standard input: Expecting property name")
        duplicate = copy.deepcopy(BASE_RECORDS)
        duplicate[1]["key"] = duplicate[0]["key"]
        self.assert_result(self.run_cli("validate", "-f", self.records_file(duplicate)), 1, "record keys must be unique")
        self.assert_result(self.run_cli("validate", "-f", self.records_file(BASE_RECORDS, key_file="/k")), 1,
                           "key_file is not a known field")
        self.assertEqual(self.fake.requests, [])

    def test_key_file_rules(self):
        self.fake.records[42] = copy.deepcopy(BASE_ZONE)
        self.key_file.chmod(0o644)
        self.assert_result(self.run_cli("list", "example.test"), 1, "must have mode 0400 or 0600, not 0644")
        self.key_file.chmod(0o400)
        self.assert_result(self.run_cli("list", "example.test"), 0)
        self.key_file.chmod(0o600)
        self.key_file.unlink()
        self.assert_result(self.run_cli("list", "example.test"), 1, f"{self.key_file}: no API key; run bunnydns init-key")
        self.assertEqual(len(self.fake.requests), 3)  # only the one good run reached Bunny

    def test_settings_file(self):
        self.fake.records[42] = copy.deepcopy(BASE_ZONE)
        other_key = self.root / "keys" / "bunny"
        other_key.parent.mkdir()
        other_key.write_text(API_KEY + "\n")
        other_key.chmod(0o600)
        self.key_file.unlink()
        other_backups = self.root / "elsewhere"
        self.settings(f"# Host settings\n\nkey_file = {other_key}\nbackup_dir={other_backups}\n")
        self.assert_result(self.run_cli("add", "example.test", "A", "new", "192.0.2.5"), 0, "Added record 104")
        self.assertEqual(len(list(other_backups.glob("*.json"))), 1)
        for text, message in (("colour=red\n", "line 1: unknown or repeated setting: colour"),
                              (f"key_file={other_key}\nkey_file={other_key}\n", "line 2: unknown or repeated setting"),
                              ("backup_dir=relative\n", "line 1: backup_dir must be an absolute path")):
            with self.subTest(text=text):
                self.settings(text)
                self.assert_result(self.run_cli("list", "example.test"), 1, message)

    def test_absent_zone(self):
        self.assert_result(self.run_cli("list", "absent.test"), 1, "expected one Bunny DNS zone named absent.test, found 0")
        self.assert_result(self.run_cli("list", "not a zone"), 1, "invalid zone name: not a zone")

    def test_key_is_sent_only_in_its_header(self):
        self.run_cli("list", "example.test")
        self.assertTrue(self.fake.headers)
        for headers in self.fake.headers:
            self.assertEqual((headers["accesskey"], headers["user-agent"]), (API_KEY, "bunnydns/0.1.0"))
        self.assertNotIn(API_KEY, "".join(path for _, path in self.fake.requests))
        self.assertNotIn(API_KEY, "".join(os.environ.values()))


class ListTests(BunnyTestCase):
    def setUp(self):
        super().setUp()
        self.fake.records[42] = copy.deepcopy(BASE_ZONE)
        self.find(103)["Disabled"] = True

    def test_table(self):
        self.assertEqual(self.run_cli("list", "example.test").stdout.splitlines(), [
            "ID   TYPE  NAME   TTL  DISABLED  VALUE",
            "102  TXT   @      300  false     service-verification=ready",
            "103  A     other  300  true      198.51.100.20",
            "101  A     www    300  false     192.0.2.10",
        ])

    def test_scripted_fields(self):
        self.assertEqual(self.run_cli("list", "-H", "-o", "name,value,priority", "example.test").stdout,
                         "@\tservice-verification=ready\t0\nother\t198.51.100.20\t0\nwww\t192.0.2.10\t0\n")

    def test_ownership_stays_hidden(self):
        self.assertNotIn("managed-by:", self.run_cli("list", "-o", ",".join(["id", "type", "name", "value", "ttl", "priority",
                                                                         "weight", "port", "flags", "tag", "disabled"]),
                                                     "example.test").output)


class DeclarativeTests(BunnyTestCase):
    def setUp(self):
        super().setUp()
        self.fake.records[42] = copy.deepcopy(BASE_ZONE)
        self.records = self.records_file(BASE_RECORDS)

    def test_dry_run_changes_nothing(self):
        result = self.run_cli("apply", "-n", "-f", self.records)
        self.assertEqual(result.stdout.splitlines(), [
            "UPDATE web-origin: A www 192.0.2.10 -- adopt the identical unmanaged record",
            "OK site-verification: TXT @ service-verification=ready -- matches",
            "CREATE api-origin: A api 192.0.2.11 -- no such record",
            "2 change(s) would be made.",
        ])
        self.assertEqual((self.fake.writes(), self.backups()), ([], []))

    def test_apply_backs_up_changes_and_verifies(self):
        result = self.run_cli("apply", "-f", self.records)
        self.assert_result(result, 0, "Backup: ", "Applied and verified 2 change(s).")
        self.assertEqual(self.find(101)["Comment"], comment("web-origin"))
        created = [item for item in self.zone if item["Comment"] == comment("api-origin")]
        self.assertEqual([item["Ttl"] for item in created], [60])  # omitted TTL defaults to 60
        self.assertEqual(self.find(103)["Comment"], comment("other-origin", "other-project"))
        self.assertEqual(self.fake.writes(), [("POST", "/dnszone/42/records/101"), ("PUT", "/dnszone/42/records")])

        [backup] = self.backups()
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.backup_dir.stat().st_mode), 0o700)
        self.assertIn('"service-verification=ready"', backup.read_text())

        self.assert_result(self.run_cli("verify", "-f", self.records), 0, "All declared records match.")
        self.assert_result(self.run_cli("apply", "-f", self.records), 0, "No changes needed.")
        self.assertEqual(len(self.backups()), 1)

    def test_records_from_standard_input(self):
        self.assert_result(self.run_cli("apply", stdin=self.records.read_text()), 0, "Applied and verified 2 change(s).")
        self.assert_result(self.run_cli("verify", stdin=self.records.read_text()), 0)

    def test_rename_updates_in_place(self):
        self.run_cli("apply", "-f", self.records)
        renamed = copy.deepcopy(BASE_RECORDS)
        renamed[0]["name"] = "web"
        path = self.records_file(renamed, "renamed.json")
        self.assert_result(self.run_cli("apply", "-f", path), 0,
                           "UPDATE web-origin: A web 192.0.2.10 -- move the record to its new name or type",
                           "Applied and verified 1 change(s).")
        self.assertEqual((self.find(101)["Name"], self.find(101)["Comment"]), ("web", comment("web-origin")))

    def test_prune_deletes_only_this_owners_obsolete_records(self):
        self.run_cli("apply", "-f", self.records)
        self.zone.append(record(150, "A", "old", "192.0.2.99", "managed-by:project-one-extra; key=api-origin"))
        fewer = self.records_file(BASE_RECORDS[:2], "fewer.json")
        self.assert_result(self.run_cli("prune", "-n", "-f", fewer), 0,
                           "DELETE api-origin: A api 192.0.2.11 -- no longer declared", "1 record(s) would be deleted.")
        self.assertEqual(len(self.backups()), 1)
        self.assert_result(self.run_cli("prune", "-f", fewer), 0, "Deleted and verified 1 record(s).")
        self.assertEqual(sorted(item["Id"] for item in self.zone), [101, 102, 103, 150])
        self.assert_result(self.run_cli("prune", "-f", fewer), 0, "No obsolete records.")
        self.assertEqual(len(self.backups()), 2)

    def test_prune_requires_a_clean_plan_first(self):
        self.assert_result(self.run_cli("prune", "-f", self.records), 1, "2 record(s) do not match the declaration")
        self.assertEqual(self.fake.writes(), [])

    def test_conflicts_stop_apply_and_verify(self):
        self.zone.append(record(200, "A", "clash", "192.0.2.99"))
        clash = self.records_file([{"key": "clashing-name", "type": "CNAME", "name": "clash", "value": "target.example.test"}],
                                  owner="conflict-project")
        self.assert_result(self.run_cli("apply", "-n", "-f", clash), 1,
                           "CONFLICT clashing-name: CNAME clash target.example.test -- a CNAME must be the only record",
                           "1 conflict(s) require review")
        self.assert_result(self.run_cli("apply", "-f", clash), 1, "require review")
        self.assert_result(self.run_cli("verify", "-f", clash), 1, "1 conflict(s) prevent a clean declared state")
        self.assertEqual(self.fake.writes(), [])


class DirectTests(BunnyTestCase):
    def setUp(self):
        super().setUp()
        self.fake.records[42] = copy.deepcopy(BASE_ZONE)

    def test_add_update_rename_delete(self):
        self.assert_result(self.run_cli("add", "example.test", "A", "cli", "192.0.2.55"), 0,
                           "Added record 104 to example.test: A cli 192.0.2.55")
        self.assertEqual((self.find(104)["Ttl"], self.find(104)["AutoSslIssuance"]), (60, True))

        self.find(104).update(ADVANCED)
        self.assert_result(self.run_cli("update", "example.test", "104", "value=192.0.2.56", "disabled=true"), 0,
                           "Updated record 104 in example.test: A cli 192.0.2.56")
        updated = self.find(104)
        self.assertEqual((updated["Name"], updated["Ttl"], updated["Disabled"]), ("cli", 60, True))
        self.assert_advanced_settings_kept(updated)

        self.assert_result(self.run_cli("update", "example.test", "104", "name=cli-renamed", "ttl=120"), 0)
        self.assertEqual((self.find(104)["Name"], self.find(104)["Ttl"], self.find(104)["Value"]),
                         ("cli-renamed", 120, "192.0.2.56"))
        self.assert_advanced_settings_kept(self.find(104))

        self.assert_result(self.run_cli("delete", "example.test", "104"), 0,
                           "Deleted record 104 from example.test: A cli-renamed 192.0.2.56")
        self.assertIsNone(self.find(104))
        self.assertEqual(len(self.backups()), 4)  # every change is preceded by a snapshot
        self.assertEqual([method for method, _ in self.fake.writes()], ["PUT", "POST", "POST", "DELETE"])

    def assert_advanced_settings_kept(self, item):
        self.assertEqual(item["PullZoneId"], 777)
        for name in ("Accelerated", "MonitorType", "SmartRoutingType", "GeolocationLatitude",
                     "GeolocationLongitude", "LatencyZone", "EnviromentalVariables", "AutoSslIssuance"):
            self.assertEqual(item[name], ADVANCED[name], name)

    def test_add_properties_and_apex(self):
        self.assert_result(self.run_cli("add", "example.test", "mx", "@", "mail.example.test", "priority=10", "ttl=3600"), 0,
                           "Added record 104 to example.test: MX @ mail.example.test")
        self.assertEqual((self.find(104)["Type"], self.find(104)["Name"], self.find(104)["Priority"]), (4, "", 10))

    def test_add_detects_value_drift(self):
        self.fake.add_value_drift = "203.0.113.254"
        self.assert_result(self.run_cli("add", "example.test", "A", "drift", "192.0.2.55"), 1,
                           "record 104 did not verify after the change")

    def test_invalid_values_never_contact_bunny(self):
        cases = [
            (["add", "example.test", "A", "bad", "192.0.2.99", "ttl=0"], "ttl must be an integer from 1 to 2147483647"),
            (["add", "example.test", "NOT_A_TYPE", "bad", "192.0.2.99"], "type must be one of A, AAAA"),
            (["update", "example.test", "101", "type=NOT_A_TYPE"], "type must be one of"),
            (["update", "example.test", "0", "ttl=60"], "invalid record id: 0"),
            (["add", "example.test", "A", "bad name", "192.0.2.99"], "name must be @ or a zone-relative name"),
            (["add", "example.test", "A", "www", ""], "value must be a non-empty string"),
            (["add", "not a zone", "A", "www", "192.0.2.99"], "invalid zone name"),
            (["add", "example.test", "CAA", "@", "letsencrypt.org", "flags=256"], "flags must be an integer from 0 to 255"),
            (["update", "example.test", "101", "disabled=yes"], "disabled must be true or false"),
            (["update", "example.test", "101", "weight=-1"], "weight must be an integer"),
        ]
        for args, message in cases:
            with self.subTest(args=args):
                self.assert_result(self.run_cli(*args), 1, message)
        self.assertEqual(self.fake.requests, [])

    def test_missing_record_and_conflicts(self):
        self.assert_result(self.run_cli("delete", "example.test", "999"), 1, "no record 999 in example.test")
        self.assert_result(self.run_cli("add", "example.test", "CNAME", "www", "target.example.test"), 1,
                           "a CNAME must be the only record at its name")
        self.assert_result(self.run_cli("add", "example.test", "A", "WWW", "192.0.2.10", "ttl=300"), 1,
                           "an identical record already exists")
        self.assertEqual(self.fake.writes(), [])

    def test_names_ignore_case_but_values_do_not(self):
        self.assert_result(self.run_cli("update", "example.test", "101", "name=WWW"), 0, "Record 101 already has these values.")
        self.fake.lowercase_names = True
        self.assert_result(self.run_cli("add", "example.test", "TXT", "MiXeD", "CaseSensitiveToken"), 0)
        self.assertEqual([(item["Name"], item["Value"]) for item in self.zone if item["Type"] == 3][-1],
                         ("mixed", "CaseSensitiveToken"))
        self.assertEqual([method for method, _ in self.fake.writes()], ["PUT"])


class PlanSafetyTests(BunnyTestCase):
    """Plans that must not write, and changes that must keep what they should."""

    def assert_conflict_without_writes(self, records):
        before = copy.deepcopy(self.zone)
        path = self.records_file(records)
        self.assert_result(self.run_cli("apply", "-n", "-f", path), 1, "CONFLICT")
        self.assert_result(self.run_cli("apply", "-f", path), 1, "CONFLICT")
        self.assertEqual(self.zone, before)
        self.assertEqual(self.fake.writes(), [])

    def test_conflicts_never_write(self):
        web = {"key": "web", "type": "A", "name": "www", "value": "192.0.2.1"}
        cases = {
            "another owner's identical record": ([record(1, "A", "www", "192.0.2.1", comment("web", "other-project"))], [web]),
            "allow_multiple does not take over": ([record(1, "A", "www", "192.0.2.1", comment("web", "other-project"))],
                                                  [{**web, "allow_multiple": True}]),
            "another key of this owner": ([record(1, "A", "www", "192.0.2.1", comment("old-key"))], [web]),
            "declared A and CNAME share a name": ([], [web, {"key": "alias", "type": "CNAME", "name": "WWW",
                                                              "value": "target.example.test"}]),
            "two keys describe one record": ([], [web, {**web, "key": "duplicate", "ttl": 300, "priority": 10}]),
            "move onto a CNAME": ([record(1, "A", "old", "192.0.2.1", comment("web")),
                                   record(2, "CNAME", "WWW", "target.example.test")], [web]),
            "allow_multiple does not bypass CNAME": ([record(1, "A", "old", "192.0.2.1", comment("web")),
                                                      record(2, "CNAME", "WWW", "target.example.test")],
                                                     [{**web, "allow_multiple": True}]),
            "move onto an unmanaged set": ([record(1, "A", "old", "192.0.2.1", comment("web")),
                                            record(2, "A", "WWW", "192.0.2.2")], [web]),
            "adoption requires matching weight": ([record(1, "A", "www", "192.0.2.1", Weight=10)],
                                                  [{**web, "weight": 100}]),
        }
        for label, (zone, records) in cases.items():
            with self.subTest(label):
                self.fake.records[42] = copy.deepcopy(zone)
                self.fake.requests.clear()
                self.assert_conflict_without_writes(records)

    def test_rename_and_ttl_update_keep_advanced_settings(self):
        self.fake.records[42] = [record(1, "A", "old", "192.0.2.1", comment("web"), ttl=60, **ADVANCED)]
        web = {"key": "web", "type": "A", "name": "www", "value": "192.0.2.1"}
        self.assert_result(self.run_cli("apply", "-f", self.records_file([web])), 0)
        self.assert_result(self.run_cli("apply", "-f", self.records_file([{**web, "ttl": 300}])), 0)
        kept = self.find(1)
        self.assertEqual((kept["Name"], kept["Ttl"], kept["PullZoneId"]), ("www", 300, 777))
        for name in ("Accelerated", "MonitorType", "SmartRoutingType", "GeolocationLatitude",
                     "GeolocationLongitude", "LatencyZone", "EnviromentalVariables", "AutoSslIssuance"):
            self.assertEqual(kept[name], ADVANCED[name], name)

    def test_lost_routing_settings_fail_verification(self):
        self.fake.records[42] = [record(1, "A", "old", "192.0.2.1", comment("web"), ttl=60, **ADVANCED)]
        self.fake.drop_routing = True
        path = self.records_file([{"key": "web", "type": "A", "name": "www", "value": "192.0.2.1"}])
        self.assert_result(self.run_cli("apply", "-f", path), 1, "record 1 did not verify after the change")

    def test_distinct_values_at_one_name_converge(self):
        path = self.records_file([{"key": "web", "type": "A", "name": "www", "value": "192.0.2.1"},
                                  {"key": "second-address", "type": "A", "name": "www", "value": "192.0.2.2"}])
        self.assert_result(self.run_cli("apply", "-f", path), 0, "Applied and verified 2 change(s).")
        self.assert_result(self.run_cli("verify", "-f", path), 0)

    def test_failed_name_and_type_update_changes_nothing_then_succeeds_in_place(self):
        before = [record(1, "A", "old", "192.0.2.1", comment("web"), ttl=60),
                  record(2, "TXT", "other", "keep", comment("other", "other-project"), ttl=60)]
        path = self.records_file([{"key": "web", "type": "AAAA", "name": "new", "value": "2001:db8::1"}])
        commands = {
            "direct": ["update", "example.test", "1", "type=AAAA", "name=new", "value=2001:db8::1"],
            "declarative": ["apply", "-f", path],
        }
        for mode, args in commands.items():
            with self.subTest(mode):
                self.fake.records[42] = copy.deepcopy(before)
                self.fake.requests.clear()
                self.fake.fail_updates = True
                self.assert_result(self.run_cli(*args), 1, "Service unavailable (HTTP 503)")
                self.assertEqual(self.zone, before)
                self.assertEqual([method for method, _ in self.fake.writes()], ["POST"])  # one update, in place
                self.fake.fail_updates = False
                self.assert_result(self.run_cli(*args), 0)
                self.assertEqual((self.find(1)["Type"], self.find(1)["Name"], self.find(1)["Value"], self.find(1)["Comment"]),
                                 (1, "new", "2001:db8::1", comment("web")))
                self.assertEqual(self.find(2), before[1])

    def test_weight_is_significant_for_a_and_aaaa(self):
        for type_name, value in (("A", "192.0.2.1"), ("AAAA", "2001:db8::1")):
            with self.subTest(type_name):
                self.fake.records[42] = [record(1, type_name, "www", value, comment("web"), ttl=60, Weight=10)]
                path = self.records_file([{"key": "web", "type": type_name, "name": "www", "value": value, "weight": 100}])
                self.assert_result(self.run_cli("verify", "-f", path), 1, "UPDATE web:")
                self.assert_result(self.run_cli("apply", "-f", path), 0)
                self.assertEqual(self.find(1)["Weight"], 100)
                self.assert_result(self.run_cli("verify", "-f", path), 0)

    def test_case_only_differences_are_ok(self):
        self.fake.records[42] = [record(1, "A", "www", "192.0.2.1", comment("web"), ttl=60),
                                 record(2, "A", "WwW", "192.0.2.2", comment("second"), ttl=60)]
        path = self.records_file([{"key": "web", "type": "A", "name": "WWW", "value": "192.0.2.1"},
                                  {"key": "second", "type": "A", "name": "www", "value": "192.0.2.2"}])
        for args in (["apply", "-n", "-f", path], ["apply", "-f", path], ["verify", "-f", path]):
            self.assert_result(self.run_cli(*args), 0, "OK web:", "OK second:")
        self.assertEqual(self.fake.writes(), [])

        # The server may lowercase the submitted name; that still verifies.
        self.fake.lowercase_names = True
        ttl = self.records_file([{"key": "web", "type": "A", "name": "WWW", "value": "192.0.2.1", "ttl": 300},
                                 {"key": "second", "type": "A", "name": "www", "value": "192.0.2.2"}])
        self.assert_result(self.run_cli("apply", "-f", ttl), 0, "Applied and verified 1 change(s).")
        self.assertEqual((self.find(1)["Id"], self.find(1)["Name"], self.find(1)["Ttl"]), (1, "www", 300))


if __name__ == "__main__":
    unittest.main()
