# Filename: test_makefile.py
# Description: Tests of the Makefile, installer, and dependency tool.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-09-30 Wed 00:00
# Version: 0.1.0
# Last-Updated: 2026-10-01 Thu 00:00
# Update #: 4

"""These tests stage installations under a temporary DESTDIR and put mock
uname, zonename, and package managers first on PATH, so they never change
the host or its package database."""

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from collections import namedtuple
from pathlib import Path

from support import PROJECT_DIR

TESTS_DIR = PROJECT_DIR / "tests"
MAKE = os.environ.get("BUNNYDNS_TEST_MAKE") or shutil.which("gmake") or shutil.which("make")
STAGED = {"BINDIR": "/opt/scs/sbin", "MANDIR": "/opt/scs/man/man8"}
Result = namedtuple("Result", "status output")


def gnu_make_available():
    if not MAKE:
        return False
    return subprocess.run([MAKE, "--version"], capture_output=True, text=True).stdout.startswith("GNU Make ")


@unittest.skipUnless(gnu_make_available(), "GNU Make is required")
class MakefileTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="bunnydns-make-test."))
        self.addCleanup(shutil.rmtree, self.root)
        self.home = self.root / "home"
        self.home.mkdir()
        self.stage = self.root / "stage"
        self.log = self.root / "commands.log"
        self.log.write_text("")
        self.mock_bin = self.root / "mock-bin"
        self.mock_bin.mkdir()
        links = {"uname": "mock_uname.sh", "zonename": "mock_zonename.sh"}
        links.update({name: "mock_dependency_command.sh" for name in ("brew", "apt-get", "dpkg-query", "id")})
        for name, target in links.items():
            (self.mock_bin / name).symlink_to(TESTS_DIR / target)
        self.pkgsrc = self.root / "pkgsrc"
        for path in ("bin/pkgin", "sbin/pkg_info"):
            (self.pkgsrc / path).parent.mkdir(parents=True, exist_ok=True)
            (self.pkgsrc / path).symlink_to(TESTS_DIR / "mock_dependency_command.sh")
        # Start each make afresh, not as a child of the make running the tests.
        ignored = ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES", "PYTHON", "XDG_DATA_HOME")
        self.environment = {name: value for name, value in os.environ.items() if name not in ignored}
        self.environment["HOME"] = str(self.home)
        self.python = subprocess.run([str(PROJECT_DIR / "tools/dependencies.sh"), "python-path"],
                                     capture_output=True, text=True, check=True).stdout.strip()

    def make(self, *args, platform=None, zone=None, **environment):
        env = dict(self.environment, **environment)
        if platform:
            env.update(PATH=f"{self.mock_bin}:{env['PATH']}", MOCK_UNAME=platform,
                       MOCK_ZONENAME=zone or "global", MOCK_DEPENDENCY_LOG=str(self.log))
        result = subprocess.run([MAKE, "--no-print-directory", "-C", str(PROJECT_DIR), *args],
                                env=env, capture_output=True, text=True)
        return Result(result.returncode, result.stdout + result.stderr)

    def staged(self, target, **variables):
        settings = {**STAGED, "DESTDIR": str(self.stage), **variables}
        return self.make(target, *(f"{name}={value}" for name, value in settings.items()))

    def assert_result(self, result, status, *needles):
        self.assertEqual(result.status, status, result.output)
        for needle in needles:
            self.assertIn(needle, result.output)

    def logged(self):
        return self.log.read_text()

    def test_default_install_paths(self):
        cases = [
            ("SunOS", "global", {}, "/opt/scs/sbin/bunnydns", "/opt/scs/man/man8/bunnydns.8"),
            ("SunOS", "web01", {}, "/opt/scs/sbin/bunnydns", "/opt/scs/man/man8/bunnydns.8"),
            ("Darwin", None, {}, f"{self.home}/.local/bin/bunnydns", f"{self.home}/.local/share/man/man8/bunnydns.8"),
            ("Darwin", None, {"XDG_DATA_HOME": "/data"}, f"{self.home}/.local/bin/bunnydns", "/data/man/man8/bunnydns.8"),
            ("Linux", None, {}, "/usr/local/sbin/bunnydns", "/usr/local/share/man/man8/bunnydns.8"),
        ]
        for platform, zone, environment, command, manual in cases:
            with self.subTest(platform=platform, zone=zone, environment=environment):
                self.assert_result(self.make("show-install-paths", platform=platform, zone=zone, **environment), 0,
                                   f"Command: {command}\n", f"Manual:  {manual}\n", f"Python:  {self.python}\n")
        self.assert_result(self.make("show-install-paths", "PYTHON=/opt/tools/bin/python3.14"), 0,
                           "Python:  /opt/tools/bin/python3.14")

    def test_refusals(self):
        self.assert_result(self.make("show-install-paths", platform="Plan9"), 2, "Unsupported operating system: Plan9")
        self.assert_result(self.make("show-install-paths", "BINDIR=relative/path"), 2, "BINDIR must be absolute")
        self.assert_result(self.make("show-install-paths", "DESTDIR=stage"), 2, "DESTDIR must be empty or absolute")
        self.assert_result(self.make("require-gnu-make", f"MAKE={TESTS_DIR / 'mock_non_gnu_make.sh'}"), 2,
                           "GNU Make is required")
        for python in ("/usr/bin/false", "python3", ""):
            with self.subTest(python=python):
                self.assert_result(self.staged("install", PYTHON=python), 2, "Python 3.9 or newer is required")
        self.assertFalse(self.stage.exists())

    def assert_only_queries(self):
        """Require every logged package-manager call to be a read-only query."""
        for line in self.logged().splitlines():
            self.assertTrue(line.startswith(("brew list --formula ", "pkg_info -q -e ", "dpkg-query -W ")), line)

    def test_dependency_status_changes_nothing(self):
        self.assert_result(self.make("dependencies-status", platform="Darwin"), 0,
                           "Toolchain status for Darwin", "Python:   Python 3.", "All installed.")
        self.assertEqual(self.logged(), "brew list --formula python@3.14\nbrew list --formula make\n")
        for zone, prefix in (("global", "/opt/tools"), ("web01", "/opt/local")):
            with self.subTest(zone=zone):
                self.assert_result(self.make("dependencies-status", platform="SunOS", zone=zone), 0, f"pkgsrc:   {prefix}\n")
        self.log.write_text("")
        result = self.make("dependencies-status", platform="SunOS", BUNNYDNS_PKGSRC_PREFIX=str(self.pkgsrc),
                           MOCK_MISSING="gmake")
        self.assert_result(result, 0, "Missing: gmake\n", "Run gmake dependencies")
        self.assert_only_queries()

    def test_dependency_installation(self):
        # The first package is missing; the others are installed and never upgraded.
        pkgsrc = {"BUNNYDNS_PKGSRC_PREFIX": str(self.pkgsrc)}
        cases = [
            ("Darwin", {}, "python@3.14", ["brew install python@3.14"]),
            ("SunOS", pkgsrc, "python314", ["pkgin -y update", "pkgin install python314"]),
            ("Linux", {}, "python3", ["apt-get update", "apt-get install -y python3"]),
        ]
        for platform, environment, missing, commands in cases:
            with self.subTest(platform):
                self.log.write_text("")
                result = self.make("dependencies", platform=platform, MOCK_MISSING=missing, **environment)
                self.assert_result(result, 0, f"Installing {missing}.", "Toolchain status")
                for command in commands:
                    self.assertIn(command + "\n", self.logged())

            with self.subTest(platform, missing=None):
                self.log.write_text("")
                self.assert_result(self.make("dependencies", platform=platform, **environment), 0, "Nothing to install")
                self.assert_only_queries()

        self.log.write_text("")
        result = self.make("dependencies", platform="Linux", MOCK_MISSING="make", MOCK_DEPENDENCY_FAIL="apt-get update")
        self.assert_result(result, 2)
        self.assertNotIn("apt-get install", self.logged())

    def test_smartos_install_creates_the_private_directory(self):
        private = self.stage / "var/opt/scs/bunnydns"
        install = ("install", f"DESTDIR={self.stage}")
        self.assert_result(self.make(*install, platform="SunOS"), 0, f"Created {private} (mode 0700)")
        self.assertTrue((self.stage / "opt/scs/sbin/bunnydns").is_file())
        self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o700)
        settings = private / "bunnydns.conf"
        settings.write_text("backup_dir=/var/opt/scs/bunnydns/backups\n")
        result = self.make(*install, platform="SunOS")
        self.assert_result(result, 0)
        self.assertNotIn("Created", result.output)
        self.assertEqual(settings.read_text(), "backup_dir=/var/opt/scs/bunnydns/backups\n")
        self.assert_result(self.make("uninstall", f"DESTDIR={self.stage}", platform="SunOS"), 0)
        self.assertTrue(settings.is_file())  # host data outlives the program

    def test_install_warns_about_search_paths(self):
        bindir, manroot = self.root / "bin", self.root / "man"
        targets = (f"BINDIR={bindir}", f"MANDIR={manroot / 'man8'}", "DESTDIR=")
        self.assert_result(self.make("install", *targets, MANPATH="/usr/share/man"), 0,
                           f"Warning: {bindir} is not on PATH", f"Warning: {manroot} is not on MANPATH")
        cases = {
            "both found": {"PATH": f"{self.environment['PATH']}:{bindir}", "MANPATH": f"/usr/share/man:{manroot}"},
            "MANPATH unset": {"PATH": f"{bindir}:{self.environment['PATH']}", "MANPATH": ""},
        }
        for label, environment in cases.items():
            with self.subTest(label):
                result = self.make("update", *targets, **environment)
                self.assert_result(result, 0, "No update needed")
                self.assertNotIn("Warning:", result.output)

    def test_checksum(self):
        self.assert_result(self.make("checksum-check"), 0, "Verified MD5")
        sidecar = self.root / "generated.md5"
        self.assert_result(self.make("checksum", f"CHECKSUM={sidecar}"), 0, "Recorded MD5")
        self.assertEqual(sidecar.read_text(), (PROJECT_DIR / "bunnydns.py.md5").read_text())
        sidecar.write_text("00000000000000000000000000000000  bunnydns.py\n")
        self.assert_result(self.make("checksum-check", f"CHECKSUM={sidecar}"), 2, "Checksum mismatch for bunnydns.py")

    def test_staged_install_update_and_uninstall(self):
        program = self.stage / "opt/scs/sbin/bunnydns"
        manual = self.stage / "opt/scs/man/man8/bunnydns.8"
        source = (PROJECT_DIR / "bunnydns.py").read_text()
        rendered = f"#!{self.python}\n" + source.split("\n", 1)[1]
        manual_source = (PROJECT_DIR / "bunnydns.8").read_bytes()

        result = self.staged("update")
        self.assert_result(result, 0, "Installing bunnydns 0.1.0; no installed copy was found",
                           f"Installed {program} (Python {self.python})")
        self.assertNotIn("Warning:", result.output)  # a staged install is for another system
        self.assertEqual((program.read_text(), manual.read_bytes()), (rendered, manual_source))
        self.assertEqual((stat.S_IMODE(program.stat().st_mode), stat.S_IMODE(manual.stat().st_mode)), (0o755, 0o644))
        version = subprocess.run([str(program), "version"], capture_output=True, text=True, env={"PATH": "/nonexistent"})
        self.assertEqual(version.stdout, "bunnydns 0.1.0\n")  # the #! line, not PATH, finds Python

        program.chmod(0o700)
        self.assert_result(self.staged("update"), 0, "No update needed: bunnydns 0.1.0 is identical")
        self.assertEqual(stat.S_IMODE(program.stat().st_mode), 0o700)  # untouched

        damage = {
            "stale manual": lambda: manual.write_text(manual.read_text() + ".SH REVIEW\nOutdated.\n"),
            "missing manual": manual.unlink,
            "other interpreter": lambda: program.write_text("#!/nonexistent/python3\n" + source.split("\n", 1)[1]),
            "local edit": lambda: program.write_text(rendered + "# local edit\n"),
            "older version": lambda: program.write_text(rendered.replace('VERSION = "0.1.0"', 'VERSION = "0.0.9"')),
        }
        for label, damage_installation in damage.items():
            with self.subTest(label):
                damage_installation()
                old = "0.0.9" if label == "older version" else "0.1.0"
                self.assert_result(self.staged("update"), 0, f"Updating bunnydns {old} to 0.1.0.", "Content MD5:")
                self.assertEqual((program.read_text(), manual.read_bytes()), (rendered, manual_source))

        self.assert_result(self.staged("uninstall"), 0, "settings, and backups were kept")
        self.assertFalse(program.exists() or manual.exists())
        self.assertTrue(program.parent.is_dir() and manual.parent.is_dir())
        self.assert_result(self.staged("install"), 0)
        self.assert_result(self.staged("uninstall"), 0)


if __name__ == "__main__":
    unittest.main()
