#!/usr/bin/env python3

# Filename: bunnydns.py
# Description: Inspect, edit, and reconcile Bunny DNS records.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-09-30 Wed 00:00
# Version: 0.1.0
# Last-Updated: 2026-09-30 Wed 00:00
# Update #: 1

"""Inspect, edit, and reconcile records in a Bunny DNS zone.

Several projects can share one zone.  Records that a project declares in a
records file carry the Bunny comment "managed-by:OWNER; key=KEY", so the
project can later update and prune exactly its own records.

The file reads top to bottom in layers, each using only those above it:
constants and helpers, settings, records and properties, the API key, the
Bunny API client, planning (pure functions), the commands, and main().
Only the Python standard library is used.
"""

from __future__ import annotations

import datetime
import getopt
import getpass
import http.client
import json
import os
import platform
import re
import signal
import socket
import ssl
import stat
import string
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from collections import namedtuple
from typing import Callable, Mapping, Optional, Sequence

if sys.version_info < (3, 9):
    sys.exit("bunnydns: Python 3.9 or newer is required")

# --- Constants and helpers --------------------------------------------------

PROGRAM = "bunnydns"
VERSION = "0.1.0"

API_BASE_URL = "https://api.bunny.net"
PAGE_SIZE = 1000
REQUEST_TIMEOUT_SECONDS = 60

# Bunny sends no body with these errors, so bunnydns supplies the text.
STATUS_MESSAGES = {
    401: "Unauthorized. Check your API key.",
    403: "Forbidden. You don't have permission for this action.",
    404: "Not found.",
    409: "Conflict. The resource already exists or is in use.",
    500: "Internal server error.",
}

# pkgsrc Python on SmartOS may not find a CA bundle by itself, so use the one
# that mozilla-rootcerts-openssl installs.
PKGSRC_CA_BUNDLES = (
    "/opt/tools/etc/openssl/certs/ca-certificates.crt",  # global zone
    "/opt/local/etc/openssl/certs/ca-certificates.crt",  # native zone
)

MAX_INT32 = 2**31 - 1  # Bunny stores TTLs and routing numbers as 32-bit integers.

RECORD_TYPES = {
    "A": 0, "AAAA": 1, "CNAME": 2, "TXT": 3, "MX": 4, "SRV": 8,
    "CAA": 9, "PTR": 10, "NS": 12, "SVCB": 13, "HTTPS": 14, "TLSA": 15,
}
RECORD_TYPE_NAMES = {number: name for name, number in RECORD_TYPES.items()}
CNAME = RECORD_TYPES["CNAME"]

# Bunny keeps every routing field on every record, but each only means
# something for some types; comparisons ignore it for the rest.
WEIGHT_TYPES = {RECORD_TYPES[name] for name in ("A", "AAAA", "SRV")}
PRIORITY_TYPES = {RECORD_TYPES[name] for name in ("MX", "SRV", "SVCB", "HTTPS")}
CAA_TYPES = {RECORD_TYPES["CAA"]}  # Flags and Tag
SRV_TYPES = {RECORD_TYPES["SRV"]}  # Port

# Record properties, named as in records files and on the command line:
# property -> (Bunny field, default).  None means the property is required.
PROPERTIES = {
    "type": ("Type", None), "name": ("Name", None), "value": ("Value", None),
    "ttl": ("Ttl", 60), "priority": ("Priority", 0), "weight": ("Weight", 0),
    "port": ("Port", 0), "flags": ("Flags", 0), "tag": ("Tag", ""), "disabled": ("Disabled", False),
}
LIST_FIELDS = ("id",) + tuple(PROPERTIES)
DEFAULT_LIST_FIELDS = ("id", "type", "name", "ttl", "disabled", "value")

MANAGED_MARKER = "managed-by:"
OWNER_PATTERN = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")
KEY_PATTERN = re.compile(r"[a-z0-9][a-z0-9-]{0,63}")
ZONE_PATTERN = re.compile(r"[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
NAME_PATTERN = re.compile(r"@|[A-Za-z0-9_.*-]+")  # "@" is the zone apex

USAGE = {
    "list": "list [-H] [-o field,...] zone",
    "add": "add zone type name value [property=value ...]",
    "update": "update zone id property=value ...",
    "delete": "delete zone id",
    "apply": "apply [-n] [-f file]",
    "verify": "verify [-f file]",
    "prune": "prune [-n] [-f file]",
    "validate": "validate [-f file]",
    "init-key": "init-key",
    "help": "help",
    "version": "version",
}


class BunnyDNSError(Exception):
    """A failure reported as "bunnydns: MESSAGE" with exit status 1."""


class UsageError(BunnyDNSError):
    """A command-line mistake, reported with the usage and exit status 2."""

    def __init__(self, command: Optional[str], message: str = ""):
        super().__init__(message)
        self.command = command


def say(line: str = "") -> None:
    print(line, flush=True)  # flush so output and errors interleave correctly


_TO_LOWER = str.maketrans(string.ascii_uppercase, string.ascii_lowercase)


def fold_name(name: Optional[str]) -> str:
    """Return a DNS name in comparable form.

    Names ignore the case of ASCII letters (RFC 4343); values never do,
    because the case of a TXT token matters.
    """
    return (name or "").translate(_TO_LOWER)


def display_name(name: Optional[str]) -> str:
    """Bunny stores the zone apex as an empty name; show it as "@"."""
    return name or "@"


def is_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)  # bool is an int in Python


def matches(pattern: re.Pattern, value: object) -> bool:
    return isinstance(value, str) and pattern.fullmatch(value) is not None


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BunnyDNSError(message)


def field(record: Mapping, name: str, default):
    """RECORD[NAME], or DEFAULT when Bunny omitted the field or sent null."""
    value = record.get(name)
    return default if value is None else value


def positive_id(value: object) -> Optional[int]:
    """Bunny uses 0 or null for "no ID"; return None for both."""
    return value if is_integer(value) and value > 0 else None


def ownership_comment(owner: str, key: str) -> str:
    return f"{MANAGED_MARKER}{owner}; key={key}"


# --- Settings ---------------------------------------------------------------
#
# SmartOS uses the illumos layout: /opt/custom/etc/bunnydns (global zone) or
# /opt/local/etc/bunnydns (native zone) for settings and /var/opt/bunnydns for
# state.  Other systems follow the XDG base directories.  The settings file,
# bunnydns.conf, is optional; it holds name=value lines and # comments.


def site_dirs(system: str, environ: Mapping[str, str], zonename: Callable[[], str]) -> tuple:
    """Return (settings directory, state directory) for this system."""
    if system == "SunOS":
        prefix = "/opt/custom" if zonename() == "global" else "/opt/local"
        return f"{prefix}/etc/{PROGRAM}", f"/var/opt/{PROGRAM}"
    home = environ.get("HOME") or os.path.expanduser("~")

    def xdg(variable: str, fallback: str) -> str:
        value = environ.get(variable, "")  # the XDG spec ignores relative paths
        return os.path.join(value if os.path.isabs(value) else os.path.join(home, fallback), PROGRAM)

    return xdg("XDG_CONFIG_HOME", ".config"), xdg("XDG_STATE_HOME", ".local/state")


def current_zone() -> str:
    try:
        return subprocess.run(["/usr/bin/zonename"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        raise BunnyDNSError("cannot determine the zone name with /usr/bin/zonename") from None


def this_site() -> tuple:
    return site_dirs(platform.system(), os.environ, current_zone)


def load_settings() -> dict:
    """The settings file's values over the defaults for key_file and backup_dir."""
    settings_dir, state_dir = this_site()
    settings = {"key_file": os.path.join(settings_dir, "api-key"), "backup_dir": os.path.join(state_dir, "backups")}
    path = os.path.join(settings_dir, f"{PROGRAM}.conf")
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except FileNotFoundError:
        return settings
    except (OSError, ValueError) as error:
        raise BunnyDNSError(f"cannot read {path}: {error}") from None
    seen = set()
    for number, line in enumerate(lines, 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, _, value = (part.strip() for part in line.partition("="))
        where = f"{path}, line {number}"
        require(name in settings and name not in seen, f"{where}: unknown or repeated setting: {name}")
        require(os.path.isabs(value), f"{where}: {name} must be an absolute path")
        settings[name] = value
        seen.add(name)
    return settings


# --- Records and properties -------------------------------------------------
#
# A records file is {"owner": ..., "zone": ..., "records": [...]}.  Validated,
# each record becomes a dict of Bunny fields plus "Key" and "AllowMultiple".


def convert_property(name: str, value: object) -> object:
    """Check one property value and return it as Bunny stores it."""
    if name == "type":
        require(isinstance(value, str) and value.upper() in RECORD_TYPES, f"type must be one of {', '.join(RECORD_TYPES)}")
        return RECORD_TYPES[value.upper()]
    if name == "name":
        require(matches(NAME_PATTERN, value), "name must be @ or a zone-relative name")
        return "" if value == "@" else value
    if name == "value":
        require(isinstance(value, str) and value != "", "value must be a non-empty string")
    elif name == "tag":
        require(isinstance(value, str), "tag must be a string")
    elif name == "disabled":
        require(isinstance(value, bool), "disabled must be true or false")
    else:
        low, high = (1, MAX_INT32) if name == "ttl" else (0, 255 if name == "flags" else MAX_INT32)
        require(is_integer(value) and low <= value <= high, f"{name} must be an integer from {low} to {high}")
    return value


def record_fields(values: Mapping[str, object]) -> dict:
    """All Bunny fields of a record from its properties, with defaults filled in."""
    fields = {}
    for name, (bunny_name, default) in PROPERTIES.items():
        value = values.get(name)
        require(value is not None or default is not None, f"{name} is required")
        fields[bunny_name] = default if value is None else convert_property(name, value)
    return fields


def normalize_records(document: object) -> dict:
    require(isinstance(document, dict), "the records file must contain a JSON object")
    check_known(document, ("owner", "zone", "records"), "")
    require(matches(OWNER_PATTERN, document.get("owner")), "owner must be 1-64 characters of a-z, 0-9, '.', '_', '-'")
    require(matches(ZONE_PATTERN, document.get("zone")), "zone is not a valid DNS zone name")
    require(isinstance(document.get("records"), list), "records must be an array")
    records = []
    for index, entry in enumerate(document["records"]):
        where = f"records[{index}]"
        require(isinstance(entry, dict), f"{where} must be an object")
        check_known(entry, ("key", "allow_multiple", *PROPERTIES), f"{where}.")
        key = entry.get("key")
        require(matches(KEY_PATTERN, key), f"{where}.key must be 1-64 characters of a-z, 0-9, '-'")
        allow_multiple = field(entry, "allow_multiple", False)
        require(isinstance(allow_multiple, bool), f"{where}.allow_multiple must be true or false")
        try:
            fields = record_fields(entry)
        except BunnyDNSError as error:
            raise BunnyDNSError(f"{where}.{error}") from None
        records.append({"Key": key, "AllowMultiple": allow_multiple,
                        "Comment": ownership_comment(document["owner"], key), **fields})
    keys = [record["Key"] for record in records]
    require(len(keys) == len(set(keys)), "record keys must be unique")
    return {"owner": document["owner"], "zone": fold_name(document["zone"]), "records": records}


def check_known(obj: dict, names: Sequence[str], where: str) -> None:
    unknown = sorted(set(obj) - set(names))
    require(not unknown, f"{where}{unknown[0] if unknown else ''} is not a known field")


def read_records(command: str, options: Mapping[str, str]) -> tuple:
    """Read and validate the records from -f FILE or standard input; return (source, records)."""
    path = options.get("-f")
    if path is None and sys.stdin.isatty():
        raise UsageError(command, "no records: use -f file or standard input")
    source = path or "standard input"
    try:
        if path is None:
            document = json.load(sys.stdin)
        else:
            with open(path, encoding="utf-8") as handle:
                document = json.load(handle)
        return source, normalize_records(document)
    except (OSError, ValueError, BunnyDNSError) as error:  # json errors are ValueErrors
        message = error.strerror if isinstance(error, OSError) else error
        raise BunnyDNSError(f"{source}: {message}") from None


def parse_properties(command: str, args: Sequence[str], allowed: Sequence[str]) -> dict:
    """Parse property=value operands; values stay unchecked until convert_property."""
    values = {}
    for arg in args:
        name, equals, text = arg.partition("=")
        if not equals or name not in allowed:
            raise UsageError(command, f"invalid property: {arg}")
        if name in values:
            raise UsageError(command, f"property given twice: {name}")
        if name == "disabled":
            values[name] = {"true": True, "false": False}.get(text, text)
        elif name in ("type", "name", "value", "tag") or not re.fullmatch(r"[0-9]+", text):
            values[name] = text
        else:
            values[name] = int(text)
    return values


# --- API key ----------------------------------------------------------------
#
# The key lives only in a protected file and in memory: never in argv or the
# environment, where other local users or child processes could read it.


def check_key_file(path: str) -> None:
    require(os.path.isabs(path), f"key_file must be an absolute path: {path}")
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        raise BunnyDNSError(f"{path}: no API key; run bunnydns init-key") from None
    except OSError as error:
        raise BunnyDNSError(f"{path}: {error.strerror}") from None
    require(not stat.S_ISLNK(info.st_mode), f"{path}: the API key file must not be a symbolic link")
    require(stat.S_ISREG(info.st_mode), f"{path}: the API key file must be a regular file")
    mode = stat.S_IMODE(info.st_mode)
    require(mode in (0o400, 0o600), f"{path}: the API key file must have mode 0400 or 0600, not {mode:04o}")


def read_api_key(path: str) -> str:
    check_key_file(path)
    try:
        # O_NOFOLLOW refuses a symbolic link swapped in after the check.
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as handle:
            data = handle.read()
    except OSError as error:
        raise BunnyDNSError(f"{path}: {error.strerror}") from None
    if data.endswith(b"\n"):
        data = data[:-1]
    require(b"\n" not in data and b"\r" not in data, f"{path}: the API key file must hold exactly one line")
    return validate_api_key(data.decode("latin-1"))  # latin-1 keeps every byte visible to the check


def validate_api_key(key: str) -> str:
    require(key != "", "the API key is empty")
    require(all(" " <= character <= "~" for character in key), "the API key must be printable ASCII")
    require(key[0] != " " and key[-1] != " ", "the API key must not start or end with a space")
    return key


def require_terminal() -> None:
    # Without a terminal, getpass would read stdin with echo on; refuse instead.
    try:
        open("/dev/tty", "rb", buffering=0).close()
    except OSError:
        raise BunnyDNSError("init-key needs an interactive terminal") from None


def read_secret(prompt: str) -> str:
    try:
        return getpass.getpass(prompt)  # echo off, prompt on /dev/tty
    except EOFError:
        raise BunnyDNSError("no API key was entered") from None


# --- Bunny API client -------------------------------------------------------


def check_base_url(base_url: str) -> str:
    """Refuse to send the key anywhere but Bunny or a loopback test server.

    The command line cannot change the URL; only tests pass one, to main().
    """
    parts = urllib.parse.urlsplit(base_url)
    if base_url == API_BASE_URL or (parts.scheme == "http" and parts.hostname in ("127.0.0.1", "::1")):
        return base_url.rstrip("/")
    raise BunnyDNSError(f"refusing to send the Bunny API key to {base_url}")


def ca_bundle_override(system: str, environ: Mapping[str, str], exists=os.path.isfile) -> Optional[str]:
    """The pkgsrc CA bundle on SmartOS, unless SSL_CERT_FILE chooses one."""
    if system != "SunOS" or environ.get("SSL_CERT_FILE"):
        return None
    return next((bundle for bundle in PKGSRC_CA_BUNDLES if exists(bundle)), None)


class _RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """Make redirects errors, so the AccessKey header never follows one elsewhere."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api_error_message(status: int, payload: bytes) -> str:
    """Bunny's message for a failed request if it sent one, plus the status."""
    try:
        document = json.loads(payload.decode("utf-8"))
    except ValueError:
        document = None
    message = STATUS_MESSAGES.get(status, "Bunny API request failed")
    if isinstance(document, dict):
        # Core API errors use Message; RFC 7807 problem documents detail/title.
        message = next((document[name] for name in ("Message", "detail", "title")
                        if isinstance(document.get(name), str) and document[name].strip()), message)
    return f"{message} (HTTP {status})"


def decode_response(status: int, content_type: str, payload: bytes) -> object:
    """The JSON body of a successful response, or None when there is none (204)."""
    if not payload.strip():
        return None
    # A 2xx page that is not JSON comes from a proxy or captive portal, not Bunny.
    if not any(kind in content_type.lower() for kind in ("application/json", "text/json", "+json")):
        raise BunnyDNSError(f"Bunny API returned a non-JSON response (HTTP {status}, content-type "
                            f"{content_type or 'unset'}); a proxy may be intercepting the request")
    try:
        return json.loads(payload.decode("utf-8"))
    except ValueError:
        raise BunnyDNSError(f"Bunny API returned invalid JSON (HTTP {status})") from None


def collect_pages(fetch_page: Callable[[int], object], label: str) -> list:
    """Read every page of a Bunny list and prove that the list is complete.

    The zone may change while it is read, so a moving TotalItems or a final
    count that differs from it is an error, never a silently partial list.
    """
    items: list = []
    total = None
    page = 1
    while True:
        document = fetch_page(page)
        if not (isinstance(document, dict) and isinstance(document.get("Items"), list)
                and is_integer(document.get("CurrentPage")) and document["CurrentPage"] == page
                and is_integer(document.get("TotalItems")) and document["TotalItems"] >= 0
                and isinstance(document.get("HasMoreItems"), bool)):
            raise BunnyDNSError(f"Bunny returned an invalid {label} page")
        if total is None:
            total = document["TotalItems"]
        elif document["TotalItems"] != total:
            raise BunnyDNSError(f"the Bunny {label} changed while it was read; retry")
        items.extend(document["Items"])
        if not document["HasMoreItems"] or len(items) > total:
            break
        if not document["Items"]:
            raise BunnyDNSError(f"Bunny {label} pagination made no progress")
        page += 1
    if len(items) != total:
        raise BunnyDNSError(f"the Bunny {label} was incomplete; retry")
    return items


def check_zone_records(records: list) -> None:
    """Require unique positive IDs and the field types the planner relies on."""
    seen = set()
    for record in records:
        record_id = record.get("Id") if isinstance(record, dict) else None
        if positive_id(record_id) is None or record_id in seen:
            raise BunnyDNSError("Bunny returned duplicate or invalid record IDs")
        seen.add(record_id)
        if not is_integer(record.get("Type")) or any(
                not isinstance(field(record, name, ""), str) for name in ("Name", "Value", "Comment")):
            raise BunnyDNSError(f"Bunny returned an invalid record (ID {record_id})")


class BunnyClient:
    """The six Bunny DNS API calls bunnydns makes.

    Nothing is retried: repeating a write whose response was lost could
    apply it twice.  TLS certificates are always verified.
    """

    def __init__(self, api_key: str, base_url: str = API_BASE_URL):
        self.api_key = api_key
        self.base_url = check_base_url(base_url)
        cafile = ca_bundle_override(platform.system(), os.environ)
        handlers = [_RefuseRedirects(), urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=cafile))]
        if self.base_url != API_BASE_URL:
            handlers.append(urllib.request.ProxyHandler({}))  # a loopback test server needs no proxy
        self.opener = urllib.request.build_opener(*handlers)

    def search_zones(self, zone: str) -> list:
        """Zones named exactly ZONE.  Bunny's search matches substrings, so
        searching for example.com also returns mirror-example.com."""
        zones = collect_pages(lambda page: self.request(
            "GET", "/dnszone", {"page": page, "perPage": PAGE_SIZE, "search": zone, "view": 0}), "zone list")
        return [candidate for candidate in zones if isinstance(candidate, dict)
                and isinstance(candidate.get("Domain"), str) and fold_name(candidate["Domain"]) == fold_name(zone)]

    def get_zone(self, zone_id: int, zone: str) -> dict:
        """The zone document, with every record (read page by page) in Records."""
        document = self.request("GET", f"/dnszone/{zone_id}")
        if not isinstance(document, dict) or not isinstance(document.get("Domain"), str) \
                or fold_name(document["Domain"]) != fold_name(zone):
            raise BunnyDNSError("Bunny returned an invalid zone document")
        records = collect_pages(lambda page: self.request(
            "GET", f"/dnszone/{zone_id}/records", {"page": page, "perPage": PAGE_SIZE}), "record list")
        check_zone_records(records)
        return {**document, "Records": records}

    def add_record(self, zone_id: int, body: dict) -> dict:
        document = self.request("PUT", f"/dnszone/{zone_id}/records", body=body)
        if not isinstance(document, dict):
            raise BunnyDNSError("Bunny API returned no document for the new record")
        return document

    def update_record(self, zone_id: int, record_id: int, body: dict) -> None:
        self.request("POST", f"/dnszone/{zone_id}/records/{record_id}", body=body)

    def delete_record(self, zone_id: int, record_id: int) -> None:
        self.request("DELETE", f"/dnszone/{zone_id}/records/{record_id}")

    def request(self, method: str, path: str, query: Optional[dict] = None, body: Optional[dict] = None) -> object:
        """Send one request; return its JSON body, or None if it had none."""
        url = self.base_url + path + ("?" + urllib.parse.urlencode(query) if query else "")
        headers = {"AccessKey": self.api_key, "User-Agent": f"{PROGRAM}/{VERSION}", "Accept": "application/json"}
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        try:
            request = urllib.request.Request(url, data=data, headers=headers, method=method)
            with self.opener.open(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
                status, content_type, payload = response.status, response.headers.get("Content-Type", ""), response.read()
        except urllib.error.HTTPError as error:
            with error:  # close the error response, or Python warns about it
                try:
                    payload = error.read()
                except (OSError, http.client.HTTPException):
                    payload = b""
            raise BunnyDNSError(api_error_message(error.code, payload)) from None
        except urllib.error.URLError as error:
            raise BunnyDNSError(connection_problem(error.reason)) from None
        except (OSError, http.client.HTTPException) as error:
            raise BunnyDNSError(connection_problem(error)) from None
        return decode_response(status, content_type, payload)


def connection_problem(reason: object) -> str:
    if isinstance(reason, socket.timeout):
        return f"Bunny API request timed out after {REQUEST_TIMEOUT_SECONDS} seconds"
    message = f"cannot reach the Bunny API: {reason or type(reason).__name__}"
    if isinstance(reason, ssl.SSLCertVerificationError):
        message += "; check the system CA certificates or set SSL_CERT_FILE"
    return message


# --- Planning (pure functions, no I/O) --------------------------------------
#
# Records are compared through "views": dicts of just the fields that matter
# for one question, with missing fields defaulted and names case-folded.
# Views accept Bunny records and validated declared records alike.

OK, CREATE, UPDATE, CONFLICT = "ok", "create", "update", "conflict"
PlanAction = namedtuple("PlanAction", "action desired reason record_id", defaults=(None,))

# The fields bunnydns writes itself.  Everything else on a record is kept.
BASIC_FIELDS = ("Type", "Ttl", "Value", "Name", "Weight", "Priority", "Flags", "Tag", "Port", "Disabled", "Comment")
BASIC_DEFAULTS = {"Ttl": 60, "Value": "", "Name": "", "Weight": 0, "Priority": 0,
                  "Flags": 0, "Tag": "", "Port": 0, "Disabled": False, "Comment": ""}


def semantic_view(record: Mapping) -> dict:
    """What a record means in DNS, ignoring TTL, ownership, and unused routing fields."""
    kind = record.get("Type")
    return {
        "Type": kind,
        "Name": fold_name(record.get("Name")),
        "Value": field(record, "Value", ""),
        "Weight": field(record, "Weight", 0) if kind in WEIGHT_TYPES else 0,
        "Priority": field(record, "Priority", 0) if kind in PRIORITY_TYPES else 0,
        "Flags": field(record, "Flags", 0) if kind in CAA_TYPES else 0,
        "Tag": field(record, "Tag", "") if kind in CAA_TYPES else "",
        "Port": field(record, "Port", 0) if kind in SRV_TYPES else 0,
        "Disabled": field(record, "Disabled", False),
    }


def declared_view(record: Mapping) -> dict:
    """Everything a records file declares: the meaning plus TTL and ownership."""
    return {**semantic_view(record), "Ttl": field(record, "Ttl", 0), "Comment": field(record, "Comment", "")}


def submitted_view(record: Mapping) -> dict:
    """The fields bunnydns submits, compared exactly as sent (name case aside)."""
    view = {name: field(record, name, BASIC_DEFAULTS.get(name)) for name in BASIC_FIELDS}
    view["Name"] = fold_name(view["Name"])
    return view


def duplicate_view(record: Mapping) -> dict:
    """Submitted fields without ownership: records equal here are duplicates."""
    view = submitted_view(record)
    del view["Comment"]
    return view


def writable_view(record: Mapping) -> dict:
    """Every writable field, so a change that reset a routing policy is caught."""
    return {
        **submitted_view(record),
        "PullZoneId": pull_zone_id(record),
        "ScriptId": positive_id(record.get("ScriptId")),
        "Accelerated": field(record, "Accelerated", False),
        "MonitorType": field(record, "MonitorType", 0),
        "GeolocationLatitude": field(record, "GeolocationLatitude", 0),
        "GeolocationLongitude": field(record, "GeolocationLongitude", 0),
        "LatencyZone": field(record, "LatencyZone", ""),
        "SmartRoutingType": field(record, "SmartRoutingType", 0),
        "EnviromentalVariables": field(record, "EnviromentalVariables", []),  # sic: Bunny's spelling
        "AutoSslIssuance": field(record, "AutoSslIssuance", False),
    }


def pull_zone_id(record: Mapping) -> Optional[int]:
    """Bunny reports a record's pull zone as AcceleratedPullZoneId but accepts it as PullZoneId."""
    value = record.get("PullZoneId")
    return positive_id(record.get("AcceleratedPullZoneId") if value is None else value)


def is_managed(record: Mapping) -> bool:
    """True if any project, not just this one, has claimed the record."""
    return field(record, "Comment", "").startswith(MANAGED_MARKER)


def build_plan(desired_records: Sequence[Mapping], zone_records: Sequence[Mapping]) -> list:
    """One PlanAction per declared record, in declaration order."""
    return [plan_record(desired, desired_records, zone_records) for desired in desired_records]


def plan_record(desired: Mapping, desired_records: Sequence[Mapping], zone_records: Sequence[Mapping]) -> PlanAction:
    """Plan one declared record.  The rules run in order; the first that applies wins."""
    name = fold_name(desired["Name"])

    def conflict(reason: str) -> PlanAction:
        return PlanAction(CONFLICT, desired, reason)

    # 1. Declared records must not collide: a CNAME shares its name with
    #    nothing, and two keys must not describe the same record.
    for other in desired_records:
        if other["Key"] != desired["Key"] and fold_name(other["Name"]) == name and (
                CNAME in (other["Type"], desired["Type"]) or semantic_view(other) == semantic_view(desired)):
            return conflict("declared records conflict at this name")

    # 2. A record carrying this key's ownership comment is ours, whatever it holds.
    owned = [record for record in zone_records if field(record, "Comment", "") == desired["Comment"]]
    if len(owned) > 1:
        return conflict("several Bunny records carry this ownership key")
    if owned:
        return plan_owned_record(desired, owned[0], zone_records)

    # 3. Adopt an identical record, but only one that no project has claimed.
    same = [record for record in zone_records if semantic_view(record) == semantic_view(desired)]
    if any(is_managed(record) for record in same):
        return conflict("an identical record is managed by another owner or key")
    if len(same) > 1:
        return conflict("several identical unmanaged records exist")
    if same:
        return PlanAction(UPDATE, desired, "adopt the identical unmanaged record", same[0]["Id"])

    # 4. A new record must respect CNAME exclusivity, and may join an existing
    #    record set of its type only when allow_multiple says so.
    here = [record for record in zone_records if fold_name(record.get("Name")) == name]
    if any(CNAME in (record["Type"], desired["Type"]) for record in here):
        return conflict("a CNAME must be the only record at its name")
    if not desired["AllowMultiple"] and any(record["Type"] == desired["Type"] for record in here):
        return conflict(f"{RECORD_TYPE_NAMES[desired['Type']]} records already exist at "
                        f"{display_name(desired['Name'])}; set allow_multiple to add one")
    return PlanAction(CREATE, desired, "no such record")


def plan_owned_record(desired: Mapping, record: Mapping, zone_records: Sequence[Mapping]) -> PlanAction:
    record_id = record["Id"]
    name = fold_name(desired["Name"])
    if (record["Type"], fold_name(record.get("Name"))) != (desired["Type"], name):
        # Moving the record: its destination must be as free as for a new record.
        for other in zone_records:
            if other["Id"] != record_id and fold_name(other.get("Name")) == name and (
                    CNAME in (other["Type"], desired["Type"])
                    or (other["Type"] == desired["Type"] and not desired["AllowMultiple"])):
                return PlanAction(CONFLICT, desired, "the new name and type are taken", record_id)
        return PlanAction(UPDATE, desired, "move the record to its new name or type", record_id)
    if declared_view(record) == declared_view(desired):
        return PlanAction(OK, desired, "matches", record_id)
    return PlanAction(UPDATE, desired, "change the record", record_id)


def obsolete_records(records: Mapping, zone_records: Sequence[Mapping]) -> list:
    """This owner's records whose keys are no longer declared."""
    prefix = ownership_comment(records["owner"], "")
    declared = {desired["Comment"] for desired in records["records"]}
    return [record for record in zone_records
            if field(record, "Comment", "").startswith(prefix) and record["Comment"] not in declared]


def new_record_body(fields: Mapping) -> dict:
    """The body that adds a record: the basic fields, defaulted where not given."""
    return {name: field(fields, name, BASIC_DEFAULTS.get(name)) for name in BASIC_FIELDS}


def update_record_body(current: Mapping, changes: Mapping) -> dict:
    """The body that updates CURRENT in place with CHANGES applied.

    Bunny's update replaces the whole record, so every writable field the
    record already has is sent back; leaving one out would reset it.
    """
    body = new_record_body(current)
    body.update({
        "PullZoneId": pull_zone_id(current),
        "ScriptId": positive_id(current.get("ScriptId")),
        "Accelerated": field(current, "Accelerated", False),
        "AutoSslIssuance": field(current, "AutoSslIssuance", False),
    })
    for name in ("MonitorType", "GeolocationLatitude", "GeolocationLongitude",
                 "LatencyZone", "SmartRoutingType", "EnviromentalVariables"):
        body[name] = current.get(name)  # passed through as Bunny reported them
    body.update((name, changes[name]) for name in BASIC_FIELDS if name in changes)
    return body


def direct_change_problem(body: Mapping, zone_records: Sequence[Mapping], record_id: Optional[int] = None) -> Optional[str]:
    """Why a direct add or update (of RECORD_ID) must not happen, or None."""
    others = [record for record in zone_records if record["Id"] != record_id]
    name = fold_name(body["Name"])
    if any(fold_name(record.get("Name")) == name and CNAME in (record["Type"], body["Type"]) for record in others):
        return "a CNAME must be the only record at its name"
    if any(duplicate_view(record) == duplicate_view(body) for record in others):
        return "an identical record already exists"
    return None


# --- Output -----------------------------------------------------------------


def list_value(record: Mapping, name: str) -> str:
    """One `list` column: a record field shown the way it is written as a property."""
    if name == "id":
        return str(record["Id"])
    if name == "type":
        return RECORD_TYPE_NAMES.get(record["Type"], f"TYPE{record['Type']}")
    if name == "name":
        return display_name(record.get("Name"))
    if name == "disabled":
        return "true" if field(record, "Disabled", False) else "false"
    return str(field(record, PROPERTIES[name][0], ""))


def format_table(names: Sequence[str], rows: Sequence[Sequence[str]], scripted: bool) -> list:
    """Aligned columns under a header, or with -H tab-separated fields and no header."""
    if scripted:
        return ["\t".join(row) for row in rows]
    table = [[name.upper() for name in names], *rows]
    widths = [max(len(row[column]) for row in table) for column in range(len(names))]
    return ["  ".join(cell.ljust(width) for cell, width in zip(row, widths)).rstrip() for row in table]


def describe(record: Mapping) -> str:
    """TYPE NAME VALUE, as in the records file."""
    return " ".join(list_value(record, name) for name in ("type", "name", "value"))


def format_plan_action(item: PlanAction) -> str:
    """UPDATE web: A www 192.0.2.10 -- change the record"""
    return f"{item.action.upper()} {item.desired['Key']}: {describe(item.desired)} -- {item.reason}"


# --- Commands ---------------------------------------------------------------


class ZoneSession:
    """A zone opened for one command: the API client and its latest snapshot."""

    def __init__(self, zone: str, api_base_url: str):
        settings = load_settings()
        self.client = BunnyClient(read_api_key(settings["key_file"]), api_base_url)
        self.backup_dir = settings["backup_dir"]
        self.zone = zone
        found = self.client.search_zones(zone)
        require(len(found) == 1, f"expected one Bunny DNS zone named {zone}, found {len(found)}")
        self.zone_id = positive_id(found[0].get("Id"))
        require(self.zone_id is not None, f"Bunny returned an invalid zone ID for {zone}")
        self.refresh()

    def refresh(self) -> None:
        self.document = self.client.get_zone(self.zone_id, self.zone)
        self.records = self.document["Records"]

    def find(self, record_id: int) -> Optional[dict]:
        return next((record for record in self.records if record["Id"] == record_id), None)

    def backup(self) -> None:
        """Save a private snapshot of the zone as last read.  Runs before every write."""
        require(os.path.isabs(self.backup_dir), f"backup_dir must be an absolute path: {self.backup_dir}")
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        try:
            os.makedirs(self.backup_dir, mode=0o700, exist_ok=True)
            os.chmod(self.backup_dir, 0o700)
            # mkstemp creates a new, unique file with mode 0600.
            descriptor, path = tempfile.mkstemp(prefix=f"{self.zone}-{stamp}-", suffix=".json", dir=self.backup_dir)
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(self.document, handle, indent=2, ensure_ascii=False)
                handle.write("\n")
        except OSError as error:
            raise BunnyDNSError(f"cannot back up the zone to {self.backup_dir}: {error.strerror}") from None
        say(f"Backup: {path}")

    def verify(self, record_id: int, body: Mapping, view: Callable[[Mapping], dict]) -> None:
        """After refresh(), require the record to match BODY as seen through VIEW."""
        actual = self.find(record_id)
        require(actual is not None and view(actual) == view(body), f"record {record_id} did not verify after the change")


def parse_args(command: str, args: Sequence[str], optstring: str, minimum: int, maximum: Optional[int] = None) -> tuple:
    """POSIX getopt parsing: options first, then operands; return (options, operands)."""
    try:
        pairs, operands = getopt.getopt(list(args), optstring)
    except getopt.GetoptError as error:
        raise UsageError(command, str(error)) from None
    if len(operands) < minimum:
        raise UsageError(command, "missing operands")
    if maximum is not None and len(operands) > maximum:
        raise UsageError(command, "too many operands")
    return dict(pairs), operands


def parse_zone(text: str) -> str:
    require(ZONE_PATTERN.fullmatch(text) is not None, f"invalid zone name: {text}")
    return fold_name(text)


def parse_record_id(text: str) -> int:
    require(re.fullmatch(r"[1-9][0-9]*", text) is not None, f"invalid record id: {text}")
    return int(text)


def show_plan(records: Mapping, session: ZoneSession) -> list:
    plan = build_plan(records["records"], session.records)
    for item in plan:
        say(format_plan_action(item))
    return plan


def count(plan: Sequence[PlanAction], action: str) -> int:
    return sum(item.action == action for item in plan)


def require_clean_plan(plan: Sequence[PlanAction]) -> None:
    """Require every declared record to be OK, telling conflicts from mismatches."""
    conflicts, mismatches = count(plan, CONFLICT), len(plan) - count(plan, OK)
    require(not conflicts, f"{conflicts} conflict(s) prevent a clean declared state")
    require(not mismatches, f"{mismatches} record(s) do not match the declaration")


def cmd_list(args: Sequence[str], api_base_url: str) -> None:
    options, [zone] = parse_args("list", args, "Ho:", 1, 1)
    names = options["-o"].split(",") if "-o" in options else list(DEFAULT_LIST_FIELDS)
    unknown = [name for name in names if name not in LIST_FIELDS]
    if unknown:
        raise UsageError("list", f"unknown field: {unknown[0]} (fields: {','.join(LIST_FIELDS)})")
    session = ZoneSession(parse_zone(zone), api_base_url)
    records = sorted(session.records, key=lambda r: (field(r, "Name", ""), r["Type"], field(r, "Value", "")))
    for line in format_table(names, [[list_value(r, name) for name in names] for r in records], "-H" in options):
        say(line)


def cmd_add(args: Sequence[str], api_base_url: str) -> None:
    """Add one record, then read it back and verify every submitted field."""
    _, operands = parse_args("add", args, "", 4)
    zone, type_name, name, value, *properties = operands
    values = parse_properties("add", properties, [name for name in PROPERTIES if name not in ("type", "name", "value")])
    body = new_record_body(record_fields({"type": type_name, "name": name, "value": value, **values}))
    session = ZoneSession(parse_zone(zone), api_base_url)
    problem = direct_change_problem(body, session.records)
    require(problem is None, problem or "")
    session.backup()
    record_id = positive_id(session.client.add_record(session.zone_id, body).get("Id"))
    require(record_id is not None, "Bunny returned an invalid ID for the new record")
    session.refresh()
    # Bunny adds fields of its own (such as AutoSslIssuance); check only ours.
    session.verify(record_id, body, submitted_view)
    say(f"Added record {record_id} to {session.zone}: {describe(body)}")


def cmd_update(args: Sequence[str], api_base_url: str) -> None:
    """Change the given properties of one record in place; its ID and settings stay."""
    _, operands = parse_args("update", args, "", 3)
    zone, id_text, *properties = operands
    record_id = parse_record_id(id_text)
    values = parse_properties("update", properties, list(PROPERTIES))
    changes = {PROPERTIES[name][0]: convert_property(name, value) for name, value in values.items()}
    session = ZoneSession(parse_zone(zone), api_base_url)
    current = session.find(record_id)
    require(current is not None, f"no record {record_id} in {session.zone}")
    require(current["Type"] in RECORD_TYPE_NAMES, f"record {record_id} has a type bunnydns does not manage")
    body = update_record_body(current, changes)
    problem = direct_change_problem(body, session.records, record_id)
    require(problem is None, problem or "")
    if writable_view(current) == writable_view(body):
        say(f"Record {record_id} already has these values.")
        return
    session.backup()
    session.client.update_record(session.zone_id, record_id, body)
    session.refresh()
    session.verify(record_id, body, writable_view)
    say(f"Updated record {record_id} in {session.zone}: {describe(body)}")


def cmd_delete(args: Sequence[str], api_base_url: str) -> None:
    _, [zone, id_text] = parse_args("delete", args, "", 2, 2)
    record_id = parse_record_id(id_text)
    session = ZoneSession(parse_zone(zone), api_base_url)
    record = session.find(record_id)
    require(record is not None, f"no record {record_id} in {session.zone}")
    session.backup()
    session.client.delete_record(session.zone_id, record_id)
    session.refresh()
    require(session.find(record_id) is None, f"record {record_id} still exists after deletion")
    say(f"Deleted record {record_id} from {session.zone}: {describe(record)}")


def cmd_apply(args: Sequence[str], api_base_url: str) -> None:
    """Apply a conflict-free plan, then read the zone again and require it to match.

    With -n, only show the plan.
    """
    options, _ = parse_args("apply", args, "nf:", 0, 0)
    _, records = read_records("apply", options)
    session = ZoneSession(records["zone"], api_base_url)
    plan = show_plan(records, session)
    require(not count(plan, CONFLICT), f"{count(plan, CONFLICT)} conflict(s) require review")
    changes = [item for item in plan if item.action in (CREATE, UPDATE)]
    if "-n" in options:
        say(f"{len(changes)} change(s) would be made.")
        return
    if not changes:
        say("No changes needed.")
        return
    session.backup()
    for item in changes:
        if item.action == CREATE:
            session.client.add_record(session.zone_id, new_record_body(item.desired))
            continue  # creates are verified by the final plan below
        current = session.find(item.record_id)
        require(current is not None, f"record {item.record_id} disappeared during apply")
        body = update_record_body(current, item.desired)
        session.client.update_record(session.zone_id, item.record_id, body)
        session.refresh()
        session.verify(item.record_id, body, writable_view)
    session.refresh()
    require_clean_plan(show_plan(records, session))
    say(f"Applied and verified {len(changes)} change(s).")


def cmd_verify(args: Sequence[str], api_base_url: str) -> None:
    options, _ = parse_args("verify", args, "f:", 0, 0)
    _, records = read_records("verify", options)
    require_clean_plan(show_plan(records, ZoneSession(records["zone"], api_base_url)))
    say("All declared records match.")


def cmd_prune(args: Sequence[str], api_base_url: str) -> None:
    """Delete this owner's undeclared records.  Safe only when everything
    declared is in place, so it starts and ends with a clean verification.
    With -n, only show what would be deleted."""
    options, _ = parse_args("prune", args, "nf:", 0, 0)
    _, records = read_records("prune", options)
    session = ZoneSession(records["zone"], api_base_url)
    require_clean_plan(build_plan(records["records"], session.records))
    obsolete = obsolete_records(records, session.records)
    prefix = len(ownership_comment(records["owner"], ""))
    for record in obsolete:
        say(f"DELETE {record['Comment'][prefix:]}: {describe(record)} -- no longer declared")
    if "-n" in options:
        say(f"{len(obsolete)} record(s) would be deleted.")
        return
    if not obsolete:
        say("No obsolete records.")
        return
    session.backup()
    for record in obsolete:
        session.client.delete_record(session.zone_id, record["Id"])
    session.refresh()
    require_clean_plan(build_plan(records["records"], session.records))
    remaining = len(obsolete_records(records, session.records))
    require(not remaining, f"{remaining} obsolete record(s) still exist after prune")
    say(f"Deleted and verified {len(obsolete)} record(s).")


def cmd_validate(args: Sequence[str], api_base_url: str) -> None:
    """Check a records file without reading the key or using the network."""
    options, _ = parse_args("validate", args, "f:", 0, 0)
    source, records = read_records("validate", options)
    say(f"{source}: {len(records['records'])} valid record(s) for {records['zone']}.")


def cmd_init_key(args: Sequence[str], api_base_url: str) -> None:
    """Prompt for the API key with echo off and store it in the new key_file."""
    parse_args("init-key", args, "", 0, 0)
    path = load_settings()["key_file"]
    require(os.path.isabs(path), f"key_file must be an absolute path: {path}")
    require(not os.path.lexists(path), f"{path} already exists; remove it first to replace the key")
    require_terminal()
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)  # a new directory is private
        key = validate_api_key(read_secret("Bunny API key: "))
        # O_EXCL never replaces a file; O_NOFOLLOW never writes through a link.
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w", encoding="ascii") as handle:
            os.fchmod(descriptor, 0o600)
            handle.write(key + "\n")
    except OSError as error:
        raise BunnyDNSError(f"cannot create {path}: {error.strerror}") from None
    say(f"Stored the API key in {path} (mode 0600).")


def usage_text() -> str:
    lines = [f"{'usage:' if index == 0 else '      '} {PROGRAM} {text}" for index, text in enumerate(USAGE.values())]
    return "\n".join(lines)


def cmd_help(args: Sequence[str], api_base_url: str) -> None:
    parse_args("help", args, "", 0, 0)
    settings_dir, state_dir = this_site()
    say(usage_text())
    say()
    say(f"Properties: {', '.join(PROPERTIES)}")
    say(f"List fields: {','.join(LIST_FIELDS)} (default {','.join(DEFAULT_LIST_FIELDS)})")
    say(f"Settings: {settings_dir}/{PROGRAM}.conf (key_file, backup_dir)")
    say(f"Defaults: key_file={settings_dir}/api-key backup_dir={state_dir}/backups")


def cmd_version(args: Sequence[str], api_base_url: str) -> None:
    parse_args("version", args, "", 0, 0)
    say(f"{PROGRAM} {VERSION}")


COMMANDS = {
    "list": cmd_list, "add": cmd_add, "update": cmd_update, "delete": cmd_delete,
    "apply": cmd_apply, "verify": cmd_verify, "prune": cmd_prune, "validate": cmd_validate,
    "init-key": cmd_init_key, "help": cmd_help, "version": cmd_version,
}


# --- main -------------------------------------------------------------------


def main(argv: Optional[Sequence[str]] = None, *, api_base_url: str = API_BASE_URL) -> int:
    """Run one command.  Exit status: 0 success, 1 error, 2 usage error, 130 interrupted.

    api_base_url is for the test suite, which points it at a local fake API.
    """
    args = sys.argv[1:] if argv is None else list(argv)
    try:
        if not args:
            raise UsageError(None)
        if args[0] not in COMMANDS:
            raise UsageError(None, f"unknown command: {args[0]}")
        COMMANDS[args[0]](args[1:], api_base_url)
        return 0
    except UsageError as error:
        if str(error):
            print(f"{PROGRAM}: {error}", file=sys.stderr)
        usage = f"usage: {PROGRAM} {USAGE[error.command]}" if error.command else usage_text()
        print(usage, file=sys.stderr, flush=True)
        return 2
    except BunnyDNSError as error:
        print(f"{PROGRAM}: {error}", file=sys.stderr, flush=True)
        return 1
    except KeyboardInterrupt:
        print(f"{PROGRAM}: interrupted", file=sys.stderr, flush=True)
        return 130
    except BrokenPipeError:
        # The reader left, as in `bunnydns list ZONE | head`; silence the exit flush.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 1


def interrupt(signum, frame):
    raise KeyboardInterrupt  # so HUP and TERM exit with 130 like Ctrl-C


if __name__ == "__main__":
    signal.signal(signal.SIGHUP, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    sys.exit(main())
