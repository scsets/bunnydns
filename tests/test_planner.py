# Filename: test_planner.py
# Description: Unit tests for the pure planning and output functions.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-09-30 Wed 00:00
# Version: 0.1.0
# Last-Updated: 2026-09-30 Wed 00:00
# Update #: 1

import unittest

from support import bunnydns, record

OWNER = "project-one"


def desired(key, type_name, name, value, **settings):
    """One declared record, validated as a records file would be."""
    entry = {"key": key, "type": type_name, "name": name, "value": value, **settings}
    return bunnydns.normalize_records({"owner": OWNER, "zone": "example.test", "records": [entry]})["records"][0]


def plan(declared, zone):
    return [(item.action, item.desired["Key"], item.reason, item.record_id)
            for item in bunnydns.build_plan(declared, zone)]


def mine(key):
    return bunnydns.ownership_comment(OWNER, key)


class BuildPlanTests(unittest.TestCase):
    def test_ok_update_and_create(self):
        zone = [record(1, "A", "www", "192.0.2.1", mine("web"), ttl=60),
                record(2, "A", "api", "192.0.2.2", mine("api"), ttl=60)]
        declared = [desired("web", "A", "www", "192.0.2.1"), desired("api", "A", "api", "192.0.2.3"),
                    desired("mail", "MX", "@", "mail.example.test", priority=10)]
        self.assertEqual(plan(declared, zone), [
            ("ok", "web", "matches", 1),
            ("update", "api", "change the record", 2),
            ("create", "mail", "no such record", None),
        ])

    def test_ttl_and_ownership_matter_only_for_owned_records(self):
        self.assertEqual(plan([desired("web", "A", "www", "192.0.2.1", ttl=300)],
                              [record(1, "A", "www", "192.0.2.1", mine("web"), ttl=60)])[0][0], "update")
        self.assertEqual(plan([desired("web", "A", "www", "192.0.2.1", ttl=300)], [record(1, "A", "www", "192.0.2.1", ttl=60)]),
                         [("update", "web", "adopt the identical unmanaged record", 1)])

    def test_names_ignore_case_and_values_do_not(self):
        zone = [record(1, "TXT", "WWW", "Token")]
        self.assertEqual(plan([desired("t", "TXT", "www", "Token")], zone)[0][0], "update")
        self.assertEqual(plan([desired("t", "TXT", "www", "token")], zone)[0][2],
                         "TXT records already exist at www; set allow_multiple to add one")
        self.assertEqual(plan([desired("t", "TXT", "www", "token", allow_multiple=True)], zone)[0][0], "create")

    def test_routing_fields_count_only_for_their_types(self):
        # Priority means nothing for A, so a stale value does not block adoption.
        self.assertEqual(plan([desired("web", "A", "www", "192.0.2.1")],
                              [record(1, "A", "www", "192.0.2.1", Priority=5)])[0][0], "update")
        # For MX it is part of the record's meaning.
        self.assertEqual(plan([desired("mx", "MX", "@", "mail.example.test", priority=10)],
                              [record(1, "MX", "", "mail.example.test", Priority=20)])[0][0], "conflict")

    def test_cname_exclusivity(self):
        reason = "a CNAME must be the only record at its name"
        self.assertEqual(plan([desired("alias", "CNAME", "www", "target.example.test")],
                              [record(1, "A", "WWW", "192.0.2.1")])[0][2], reason)
        self.assertEqual(plan([desired("web", "A", "www", "192.0.2.1", allow_multiple=True)],
                              [record(1, "CNAME", "www", "target.example.test")])[0][2], reason)

    def test_ownership_conflicts(self):
        web = desired("web", "A", "www", "192.0.2.1")
        cases = {
            "several Bunny records carry this ownership key":
                [record(1, "A", "www", "192.0.2.1", mine("web")), record(2, "A", "x", "192.0.2.9", mine("web"))],
            "an identical record is managed by another owner or key":
                [record(1, "A", "www", "192.0.2.1", "managed-by:other; key=web")],
            "several identical unmanaged records exist":
                [record(1, "A", "www", "192.0.2.1"), record(2, "A", "WWW", "192.0.2.1", ttl=60)],
        }
        for reason, zone in cases.items():
            with self.subTest(reason):
                self.assertEqual(plan([web], zone), [("conflict", "web", reason, None)])

    def test_declared_records_conflict_with_each_other(self):
        declared = [desired("a", "A", "www", "192.0.2.1"), desired("b", "A", "WWW", "192.0.2.1", ttl=300)]
        self.assertEqual({item[2] for item in plan(declared, [])}, {"declared records conflict at this name"})
        distinct = [desired("a", "A", "www", "192.0.2.1"), desired("b", "A", "www", "192.0.2.2")]
        self.assertEqual({item[0] for item in plan(distinct, [])}, {"create"})

    def test_moving_an_owned_record(self):
        zone = [record(1, "A", "old", "192.0.2.1", mine("web")), record(2, "A", "www", "192.0.2.2")]
        self.assertEqual(plan([desired("web", "A", "www", "192.0.2.1")], zone),
                         [("conflict", "web", "the new name and type are taken", 1)])
        self.assertEqual(plan([desired("web", "A", "www", "192.0.2.1", allow_multiple=True)], zone),
                         [("update", "web", "move the record to its new name or type", 1)])
        self.assertEqual(plan([desired("web", "AAAA", "old", "2001:db8::1")], zone)[0][0], "update")

    def test_obsolete_records(self):
        records = {"owner": OWNER, "records": [desired("web", "A", "www", "192.0.2.1")]}
        zone = [record(1, "A", "www", "192.0.2.1", mine("web")), record(2, "A", "old", "192.0.2.2", mine("old")),
                record(3, "A", "x", "192.0.2.3", "managed-by:project-one-extra; key=old"),
                record(4, "A", "y", "192.0.2.4")]
        self.assertEqual([item["Id"] for item in bunnydns.obsolete_records(records, zone)], [2])


class RecordBodyTests(unittest.TestCase):
    def test_update_body_keeps_advanced_fields(self):
        current = record(7, "A", "www", "192.0.2.1", mine("web"), AcceleratedPullZoneId=777, SmartRoutingType=1,
                         ScriptId=0, EnviromentalVariables=[{"Name": "REGION", "Value": "eu"}])
        body = bunnydns.update_record_body(current, {"Name": "web", "Ttl": 60})
        self.assertEqual((body["Name"], body["Ttl"], body["Value"], body["Comment"]), ("web", 60, "192.0.2.1", mine("web")))
        self.assertEqual((body["PullZoneId"], body["ScriptId"], body["SmartRoutingType"]), (777, None, 1))
        self.assertNotIn("Id", body)
        self.assertNotIn("Key", bunnydns.update_record_body(current, desired("web", "A", "www", "192.0.2.1")))

    def test_writable_view_notices_a_reset_routing_policy(self):
        body = bunnydns.update_record_body(record(1, "A", "www", "192.0.2.1", SmartRoutingType=1), {})
        stored = {**body, "Id": 1}
        del stored["SmartRoutingType"]
        self.assertNotEqual(bunnydns.writable_view(stored), bunnydns.writable_view(body))
        self.assertEqual(bunnydns.submitted_view(stored), bunnydns.submitted_view(body))

    def test_direct_change_problem(self):
        zone = [record(1, "A", "www", "192.0.2.1"), record(2, "CNAME", "alias", "www.example.test")]
        add = bunnydns.new_record_body
        self.assertEqual(bunnydns.direct_change_problem(add({"Type": 0, "Name": "ALIAS", "Value": "192.0.2.2"}), zone),
                         "a CNAME must be the only record at its name")
        self.assertEqual(bunnydns.direct_change_problem(add({"Type": 0, "Name": "WWW", "Value": "192.0.2.1", "Ttl": 300}), zone),
                         "an identical record already exists")
        self.assertIsNone(bunnydns.direct_change_problem(add({"Type": 0, "Name": "www", "Value": "192.0.2.1"}), zone))
        self.assertIsNone(bunnydns.direct_change_problem(dict(zone[0]), zone, record_id=1))


class OutputTests(unittest.TestCase):
    def test_list_values(self):
        item = record(105, "CAA", "", "letsencrypt.org", mine("caa"), Flags=128, Tag="issue", Disabled=True)
        self.assertEqual([bunnydns.list_value(item, name) for name in bunnydns.LIST_FIELDS],
                         ["105", "CAA", "@", "letsencrypt.org", "300", "0", "0", "0", "128", "issue", "true"])
        self.assertEqual(bunnydns.list_value({"Id": 9, "Type": 5}, "type"), "TYPE5")

    def test_table(self):
        rows = [["1", "www"], ["22", "@"]]
        self.assertEqual(bunnydns.format_table(["id", "name"], rows, False), ["ID  NAME", "1   www", "22  @"])
        self.assertEqual(bunnydns.format_table(["id", "name"], rows, True), ["1\twww", "22\t@"])
        self.assertEqual(bunnydns.format_table(["id"], [], False), ["ID"])

    def test_plan_line(self):
        action = bunnydns.PlanAction("update", desired("web", "A", "@", "192.0.2.1"), "change the record", 1)
        self.assertEqual(bunnydns.format_plan_action(action), "UPDATE web: A @ 192.0.2.1 -- change the record")


if __name__ == "__main__":
    unittest.main()
