#!/usr/bin/env python3
"""
Jamf Toolbox
============
A small macOS desktop utility (Tkinter, standard library only) for running
common one-off Jamf Pro tasks against computers and mobile devices:

  * Enable / disable Lost Mode with a templated message (mobile devices)
  * Rename devices using a templated naming format
  * Lock devices with a PIN and templated message
  * Send an Update Inventory command
  * Open the device record in Jamf Pro in your browser

Templates support {tags} (e.g. {username}, {serial}) that are filled in from
the device record before the command is sent. Settings — including API
credentials — persist between launches. Credentials are stored in the macOS
Keychain when available.

Requires: macOS 13 (Ventura) or later, Python 3.9+ with Tkinter
          (e.g. the python.org installer, or `brew install python-tk`).
No third-party packages are needed.
"""

import base64
import copy
import datetime
import json
import os
import re
import ssl
import subprocess
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
import xml.sax.saxutils as saxutils

import tkinter as tk
from tkinter import ttk, messagebox, filedialog

APP_NAME = "Jamf Toolbox"
APP_VERSION = "2.4.0"
KEYCHAIN_SERVICE = "com.jamftoolbox.credentials"
LEGACY_KEYCHAIN_SERVICE = "com.jamfquicktasks.credentials"   # pre-rename

CONFIG_DIR = os.path.expanduser("~/Library/Application Support/JamfToolbox")
LEGACY_CONFIG_DIR = os.path.expanduser("~/Library/Application Support/JamfQuickTasks")
CONFIG_PATH = os.path.join(CONFIG_DIR, "settings.json")

DEFAULTS = {
    "jamf_url": "",
    "auth_method": "basic",          # "oauth" (API client) or "basic" (user account)
    "verify_notes": True,            # show confirmation preview before sending
    "ssl_verify": True,              # verify the server's TLS certificate
    "ssl_ca_bundle": "/etc/ssl/cert.pem", # optional path to a .pem for internal CAs
    "lost_mode_message": "{name} - (Lost Mode: Please return to tech desk to disable lost mode)",
    "lost_mode_phone": "",
    "lost_mode_footnote": "Property of Rock Ridge Public Schools",
    "lost_mode_sound": True,
    "rename_format_computer": "{realname} - {serial}",
    "rename_format_mobile": "{realname} - {username} - {serial}",
    "double_click_action": "action_open_in_jamf",
    "list_columns": None,            # None -> DEFAULT_COLUMNS; user-chosen order
    "lock_message": "This device has been locked by RRPS Tech Department. Please contact tech@rrps.org or bring to tech desk to remove lock.",
    "device_list_computer": [],      # saved working list of computers
    "device_list_mobile": [],        # saved working list of mobile devices
    "meraki_org_id": "",             # remembered Meraki organization
    "meraki_org_name": "",
    "meraki_network_id": "",         # remembered Meraki network (Meraki Info default)
    "meraki_network_name": "",
    "window_geometry": "",           # saved main-window size/position
    "credentials_in_file": {},       # fallback only, used when Keychain is unavailable
}


def build_ssl_context(verify=True, ca_bundle=""):
    """TLS context for API calls: default trust, a custom CA bundle for
    internal CAs, or (discouraged) no verification at all."""
    if not verify:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    if ca_bundle:
        try:
            return ssl.create_default_context(cafile=ca_bundle)
        except (OSError, ssl.SSLError) as exc:
            raise JamfError(f"Could not load CA bundle {ca_bundle}: {exc}")
    return ssl.create_default_context()

# ---------------------------------------------------------------------------
# Settings persistence
# ---------------------------------------------------------------------------

class Settings:
    """Loads/saves app settings as JSON; secrets go to the macOS Keychain.

    If the `security` tool is unavailable (or fails), secrets fall back to an
    obfuscated entry inside the settings file so the app still works.
    """

    SECRET_KEYS = ("client_id", "client_secret", "username", "password")

    def __init__(self):
        self.data = copy.deepcopy(DEFAULTS)
        self._keychain_ok = sys.platform == "darwin"
        self._migrate_legacy_dir()
        self.load()

    @staticmethod
    def _migrate_legacy_dir():
        """One-time move of settings from the app's pre-rename folder."""
        try:
            if os.path.isdir(LEGACY_CONFIG_DIR) and not os.path.exists(CONFIG_DIR):
                os.rename(LEGACY_CONFIG_DIR, CONFIG_DIR)
        except OSError:
            pass  # fall back to fresh settings rather than failing launch

    # -- file-backed settings ------------------------------------------------
    def load(self):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
                stored = json.load(fh)
            for key, value in stored.items():
                self.data[key] = value
            # One-time migration: the single rename_format became per-type
            # templates. The legacy value was written for mobile devices, so
            # carry it there; computers pick up their own new default.
            if "rename_format" in stored and "rename_format_mobile" not in stored:
                self.data["rename_format_mobile"] = stored["rename_format"]
            self.data.pop("rename_format", None)
        except FileNotFoundError:
            pass
        except Exception:
            # A corrupt settings file should never prevent launch.
            pass

    def save(self):
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(CONFIG_PATH, "w", encoding="utf-8") as fh:
            json.dump(self.data, fh, indent=2)
        try:
            os.chmod(CONFIG_PATH, 0o600)
        except OSError:
            pass

    def get(self, key, default=""):
        return self.data.get(key, default)

    def set(self, key, value):
        self.data[key] = value

    # -- secrets -------------------------------------------------------------
    def get_secret(self, account):
        if self._keychain_ok:
            try:
                for service in (KEYCHAIN_SERVICE, LEGACY_KEYCHAIN_SERVICE):
                    result = subprocess.run(
                        ["security", "find-generic-password",
                         "-s", service, "-a", account, "-w"],
                        capture_output=True, text=True, timeout=10,
                    )
                    if result.returncode == 0:
                        value = result.stdout.rstrip("\n")
                        if service == LEGACY_KEYCHAIN_SERVICE:
                            self.set_secret(account, value)  # migrate forward
                        return value
            except (OSError, subprocess.TimeoutExpired):
                self._keychain_ok = False
        blob = self.data.get("credentials_in_file", {}).get(account, "")
        if blob:
            try:
                return base64.b64decode(blob.encode()).decode()
            except Exception:
                return ""
        return ""

    def set_secret(self, account, value):
        if self._keychain_ok:
            try:
                result = subprocess.run(
                    ["security", "add-generic-password", "-U",
                     "-s", KEYCHAIN_SERVICE, "-a", account, "-w", value],
                    capture_output=True, text=True, timeout=10,
                )
                if result.returncode == 0:
                    # ensure no stale plaintext fallback lingers
                    self.data.get("credentials_in_file", {}).pop(account, None)
                    return True
            except (OSError, subprocess.TimeoutExpired):
                self._keychain_ok = False
        fallback = self.data.setdefault("credentials_in_file", {})
        fallback[account] = base64.b64encode(value.encode()).decode()
        return False

    @property
    def keychain_available(self):
        return self._keychain_ok


# ---------------------------------------------------------------------------
# Tag rendering
# ---------------------------------------------------------------------------

TAG_DESCRIPTIONS = [
    ("{name}",          "Current device name in Jamf Pro"),
    ("{username}",      "Assigned username (Location > Username)"),
    ("{realname}",      "Assigned user's full name"),
    ("{email}",         "Assigned user's email address"),
    ("{position}",      "Assigned user's job title / position"),
    ("{department}",    "Department from the device record"),
    ("{building}",      "Building from the device record"),
    ("{room}",          "Room from the device record"),
    ("{phone}",         "Assigned user's phone number"),
    ("{serial}",        "Device serial number"),
    ("{serial_last4}",  "Last 4 characters of the serial number"),
    ("{asset_tag}",     "Asset tag from the device record"),
    ("{model}",         "Full model name (e.g. MacBook Pro 14-inch)"),
    ("{model_short}",   "Condensed model name, no spaces (e.g. MacBookPro)"),
    ("{wifi_mac}",      "Wi-Fi MAC address (primary MAC for computers)"),
    ("{ip}",            "Last reported IP address"),
    ("{os_version}",    "Operating system version"),
    ("{udid}",          "Device UDID"),
    ("{last_inventory}", "When the device last submitted inventory"),
    ("{device_id}",     "The device's Jamf Pro ID"),
    ("{date}",          "Today's date (YYYY-MM-DD)"),
    ("{time}",          "Current time (HH:MM)"),
]

_TAG_RE = re.compile(r"\{([a-z_0-9]+)\}")


def build_tag_values(record, device_type, device_id):
    """Flatten a classic-API device record into a dict of tag values."""
    general = record.get("general", {}) or {}
    location = record.get("location", {}) or {}

    hardware = record.get("hardware", {}) or {}
    if device_type == "computer":
        name = general.get("name", "")
        model = hardware.get("model", "")
        wifi_mac = general.get("mac_address", "") or ""
        ip = (general.get("last_reported_ip") or general.get("ip_address") or "")
        os_version = hardware.get("os_version", "") or ""
        last_inventory = general.get("report_date", "") or ""
    else:
        name = general.get("display_name") or general.get("name", "")
        model = general.get("model") or general.get("model_display", "")
        wifi_mac = general.get("wifi_mac_address", "") or ""
        ip = general.get("ip_address", "") or ""
        os_version = general.get("os_version", "") or ""
        last_inventory = general.get("last_inventory_update", "") or ""

    serial = general.get("serial_number", "") or ""
    model_short = re.sub(r"[^A-Za-z0-9]", "", model.split("(")[0])
    now = datetime.datetime.now()

    return {
        "name": name or "",
        "username": location.get("username", "") or "",
        "realname": (location.get("realname") or location.get("real_name") or ""),
        "email": location.get("email_address", "") or "",
        "position": location.get("position", "") or "",
        "department": location.get("department", "") or "",
        "building": location.get("building", "") or "",
        "room": str(location.get("room", "") or ""),
        "phone": (location.get("phone") or location.get("phone_number") or ""),
        "serial": serial,
        "serial_last4": serial[-4:] if serial else "",
        "asset_tag": str(general.get("asset_tag", "") or ""),
        "model": model or "",
        "model_short": model_short,
        "wifi_mac": wifi_mac,
        "ip": ip,
        "os_version": os_version,
        "udid": general.get("udid", "") or "",
        "last_inventory": str(last_inventory),
        "device_id": str(device_id),
        "date": now.strftime("%Y-%m-%d"),
        "time": now.strftime("%H:%M"),
    }


# ---------------------------------------------------------------------------
# Column catalog
# ---------------------------------------------------------------------------
# Every field a device row can display, in a sensible catalog order. The user
# chooses which of these appear as columns (and in what order) — stored in the
# "list_columns" setting. Entries in the saved device lists carry ALL of these
# fields, so changing columns never requires a refetch.
COLUMN_CATALOG = [
    #  field           heading           width
    ("name",           "Name",           170),
    ("serial",         "Serial",         115),
    ("username",       "Username",       100),
    ("realname",       "Full Name",      140),
    ("email",          "Email",          170),
    ("position",       "Position",       120),
    ("department",     "Department",     120),
    ("building",       "Building",       110),
    ("room",           "Room",           70),
    ("phone",          "Phone",          110),
    ("asset_tag",      "Asset Tag",      100),
    ("wifi_mac",       "Wi-Fi MAC",      130),
    ("ip",             "IP address",     110),
    ("model",          "Model",          160),
    ("model_short",    "Model (short)",  110),
    ("serial_last4",   "Serial (last 4)", 90),
    ("os_version",     "OS Version",     90),
    ("udid",           "UDID",           230),
    ("last_inventory", "Last Inventory", 150),
    ("device_id",      "Jamf ID",        70),
]
CATALOG_FIELDS = tuple(field for field, _h, _w in COLUMN_CATALOG)
COLUMN_HEADINGS = {field: heading for field, heading, _w in COLUMN_CATALOG}
COLUMN_WIDTHS = {field: width for field, _h, width in COLUMN_CATALOG}

# The out-of-the-box column set (also what "Reset to defaults" restores).
DEFAULT_COLUMNS = ["name", "serial", "username", "wifi_mac", "ip", "model"]


def entry_from_record(record, device_type, device_id):
    """Build a working-list entry carrying every catalog field, from a full
    device record."""
    tags = build_tag_values(record, device_type, device_id)
    entry = {"id": str(device_id)}
    for field in CATALOG_FIELDS:
        entry[field] = tags.get(field, "")
    return entry


def lost_mode_enabled(record):
    """Read a mobile device's current Lost Mode state from its record.

    Jamf reports this in slightly different places/spellings depending on
    version, so several keys are checked. Returns True, False, or None when
    the record doesn't say.
    """
    sections = [record.get("general", {}) or {},
                record.get("security", {}) or {},
                record.get("mobile_device_lost_mode", {}) or {}]
    keys = ("lost_mode_enabled", "lost_mode_enable", "lost_mode_enforced",
            "lost_mode_status", "lost_mode")
    for section in sections:
        if not isinstance(section, dict):
            continue
        for key in keys:
            if key not in section:
                continue
            value = section[key]
            if isinstance(value, bool):
                return value
            if isinstance(value, str) and value.strip():
                return value.strip().lower() in ("true", "yes", "on", "enabled")
    return None


def render_template(template, values):
    """Substitute {tags}; unknown tags are left as-is so typos are visible."""
    def repl(match):
        key = match.group(1)
        return str(values.get(key, match.group(0)))
    return _TAG_RE.sub(repl, template or "")


# ---------------------------------------------------------------------------
# Jamf Pro API client (standard library only)
# ---------------------------------------------------------------------------

class JamfError(Exception):
    pass


class JamfClient:
    """Minimal Jamf Pro API client covering the tasks this app performs.

    Uses the classic API (JSON responses) for searches, device detail, and
    MDM commands, and the modern API for token auth and the
    SETTINGS MDM command (deviceName).
    """

    def __init__(self, base_url, auth_method, cred_a, cred_b,
                 ssl_verify=True, ssl_ca_bundle=""):
        self.base_url = base_url.rstrip("/")
        self.auth_method = auth_method  # "oauth" or "basic"
        self.cred_a = cred_a            # client_id or username
        self.cred_b = cred_b            # client_secret or password
        self.ssl_verify = ssl_verify
        self.ssl_ca_bundle = ssl_ca_bundle
        self._token = None
        self._token_expiry = None
        self._lock = threading.Lock()

    def _open(self, req, timeout):
        ctx = build_ssl_context(self.ssl_verify, self.ssl_ca_bundle)
        return urllib.request.urlopen(req, timeout=timeout, context=ctx)

    @staticmethod
    def _explain_urlerror(exc, base_url):
        reason = getattr(exc, "reason", exc)
        if isinstance(reason, ssl.SSLCertVerificationError) or "CERTIFICATE_VERIFY_FAILED" in str(reason):
            return JamfError(
                f"TLS certificate verification failed for {base_url}.\n\n"
                "Python does not trust the server's certificate chain. Fixes, "
                "in order of preference:\n"
                "1. If you installed Python from python.org, run "
                "\"Install Certificates.command\" in its /Applications folder, "
                "then try again.\n"
                "2. If the server uses an internal/district CA, export that CA "
                "as a .pem file and set it as the CA bundle in Settings > "
                "Connection.\n"
                "3. As a last resort, uncheck \"Verify SSL certificates\" in "
                "Settings (not recommended)."
            )
        return JamfError(f"Could not reach {base_url}: {reason}")

    # -- auth ----------------------------------------------------------------
    def _fetch_token(self):
        if self.auth_method == "oauth":
            url = f"{self.base_url}/api/oauth/token"
            body = urllib.parse.urlencode({
                "grant_type": "client_credentials",
                "client_id": self.cred_a,
                "client_secret": self.cred_b,
            }).encode()
            req = urllib.request.Request(url, data=body, method="POST")
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
        else:
            url = f"{self.base_url}/api/v1/auth/token"
            basic = base64.b64encode(f"{self.cred_a}:{self.cred_b}".encode()).decode()
            req = urllib.request.Request(url, data=b"", method="POST")
            req.add_header("Authorization", f"Basic {basic}")
        req.add_header("Accept", "application/json")
        try:
            with self._open(req, timeout=30) as resp:
                payload = json.loads(resp.read().decode())
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                raise JamfError("Authentication failed (401). Check your credentials in Settings.")
            raise JamfError(f"Token request failed: HTTP {exc.code}")
        except urllib.error.URLError as exc:
            raise self._explain_urlerror(exc, self.base_url)

        token = payload.get("access_token") or payload.get("token")
        if not token:
            raise JamfError("Jamf Pro did not return a token.")
        ttl = payload.get("expires_in")
        if ttl:
            expiry = datetime.datetime.now() + datetime.timedelta(seconds=int(ttl) - 60)
        else:
            expires = payload.get("expires", "")
            try:
                expiry = datetime.datetime.fromisoformat(
                    expires.replace("Z", "+00:00")
                ).astimezone().replace(tzinfo=None) - datetime.timedelta(seconds=60)
            except Exception:
                expiry = datetime.datetime.now() + datetime.timedelta(minutes=15)
        return token, expiry

    def _get_token(self):
        with self._lock:
            if self._token and self._token_expiry and datetime.datetime.now() < self._token_expiry:
                return self._token
            self._token, self._token_expiry = self._fetch_token()
            return self._token

    def test_connection(self):
        self._token = None
        self._get_token()
        return True

    # -- request helper ------------------------------------------------------
    def _request(self, path, method="GET", data=None, content_type=None, accept="application/json"):
        token = self._get_token()
        url = f"{self.base_url}{path}"
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {token}")
        req.add_header("Accept", accept)
        if content_type:
            req.add_header("Content-Type", content_type)
        try:
            with self._open(req, timeout=45) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                detail = exc.read().decode()[:300]
            except Exception:
                pass
            if exc.code == 401:
                # token may have been revoked mid-session; retry once
                with self._lock:
                    self._token = None
                raise JamfError("Session expired or unauthorized (401). Try again.")
            if exc.code == 403:
                raise JamfError("Permission denied (403). The API account lacks a required privilege.")
            if exc.code == 404:
                raise JamfError(f"Not found (404): {path}")
            raise JamfError(f"HTTP {exc.code} on {method} {path}. {detail}")
        except urllib.error.URLError as exc:
            raise self._explain_urlerror(exc, self.base_url)
        if not raw:
            return {}
        if accept == "application/json":
            try:
                return json.loads(raw.decode())
            except Exception:
                return {}
        return raw

    # -- searches & detail ---------------------------------------------------
    def search_computers(self, query):
        q = urllib.parse.quote(f"*{query}*" if query else "*")
        data = self._request(f"/JSSResource/computers/match/{q}")
        return data.get("computers", [])

    def search_mobile_devices(self, query):
        q = urllib.parse.quote(f"*{query}*" if query else "*")
        data = self._request(f"/JSSResource/mobiledevices/match/{q}")
        return data.get("mobile_devices", [])

    def get_computer(self, device_id):
        data = self._request(f"/JSSResource/computers/id/{device_id}")
        return data.get("computer", {})

    def get_mobile_device(self, device_id):
        data = self._request(f"/JSSResource/mobiledevices/id/{device_id}")
        return data.get("mobile_device", {})

    # -- mobile device commands ----------------------------------------------
    def _mobile_command(self, command, device_id, extra_xml=""):
        xml = (
            "<mobile_device_command><general>"
            f"<command>{command}</command>{extra_xml}"
            "</general><mobile_devices><mobile_device>"
            f"<id>{int(device_id)}</id>"
            "</mobile_device></mobile_devices></mobile_device_command>"
        )
        self._request(
            "/JSSResource/mobiledevicecommands/command",
            method="POST", data=xml.encode(), content_type="text/xml",
        )

    def _mobile_mdm_command(self, device_id, command_data):
        """POST a modern MDM command (/api/v2/mdm/commands) for a mobile
        device, resolving its managementId first."""
        mgmt_id = self._mobile_management_id(device_id)
        if not mgmt_id:
            raise JamfError(
                "Could not find this device's management ID, which is required "
                "to send MDM commands. The device may not be fully "
                "enrolled/supervised.")
        body = json.dumps({
            "commandData": command_data,
            "clientData": [{"managementId": mgmt_id}],
        }).encode()
        self._request("/api/v2/mdm/commands", method="POST",
                      data=body, content_type="application/json")

    def enable_lost_mode(self, device_id, message, phone="", footnote="", play_sound=False):
        """Enable Lost Mode. Tries the classic EnableLostMode command first
        (which supports the sound option); if the server rejects it — newer
        Jamf versions have removed several classic commands — falls back to
        the modern ENABLE_LOST_MODE MDM command."""
        esc = saxutils.escape
        extra = (
            f"<lost_mode_message>{esc(message)}</lost_mode_message>"
            f"<lost_mode_phone>{esc(phone)}</lost_mode_phone>"
            f"<lost_mode_footnote>{esc(footnote)}</lost_mode_footnote>"
            f"<lost_mode_with_sound>{'true' if play_sound else 'false'}</lost_mode_with_sound>"
            "<always_enforce_lost_mode>true</always_enforce_lost_mode>"
        )
        try:
            self._mobile_command("EnableLostMode", device_id, extra)
            return "Enable Lost Mode command queued."
        except JamfError:
            # Newer servers drop the classic command. The modern equivalent
            # takes the message fields directly; the sound is a separate
            # PLAY_LOST_MODE_SOUND command sent once Lost Mode is on.
            self._mobile_mdm_command(device_id, {
                "commandType": "ENABLE_LOST_MODE",
                "lostModeMessage": message,
                "lostModePhone": phone,
                "lostModeFootnote": footnote,
            })
            note = "Enable Lost Mode command queued."
            if play_sound:
                try:
                    self._mobile_mdm_command(
                        device_id, {"commandType": "PLAY_LOST_MODE_SOUND"})
                    note += " Lost Mode sound requested."
                except JamfError as exc:
                    note += f" Lost Mode is on, but the sound command failed: {exc}"
            return note

    def disable_lost_mode(self, device_id):
        """Disable Lost Mode via the modern MDM command. The classic
        DisableLostMode command returns HTTP 400 "Invalid command" on current
        Jamf Pro versions; DISABLE_LOST_MODE on /api/v2/mdm/commands is the
        supported route (verified against Jamf Pro 11.x)."""
        self._mobile_mdm_command(device_id, {"commandType": "DISABLE_LOST_MODE"})
        return "Disable Lost Mode command queued via MDM."

    def rename_mobile_device(self, device_id, new_name):
        """Rename a mobile device via the modern MDM commands endpoint.

        The classic /mobiledevicecommands/command/DeviceName route (in both
        its path and body forms) returns HTTP 400 on current Jamf Pro
        versions, so we use POST /api/v2/mdm/commands with a SETTINGS command
        carrying the new deviceName. Handles any characters (spaces included)
        since the name travels in a JSON body.
        """
        self._mobile_mdm_command(device_id, {"commandType": "SETTINGS",
                                             "deviceName": new_name})
        return "Set Device Name command queued via MDM."

    def _mobile_management_id(self, device_id):
        """Resolve a mobile device's managementId from the modern API,
        tolerating the couple of shapes different Jamf versions return."""
        detail = self._request(f"/api/v2/mobile-devices/{int(device_id)}/detail")
        if isinstance(detail, dict):
            mgmt = detail.get("managementId")
            if mgmt:
                return mgmt
            general = detail.get("general")
            if isinstance(general, dict) and general.get("managementId"):
                return general["managementId"]
        # Fallback: the list endpoint can also carry it, keyed by id.
        try:
            listing = self._request(
                f"/api/v2/mobile-devices?page=0&page-size=1&filter="
                f"id=={int(device_id)}")
            results = (listing or {}).get("results") or []
            if results and results[0].get("managementId"):
                return results[0]["managementId"]
        except JamfError:
            pass
        return ""

    def update_inventory_mobile(self, device_id):
        """Modern DEVICE_INFORMATION command (verified available on Jamf Pro
        11.x), falling back to the classic UpdateInventory for older servers."""
        try:
            self._mobile_mdm_command(device_id, {"commandType": "DEVICE_INFORMATION"})
            return "Update Inventory command queued."
        except JamfError:
            self._mobile_command("UpdateInventory", device_id)
            return "Update Inventory command queued (classic)."

    def lock_mobile_device(self, device_id, message="", phone=""):
        """Lock a mobile device. Unlike computers, this takes no PIN — iOS and
        iPadOS lock with the device's existing passcode (Apple MDM behavior).
        Modern DEVICE_LOCK first; the classic command was removed in current
        Jamf Pro versions but is kept as a fallback for older servers."""
        command = {"commandType": "DEVICE_LOCK"}
        if message:
            command["message"] = message
        if phone:
            command["phoneNumber"] = phone
        try:
            self._mobile_mdm_command(device_id, command)
            return "Lock Device command queued."
        except JamfError:
            self._mobile_command("DeviceLock", device_id)
            return "Lock Device command queued (classic)."

    # -- computer commands ---------------------------------------------------
    def _computer_command(self, command, device_id, extra_xml=""):
        xml = (
            "<computer_command><general>"
            f"<command>{command}</command>{extra_xml}"
            "</general><computers><computer>"
            f"<id>{int(device_id)}</id>"
            "</computer></computers></computer_command>"
        )
        self._request(
            "/JSSResource/computercommands/command",
            method="POST", data=xml.encode(), content_type="text/xml",
        )

    def _computer_management_id(self, device_id):
        detail = self._request(f"/api/v1/computers-inventory-detail/{int(device_id)}")
        if isinstance(detail, dict):
            general = detail.get("general")
            if isinstance(general, dict) and general.get("managementId"):
                return general["managementId"]
            if detail.get("managementId"):
                return detail["managementId"]
        return ""

    def _computer_mdm_command(self, device_id, command_data):
        """POST a modern MDM command for a computer."""
        mgmt_id = self._computer_management_id(device_id)
        if not mgmt_id:
            raise JamfError(
                "Could not find this computer's management ID, which is "
                "required to send MDM commands.")
        body = json.dumps({
            "commandData": command_data,
            "clientData": [{"managementId": mgmt_id}],
        }).encode()
        self._request("/api/v2/mdm/commands", method="POST",
                      data=body, content_type="application/json")

    def lock_computer(self, device_id, passcode, message=""):
        """Lock a Mac with a 6-digit recovery PIN. Modern DEVICE_LOCK first
        (carrying the PIN), classic as a fallback for older servers."""
        command = {"commandType": "DEVICE_LOCK", "pin": passcode}
        if message:
            command["message"] = message
        try:
            self._computer_mdm_command(device_id, command)
            return "Lock Device command queued."
        except JamfError:
            esc = saxutils.escape
            extra = f"<passcode>{esc(passcode)}</passcode>"
            if message:
                extra += f"<lock_message>{esc(message)}</lock_message>"
            self._computer_command("DeviceLock", device_id, extra)
            return "Lock Device command queued (classic)."

    def rename_computer(self, device_id, new_name):
        """Update the inventory record name, then send the SETTINGS MDM command
        so the change reaches the Mac itself. (The command type is SETTINGS,
        not SET_COMPUTER_NAME — the latter is rejected as an unknown type by
        /api/v2/mdm/commands.) Returns a note describing what happened."""
        esc = saxutils.escape
        xml = f"<computer><general><name>{esc(new_name)}</name></general></computer>"
        self._request(
            f"/JSSResource/computers/id/{int(device_id)}",
            method="PUT", data=xml.encode(), content_type="text/xml",
        )
        # Push to the device via the modern MDM command.
        try:
            self._computer_mdm_command(device_id, {"commandType": "SETTINGS",
                                                   "deviceName": new_name})
            return "Name updated and Set Computer Name command queued via MDM."
        except JamfError as exc:
            return (f"Name updated in Jamf Pro, but the push-to-device command "
                    f"failed: {exc}. It will reconcile on the Mac's next "
                    "inventory update.")

    # -- misc ----------------------------------------------------------------
    def device_web_url(self, device_type, device_id):
        if device_type == "computer":
            return f"{self.base_url}/computers.html?id={device_id}&o=r"
        return f"{self.base_url}/mobileDevices.html?id={device_id}&o=r"


# ---------------------------------------------------------------------------
# Meraki Dashboard API client
# ---------------------------------------------------------------------------

class MerakiError(Exception):
    pass


class MerakiClient:
    """Minimal Meraki Dashboard API (v1) client for client lookups."""

    BASE = "https://api.meraki.com/api/v1"

    def __init__(self, api_key, ssl_verify=True, ssl_ca_bundle=""):
        self.api_key = api_key
        self.ssl_verify = ssl_verify
        self.ssl_ca_bundle = ssl_ca_bundle

    def _request(self, path):
        req = urllib.request.Request(f"{self.BASE}{path}")
        req.add_header("Authorization", f"Bearer {self.api_key}")
        req.add_header("Accept", "application/json")
        try:
            ctx = build_ssl_context(self.ssl_verify, self.ssl_ca_bundle)
            with urllib.request.urlopen(req, timeout=45, context=ctx) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                raise MerakiError("Meraki rejected the API key (401). "
                                  "Check it in Settings > Meraki.")
            if exc.code == 404:
                raise MerakiError("__NOT_FOUND__")
            if exc.code == 429:
                raise MerakiError("Meraki rate limit hit (429). Wait a few seconds and retry.")
            detail = ""
            try:
                detail = exc.read().decode()[:200]
            except Exception:
                pass
            raise MerakiError(f"Meraki API error HTTP {exc.code}. {detail}")
        except urllib.error.URLError as exc:
            reason = getattr(exc, "reason", exc)
            if "CERTIFICATE_VERIFY_FAILED" in str(reason):
                raise MerakiError("TLS verification failed reaching Meraki. The CA bundle "
                                  "configured in Settings > Connection is used here too.")
            raise MerakiError(f"Could not reach the Meraki API: {reason}")
        try:
            return json.loads(raw.decode()) if raw else {}
        except Exception:
            raise MerakiError("Meraki returned an unreadable response.")

    def get_organizations(self):
        orgs = self._request("/organizations")
        return orgs if isinstance(orgs, list) else []

    def get_networks(self, org_id):
        networks = self._request(
            f"/organizations/{urllib.parse.quote(str(org_id))}/networks?perPage=1000")
        return networks if isinstance(networks, list) else []

    def get_devices(self, network_id):
        """All Meraki hardware (APs, switches, …) in a network."""
        devices = self._request(
            f"/networks/{urllib.parse.quote(str(network_id))}/devices")
        return devices if isinstance(devices, list) else []

    def get_client(self, network_id, mac):
        """Look up a client by MAC in a network. Returns None if not found."""
        mac = normalize_mac(mac)
        try:
            return self._request(
                f"/networks/{urllib.parse.quote(str(network_id))}"
                f"/clients/{urllib.parse.quote(mac)}")
        except MerakiError as exc:
            if str(exc) == "__NOT_FOUND__":
                return None
            raise

    def search_client(self, org_id, mac):
        """Org-wide client lookup by MAC — no network needed.

        Returns the payload from /organizations/{id}/clients/search, whose
        `records` list holds one entry per network the MAC was seen on, or
        None if the client isn't found anywhere in the organization.
        """
        mac = normalize_mac(mac)
        try:
            payload = self._request(
                f"/organizations/{urllib.parse.quote(str(org_id))}/clients/search"
                f"?mac={urllib.parse.quote(mac)}")
        except MerakiError as exc:
            if str(exc) == "__NOT_FOUND__":
                return None
            raise
        if not isinstance(payload, dict) or not payload.get("records"):
            return None
        return payload


def normalize_mac(mac):
    """Meraki wants aa:bb:cc:dd:ee:ff."""
    hexed = re.sub(r"[^0-9A-Fa-f]", "", mac or "")
    if len(hexed) != 12:
        return (mac or "").strip().lower()
    return ":".join(hexed[i:i + 2] for i in range(0, 12, 2)).lower()


def friendly_timestamp(value):
    """Meraki timestamps arrive as ISO 8601 or epoch seconds; localize them."""
    if value in (None, ""):
        return ""
    try:
        if isinstance(value, (int, float)):
            stamp = datetime.datetime.fromtimestamp(float(value))
        else:
            stamp = datetime.datetime.fromisoformat(
                str(value).replace("Z", "+00:00")).astimezone().replace(tzinfo=None)
        return stamp.strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return str(value)


# ---------------------------------------------------------------------------
# Dialogs
# ---------------------------------------------------------------------------

class SettingsDialog(tk.Toplevel):
    """Connection credentials + message/name templates, saved on OK."""

    def __init__(self, parent, settings, on_saved=None):
        super().__init__(parent)
        self.title("Settings")
        self.settings = settings
        self.on_saved = on_saved
        self.resizable(False, False)
        self.transient(parent)
        self.grab_set()

        notebook = ttk.Notebook(self)
        notebook.pack(fill="both", expand=True, padx=12, pady=(12, 6))

        self._build_connection_tab(notebook)
        self._build_templates_tab(notebook)
        self._build_meraki_tab(notebook)

        buttons = ttk.Frame(self)
        buttons.pack(fill="x", padx=12, pady=(0, 12))
        ttk.Button(buttons, text="Cancel", command=self.destroy).pack(side="right", padx=(6, 0))
        ttk.Button(buttons, text="Save", command=self._save).pack(side="right")
        ttk.Button(buttons, text="Test connection", command=self._test).pack(side="left")

        if not settings.keychain_available:
            ttk.Label(
                buttons,
                text="Keychain unavailable — secrets stored in settings file",
                foreground="#b25c00",
            ).pack(side="left", padx=(10, 0))

        self.bind("<Escape>", lambda _e: self.destroy())
        self._center_over(parent)

    def _center_over(self, parent):
        self.update_idletasks()
        px, py = parent.winfo_rootx(), parent.winfo_rooty()
        pw, ph = parent.winfo_width(), parent.winfo_height()
        w, h = self.winfo_width(), self.winfo_height()
        self.geometry(f"+{px + (pw - w) // 2}+{py + (ph - h) // 3}")

    # -- Connection tab ------------------------------------------------------
    def _build_connection_tab(self, notebook):
        tab = ttk.Frame(notebook, padding=14)
        notebook.add(tab, text="Connection")
        s = self.settings

        ttk.Label(tab, text="Jamf Pro URL").grid(row=0, column=0, sticky="w", pady=3)
        self.var_url = tk.StringVar(value=s.get("jamf_url"))
        ttk.Entry(tab, textvariable=self.var_url, width=42).grid(row=0, column=1, sticky="we", pady=3)
        ttk.Label(tab, text="e.g. https://yourorg.jamfcloud.com", foreground="gray").grid(
            row=1, column=1, sticky="w")

        ttk.Label(tab, text="Authentication").grid(row=2, column=0, sticky="w", pady=(12, 3))
        self.var_auth = tk.StringVar(value=s.get("auth_method", "oauth"))
        radios = ttk.Frame(tab)
        radios.grid(row=2, column=1, sticky="w", pady=(12, 3))
        ttk.Radiobutton(radios, text="API client (recommended)", value="oauth",
                        variable=self.var_auth, command=self._sync_auth_labels).pack(side="left")
        ttk.Radiobutton(radios, text="User account", value="basic",
                        variable=self.var_auth, command=self._sync_auth_labels).pack(side="left", padx=(10, 0))

        self.lbl_cred_a = ttk.Label(tab, text="Client ID")
        self.lbl_cred_a.grid(row=3, column=0, sticky="w", pady=3)
        self.var_cred_a = tk.StringVar(value=self._initial_cred("a"))
        ttk.Entry(tab, textvariable=self.var_cred_a, width=42).grid(row=3, column=1, sticky="we", pady=3)

        self.lbl_cred_b = ttk.Label(tab, text="Client secret")
        self.lbl_cred_b.grid(row=4, column=0, sticky="w", pady=3)
        self.var_cred_b = tk.StringVar(value=self._initial_cred("b"))
        ttk.Entry(tab, textvariable=self.var_cred_b, width=42, show="•").grid(
            row=4, column=1, sticky="we", pady=3)

        self.var_confirm = tk.BooleanVar(value=bool(s.get("verify_notes", True)))
        ttk.Checkbutton(tab, text="Preview and confirm before sending any command",
                        variable=self.var_confirm).grid(row=5, column=0, columnspan=2,
                                                        sticky="w", pady=(14, 0))

        ttk.Label(tab, text="Double-click action").grid(row=6, column=0, sticky="w", pady=(10, 0))
        self._dc_labels = [label for label, _m in App.ALL_ACTIONS]
        self._dc_methods = {label: method for label, method in App.ALL_ACTIONS}
        current_method = s.get("double_click_action", "action_open_in_jamf")
        current_label = next((l for l, m in App.ALL_ACTIONS if m == current_method),
                             "Open in Jamf Pro")
        self.var_double_click = tk.StringVar(value=current_label)
        ttk.Combobox(tab, textvariable=self.var_double_click, state="readonly",
                     values=self._dc_labels, width=24).grid(row=6, column=1,
                                                            sticky="w", pady=(10, 0))

        ttk.Separator(tab).grid(row=7, column=0, columnspan=2, sticky="we", pady=10)

        ttk.Label(tab, text="CA bundle (.pem)").grid(row=8, column=0, sticky="w", pady=3)
        ca_row = ttk.Frame(tab)
        ca_row.grid(row=8, column=1, sticky="we", pady=3)
        self.var_ca = tk.StringVar(value=s.get("ssl_ca_bundle", ""))
        ttk.Entry(ca_row, textvariable=self.var_ca).pack(side="left", fill="x", expand=True)
        ttk.Button(ca_row, text="Browse…", command=self._pick_ca).pack(side="left", padx=(6, 0))
        ttk.Label(tab, text="Only needed if your server's certificate comes from an internal CA",
                  foreground="gray").grid(row=9, column=1, sticky="w")

        self.var_ssl = tk.BooleanVar(value=bool(s.get("ssl_verify", True)))
        ttk.Checkbutton(tab, text="Verify SSL certificates (recommended)",
                        variable=self.var_ssl,
                        command=self._sync_ssl_warning).grid(row=10, column=0, columnspan=2,
                                                             sticky="w", pady=(8, 0))
        self.lbl_ssl_warn = ttk.Label(
            tab, foreground="#b00020", wraplength=420, justify="left",
            text="Warning: with verification off, credentials could be exposed to "
                 "anyone intercepting traffic to the server. Prefer a CA bundle.")
        self.lbl_ssl_warn.grid(row=11, column=0, columnspan=2, sticky="w")

        tab.columnconfigure(1, weight=1)
        self._sync_auth_labels()
        self._sync_ssl_warning()

    def _pick_ca(self):
        path = filedialog.askopenfilename(
            parent=self, title="Choose CA bundle",
            filetypes=[("Certificates", "*.pem *.crt *.cer"), ("All files", "*")])
        if path:
            self.var_ca.set(path)

    def _sync_ssl_warning(self):
        if self.var_ssl.get():
            self.lbl_ssl_warn.grid_remove()
        else:
            self.lbl_ssl_warn.grid()

    def _initial_cred(self, which):
        if self.settings.get("auth_method", "oauth") == "oauth":
            return self.settings.get_secret("client_id" if which == "a" else "client_secret")
        return self.settings.get_secret("username" if which == "a" else "password")

    def _sync_auth_labels(self):
        if self.var_auth.get() == "oauth":
            self.lbl_cred_a.config(text="Client ID")
            self.lbl_cred_b.config(text="Client secret")
        else:
            self.lbl_cred_a.config(text="Username")
            self.lbl_cred_b.config(text="Password")

    # -- Templates tab -------------------------------------------------------
    def _build_templates_tab(self, notebook):
        tab = ttk.Frame(notebook, padding=14)
        notebook.add(tab, text="Templates")
        s = self.settings
        row = 0

        ttk.Label(tab, text="Lost Mode message").grid(row=row, column=0, sticky="nw", pady=3)
        self.txt_lost = tk.Text(tab, width=48, height=3, wrap="word")
        self.txt_lost.insert("1.0", s.get("lost_mode_message"))
        self.txt_lost.grid(row=row, column=1, sticky="we", pady=3)
        row += 1

        ttk.Label(tab, text="Lost Mode phone").grid(row=row, column=0, sticky="w", pady=3)
        self.var_lost_phone = tk.StringVar(value=s.get("lost_mode_phone"))
        ttk.Entry(tab, textvariable=self.var_lost_phone).grid(row=row, column=1, sticky="we", pady=3)
        row += 1

        ttk.Label(tab, text="Lost Mode footnote").grid(row=row, column=0, sticky="w", pady=3)
        self.var_lost_foot = tk.StringVar(value=s.get("lost_mode_footnote"))
        ttk.Entry(tab, textvariable=self.var_lost_foot).grid(row=row, column=1, sticky="we", pady=3)
        row += 1

        self.var_lost_sound = tk.BooleanVar(value=bool(s.get("lost_mode_sound", False)))
        ttk.Checkbutton(tab, text="Play a sound when Lost Mode is enabled",
                        variable=self.var_lost_sound).grid(row=row, column=1, sticky="w", pady=(0, 8))
        row += 1

        ttk.Separator(tab).grid(row=row, column=0, columnspan=2, sticky="we", pady=6)
        row += 1

        ttk.Label(tab, text="Rename format (computers)").grid(row=row, column=0, sticky="w", pady=3)
        self.var_rename_computer = tk.StringVar(value=s.get("rename_format_computer"))
        ttk.Entry(tab, textvariable=self.var_rename_computer).grid(row=row, column=1, sticky="we", pady=3)
        row += 1

        ttk.Label(tab, text="Rename format (mobile)").grid(row=row, column=0, sticky="w", pady=3)
        self.var_rename_mobile = tk.StringVar(value=s.get("rename_format_mobile"))
        ttk.Entry(tab, textvariable=self.var_rename_mobile).grid(row=row, column=1, sticky="we", pady=3)
        row += 1
        ttk.Label(tab, text="e.g. {username}-{model_short}-{serial_last4}",
                  foreground="gray").grid(row=row, column=1, sticky="w")
        row += 1

        ttk.Separator(tab).grid(row=row, column=0, columnspan=2, sticky="we", pady=6)
        row += 1

        ttk.Label(tab, text="Lock message").grid(row=row, column=0, sticky="nw", pady=3)
        self.txt_lock = tk.Text(tab, width=48, height=2, wrap="word")
        self.txt_lock.insert("1.0", s.get("lock_message"))
        self.txt_lock.grid(row=row, column=1, sticky="we", pady=3)
        row += 1

        ttk.Label(tab, text="Templates accept {tags} — see Help for the full list.",
                  foreground="gray").grid(row=row, column=0, columnspan=2, sticky="w", pady=(10, 0))
        tab.columnconfigure(1, weight=1)

    # -- Meraki tab ----------------------------------------------------------
    def _build_meraki_tab(self, notebook):
        tab = ttk.Frame(notebook, padding=14)
        notebook.add(tab, text="Meraki")
        s = self.settings

        ttk.Label(tab, text="Dashboard API key").grid(row=0, column=0, sticky="w", pady=3)
        self.var_meraki_key = tk.StringVar(value=s.get_secret("meraki_api_key"))
        ttk.Entry(tab, textvariable=self.var_meraki_key, width=42, show="•").grid(
            row=0, column=1, sticky="we", pady=3)
        ttk.Label(tab, text="Generate one in the Meraki Dashboard under your profile\n"
                            "(My profile > API access). Stored in the Keychain.",
                  foreground="gray", justify="left").grid(row=1, column=1, sticky="w")

        org_name = s.get("meraki_org_name") or "chosen automatically on first use"
        ttk.Label(tab, text="Organization").grid(row=2, column=0, sticky="w", pady=(14, 3))
        ttk.Label(tab, text=org_name).grid(row=2, column=1, sticky="w", pady=(14, 3))
        ttk.Label(tab, text="Lookups search your whole organization, so no network\n"
                            "needs to be picked. If your key sees several organizations,\n"
                            "you'll be asked once and the choice is remembered.",
                  foreground="gray", justify="left").grid(row=3, column=1, sticky="w")
        tab.columnconfigure(1, weight=1)

    # -- actions -------------------------------------------------------------
    def _collect(self):
        s = self.settings
        s.set("jamf_url", self.var_url.get().strip().rstrip("/"))
        s.set("auth_method", self.var_auth.get())
        s.set("verify_notes", bool(self.var_confirm.get()))
        s.set("ssl_verify", bool(self.var_ssl.get()))
        s.set("ssl_ca_bundle", self.var_ca.get().strip())
        s.set("lost_mode_message", self.txt_lost.get("1.0", "end").strip())
        s.set("lost_mode_phone", self.var_lost_phone.get().strip())
        s.set("lost_mode_footnote", self.var_lost_foot.get().strip())
        s.set("lost_mode_sound", bool(self.var_lost_sound.get()))
        s.set("rename_format_computer", self.var_rename_computer.get().strip())
        s.set("rename_format_mobile", self.var_rename_mobile.get().strip())
        s.set("double_click_action",
              self._dc_methods.get(self.var_double_click.get(), "action_open_in_jamf"))
        s.set("lock_message", self.txt_lock.get("1.0", "end").strip())
        if self.var_auth.get() == "oauth":
            s.set_secret("client_id", self.var_cred_a.get().strip())
            s.set_secret("client_secret", self.var_cred_b.get())
        else:
            s.set_secret("username", self.var_cred_a.get().strip())
            s.set_secret("password", self.var_cred_b.get())
        s.set_secret("meraki_api_key", self.var_meraki_key.get().strip())

    def _save(self):
        url = self.var_url.get().strip()
        if url and not url.lower().startswith("https://"):
            messagebox.showwarning(APP_NAME, "The Jamf Pro URL should start with https://",
                                   parent=self)
            return
        self._collect()
        self.settings.save()
        if self.on_saved:
            self.on_saved()
        self.destroy()

    def _test(self):
        self._collect()
        client = JamfClient(
            self.settings.get("jamf_url"),
            self.settings.get("auth_method"),
            self.var_cred_a.get().strip(),
            self.var_cred_b.get(),
            ssl_verify=bool(self.var_ssl.get()),
            ssl_ca_bundle=self.var_ca.get().strip(),
        )

        def worker():
            try:
                client.test_connection()
                error_message = None
            except JamfError as exc:
                error_message = str(exc)
            except Exception as exc:  # anything unexpected — still surface it
                error_message = f"Unexpected error: {exc}"

            def report():
                if error_message is None:
                    messagebox.showinfo(
                        APP_NAME, "Connection successful — a token was issued.", parent=self)
                else:
                    messagebox.showerror(APP_NAME, error_message, parent=self)

            self.after(0, report)

        threading.Thread(target=worker, daemon=True).start()


HELP_TEXT = f"""{APP_NAME} {APP_VERSION}

MENUS AND SHORTCUTS
Cmd+N add devices, Cmd+R refresh info, Cmd+A select all,
Cmd+C copy selection, Cmd+W close a dialog, Cmd+, settings.
Every action button is also in the Device menu.

On macOS the first menu is titled with the name of the running
application bundle, which is why it reads "Python" when the app is
started with `python3 jamf_toolbox.py`. The Services, Hide and Quit
items in that menu come from macOS itself and appear in every Mac
application.

GETTING STARTED
1. Open Settings (the Settings button, Cmd+,, or the app menu) and
   enter your Jamf Pro URL
   and credentials. An API client (Settings > System > API roles and
   clients in Jamf Pro) is recommended over a user account.
2. Grant the API role at least these privileges:
      Read Computers, Update Computers,
      Read Mobile Devices, Send Mobile Device Commands
      (Lost Mode, Set Device Name, Update Inventory, Lock Device),
      Send Computer Remote Lock Command, Send Computer Remote
      Command to Download and Install OS X Update / MDM commands.
3. Use "Test connection" to verify, then Save. Settings persist in
   ~/Library/Application Support/JamfToolbox and credentials are
   kept in your macOS Keychain.
4. On-prem servers with certificates from an internal CA: if the
   connection fails with a certificate error, first try running
   "Install Certificates.command" from your Python folder in
   /Applications. If the certificate comes from your organization's
   own CA, export it as a .pem and choose it as the CA bundle in
   Settings > Connection. Disabling verification is a last resort.

USING THE APP
* The main window shows your saved working lists — one for
  Computers and one for Mobile Devices. Use the radio buttons to
  switch between them. Lists persist between launches.
* Click "Add…" (Cmd+F or Cmd+N) to search Jamf Pro by name, serial,
  username, or asset tag and add results to the list. Cmd-click to
  select several results; devices already in your list appear gray.
* Select devices and click "Remove" (or press Delete) to take them
  off the list. This only edits your list — it never touches Jamf.
* "Refresh info" re-fetches the listed devices' details from
  Jamf Pro, and drops devices that no longer exist there. Details
  (model, Wi-Fi MAC, IP) are also filled in automatically when a
  device is added. For computers, the MAC shown is the primary
  MAC address reported to Jamf, and the IP is the last reported
  LAN IP. IPs are only as fresh as the device's last check-in.
* Choose which columns the list shows by right-clicking any
  column header: tick fields on or off, pick "Arrange Columns…"
  to set their order, or "Reset to Default Columns". Your
  selection and order are saved between launches. A horizontal
  scroll bar appears when the columns are wider than the window.
  Devices saved before this feature will show blanks in the new
  columns until you run "Refresh info" once.
* Reorder the list by clicking a column header to sort by it
  (click again to reverse), or select rows and use the ↑ / ↓
  buttons (or Cmd+Up / Cmd+Down) to move them by hand. A manual
  move clears the column sort.
* "Export…" writes the current list to a CSV or Excel (.xlsx)
  file — choose the extension in the save dialog.
* Copying works the same way everywhere: right-click (or
  Ctrl-click) whatever you want to copy and pick from the menu.
  In the list, right-clicking a cell offers that field, the
  selected row(s), the row(s) as CSV, or the whole list as CSV.
  Cmd+C copies the selected row(s) as tab-separated text. CSV
  copies include a header row and paste cleanly into a spreadsheet
  or a ticket.
* Bulk actions: select several devices (Shift-click or Cmd-click,
  or Cmd+A for all), then right-click and choose Toggle Lost Mode,
  Lock Device, Rename Device, or Open in Jamf Pro — the menu shows
  the number selected. Each shows exactly what will happen before
  anything is sent, runs one device at a time with a progress
  window you can cancel, and logs a per-device result plus a
  summary. Bulk rename uses the type's default template; bulk Lost
  Mode asks once whether to enable or disable and applies that to
  every selected device; bulk locking a Mac uses one PIN for the
  whole batch.
* To act on a device, right-click it and choose an action from
  the top of the menu, or use the Device menu in the menu bar.
  Double-clicking a row runs a configurable action (Settings >
  Connection; the default opens the device in Jamf Pro). The
  actions appear in the same order for both device types; the
  ones that apply to mobile devices only (Toggle Lost Mode and
  Update Inventory) are shown disabled for computers, because Jamf
  Pro has no equivalent remote command for a Mac (which reports
  inventory by running its own recon). If previews are
  enabled (Settings), you can review and edit the final message
  or name before anything is sent.
* The Activity log at the bottom can be resized by dragging the
  grip handle (the strip with dots just above it); right-click the
  log to copy or clear it.
* Computers and mobile devices each have their own rename format
  in Settings > Templates.
* "Show device info" opens the device's full Jamf Pro record as a
  collapsible tree, mirroring the API's structure. Use the filter
  box to find fields, right-click any field to copy its value or
  name (branches copy as JSON), or press Cmd+C on a selection.
  The window stays open, so you can keep it beside the main list.
* "Meraki info" looks up the selected device's Wi-Fi MAC in the
  Meraki Dashboard and shows its description, IP, recent SSID, the
  AP it's connected to, when it was last seen, and its status.
  Add a Dashboard API key in Settings > Meraki first. The search
  covers your whole organization in a single request, so there is
  no network to pick — the network the device was found on is
  shown in the window. If your key can see several organizations,
  you are asked once and that choice is remembered. Right-click
  any field to copy it; "Full response…" shows the complete
  Meraki record. If a device isn't found (it hasn't been on the
  Wi-Fi recently), you can fall back to searching one network.
  The MAC address is re-read from Jamf Pro on every lookup rather
  than taken from the saved list, so a stale row can't send the
  query to the wrong device; the row is refreshed at the same
  time. Note that if a device has iOS/macOS "Private Wi-Fi
  Address" enabled for your SSID, Meraki sees a randomized MAC
  and the lookup won't match the hardware MAC Jamf reports.
* "Toggle Lost Mode" checks whether Lost Mode is currently on for
  the selected device and offers the opposite action: it previews
  your message before enabling, and simply confirms before turning
  it off. Supervised mobile devices only.
* Rename sends the Set Device Name command through Jamf Pro's
  modern MDM commands API for mobile devices (the older Classic
  command was removed in recent Jamf versions); for computers it
  updates the record name and sends the SETTINGS MDM command. The new
  name appears in Jamf's inventory after the device's next
  check-in — use Refresh info to pull it in.
* Locking a computer prompts for a 6-digit PIN that is required to
  unlock it — keep that PIN somewhere safe. Mobile devices lock
  with their existing passcode instead.

TEMPLATE TAGS
Templates in Settings may contain tags in curly braces. Each tag is
replaced with data from the selected device's record when a command
is sent. Unknown tags are left untouched so typos are easy to spot.
"""


class HelpDialog(tk.Toplevel):
    def __init__(self, parent):
        super().__init__(parent)
        self.title(f"{APP_NAME} Help")
        self.transient(parent)
        self.geometry("620x560")

        container = ttk.Frame(self, padding=12)
        container.pack(fill="both", expand=True)

        text = tk.Text(container, wrap="word", borderwidth=0, highlightthickness=0)
        scroll = ttk.Scrollbar(container, command=text.yview)
        text.configure(yscrollcommand=scroll.set)
        text.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")

        text.insert("end", HELP_TEXT + "\n")
        widest = max(len(tag) for tag, _ in TAG_DESCRIPTIONS)
        for tag, desc in TAG_DESCRIPTIONS:
            text.insert("end", f"  {tag.ljust(widest + 2)}{desc}\n", "mono")
        text.tag_configure("mono", font=("Menlo", 11))
        text.configure(state="disabled")

        ttk.Button(self, text="Close", command=self.destroy).pack(pady=(0, 12))
        self.bind("<Escape>", lambda _e: self.destroy())


class DeviceInfoDialog(tk.Toplevel):
    """Browse a device's full API record as a collapsible key/value tree.

    Mirrors the structure returned by /JSSResource/computers/id/{id} or
    /JSSResource/mobiledevices/id/{id}. Any field can be copied via
    right-click or Cmd+C, and the whole record can be filtered.
    """

    def __init__(self, parent, title, record):
        super().__init__(parent)
        self.title(title)
        self.record = record
        self.geometry("700x560")
        self.minsize(480, 320)
        # deliberately non-modal: keep it open next to the main window

        top = ttk.Frame(self, padding=(12, 10, 12, 6))
        top.pack(fill="x")
        ttk.Label(top, text="Filter:").pack(side="left")
        self.var_filter = tk.StringVar()
        entry = ttk.Entry(top, textvariable=self.var_filter)
        entry.pack(side="left", fill="x", expand=True, padx=(6, 8))
        entry.bind("<KeyRelease>", self._on_filter_typed)
        entry.bind("<Escape>", lambda _e: self.var_filter.set("") or self._rebuild())
        ttk.Button(top, text="Expand all", command=lambda: self._set_open(True)).pack(side="left")
        ttk.Button(top, text="Collapse all",
                   command=lambda: self._set_open(False)).pack(side="left", padx=(6, 0))

        mid = ttk.Frame(self, padding=(12, 0, 12, 6))
        mid.pack(fill="both", expand=True)
        self.tree = ttk.Treeview(mid, columns=("value",), show="tree headings",
                                 selectmode="browse")
        self.tree.heading("#0", text="Field")
        self.tree.heading("value", text="Value")
        self.tree.column("#0", width=260, anchor="w")
        self.tree.column("value", width=360, anchor="w")
        scroll = ttk.Scrollbar(mid, command=self.tree.yview)
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.pack(side="left", fill="both", expand=True)
        scroll.pack(side="left", fill="y")

        bottom = ttk.Frame(self, padding=(12, 0, 12, 12))
        bottom.pack(fill="x")
        self.var_status = tk.StringVar(
            value="Right-click a field to copy it. Cmd+C copies the selected value.")
        ttk.Label(bottom, textvariable=self.var_status, foreground="gray").pack(side="left")
        ttk.Button(bottom, text="Close", command=self.destroy).pack(side="right")
        ttk.Button(bottom, text="Copy all as JSON",
                   command=self._copy_all).pack(side="right", padx=(0, 6))

        self._nodes = {}          # iid -> (key, raw python value)
        self._filter_job = None
        self._rebuild()

        self.tree.bind("<Button-2>", self._show_copy_menu)
        self.tree.bind("<Button-3>", self._show_copy_menu)
        self.tree.bind("<Control-Button-1>", self._show_copy_menu)
        self.tree.bind("<Command-c>", lambda _e: self._copy_selected_value())
        self.bind("<Escape>", lambda _e: self.destroy())

    # -- building ------------------------------------------------------------
    @staticmethod
    def _preview(value):
        """One-line value column text for any node."""
        if isinstance(value, dict):
            return f"{{{len(value)} field(s)}}"
        if isinstance(value, list):
            return f"[{len(value)} item(s)]"
        if value is None:
            return ""
        if isinstance(value, bool):
            return "true" if value else "false"
        return str(value)

    def _insert(self, parent, key, value, query):
        """Insert key/value under parent; returns True if this branch matched
        the filter (empty query matches everything)."""
        text = str(key)
        if isinstance(value, dict):
            iid = self.tree.insert(parent, "end", text=text, values=(self._preview(value),))
            matched = self._matches(text, "", query)
            child_match = False
            for k, v in value.items():
                child_match = self._insert(iid, k, v, query) or child_match
            if query and not (matched or child_match):
                self.tree.delete(iid)
                return False
            self._nodes[iid] = (text, value)
            if query:
                self.tree.item(iid, open=True)
            return matched or child_match
        if isinstance(value, list):
            iid = self.tree.insert(parent, "end", text=text, values=(self._preview(value),))
            matched = self._matches(text, "", query)
            child_match = False
            for index, item in enumerate(value):
                child_match = self._insert(iid, f"[{index}]", item, query) or child_match
            if query and not (matched or child_match):
                self.tree.delete(iid)
                return False
            self._nodes[iid] = (text, value)
            if query:
                self.tree.item(iid, open=True)
            return matched or child_match
        preview = self._preview(value)
        if query and not self._matches(text, preview, query):
            return False
        iid = self.tree.insert(parent, "end", text=text, values=(preview,))
        self._nodes[iid] = (text, value)
        return True

    @staticmethod
    def _matches(key, preview, query):
        if not query:
            return True
        query = query.lower()
        return query in key.lower() or query in preview.lower()

    def _rebuild(self):
        query = self.var_filter.get().strip()
        self.tree.delete(*self.tree.get_children())
        self._nodes.clear()
        for key, value in self.record.items():
            self._insert("", key, value, query)
        if not query:
            # open the top-level sections (general, location, hardware, …)
            for iid in self.tree.get_children():
                self.tree.item(iid, open=True)
        count = len(self._nodes)
        self.var_status.set(f"{count} field(s) shown."
                            + ("" if not query else f" Filter: “{query}”"))

    def _on_filter_typed(self, _event):
        if self._filter_job:
            self.after_cancel(self._filter_job)
        self._filter_job = self.after(250, self._rebuild)

    def _set_open(self, is_open):
        def walk(iid):
            self.tree.item(iid, open=is_open)
            for child in self.tree.get_children(iid):
                walk(child)
        for iid in self.tree.get_children():
            walk(iid)

    # -- copying -------------------------------------------------------------
    def _copy(self, text, what):
        self.clipboard_clear()
        self.clipboard_append(text)
        shown = text if len(text) <= 60 and "\n" not in text else f"{len(text)} characters"
        self.var_status.set(f"Copied {what}: {shown}")

    @staticmethod
    def _as_text(value):
        if isinstance(value, (dict, list)):
            return json.dumps(value, indent=2)
        if value is None:
            return ""
        if isinstance(value, bool):
            return "true" if value else "false"
        return str(value)

    def _copy_selected_value(self):
        selection = self.tree.selection()
        if not selection:
            return
        key, value = self._nodes[selection[0]]
        self._copy(self._as_text(value), key)

    def _copy_all(self):
        self._copy(json.dumps(self.record, indent=2), "full record")

    def _show_copy_menu(self, event):
        iid = self.tree.identify_row(event.y)
        if not iid:
            return
        self.tree.selection_set(iid)
        key, value = self._nodes[iid]
        is_branch = isinstance(value, (dict, list))
        value_text = self._as_text(value)

        menu = tk.Menu(self, tearoff=0)
        if is_branch:
            menu.add_command(label=f"Copy “{key}” as JSON",
                             command=lambda: self._copy(value_text, key))
        else:
            shown = value_text if len(value_text) <= 40 else value_text[:37] + "…"
            menu.add_command(label=f"Copy value ({shown})" if shown else "Copy value",
                             command=lambda: self._copy(value_text, key))
            menu.add_command(label="Copy field name",
                             command=lambda: self._copy(key, "field name"))
            menu.add_command(label="Copy “field: value”",
                             command=lambda: self._copy(f"{key}: {value_text}", key))
        menu.tk_popup(event.x_root, event.y_root)
        return "break"


class BulkProgressDialog(tk.Toplevel):
    """Progress window for a bulk operation, with a Cancel button.

    The work itself runs on a worker thread; this window is updated from the
    UI thread via `step()` and closed by `finish()`.
    """

    def __init__(self, parent, title, total):
        super().__init__(parent)
        self.title(title)
        self.transient(parent)
        self.resizable(False, False)
        self.cancelled = False

        frame = ttk.Frame(self, padding=16)
        frame.pack(fill="both", expand=True)

        self.var_status = tk.StringVar(value="Starting…")
        ttk.Label(frame, textvariable=self.var_status, width=52,
                  anchor="w").pack(anchor="w")

        self.bar = ttk.Progressbar(frame, mode="determinate", maximum=total,
                                   length=380)
        self.bar.pack(fill="x", pady=(8, 10))

        self.btn_cancel = ttk.Button(frame, text="Cancel", command=self._cancel)
        self.btn_cancel.pack(anchor="e")

        # Cancel rather than closing mid-run, so the worker can stop cleanly.
        self.protocol("WM_DELETE_WINDOW", self._cancel)
        self.update_idletasks()
        px, py = parent.winfo_rootx(), parent.winfo_rooty()
        self.geometry(f"+{px + 160}+{py + 140}")
        self.grab_set()

    def _cancel(self):
        self.cancelled = True
        self.var_status.set("Finishing the current device, then stopping…")
        self.btn_cancel.state(["disabled"])

    def step(self, index, text):
        self.bar["value"] = index
        self.var_status.set(text)

    def finish(self):
        try:
            self.grab_release()
        except tk.TclError:
            pass
        self.destroy()


class BulkConfirmDialog(tk.Toplevel):
    """Shows exactly what a bulk action will do, one line per device, and
    requires explicit confirmation before anything is sent."""

    def __init__(self, parent, title, intro, lines, confirm_label,
                 warning=""):
        super().__init__(parent)
        self.title(title)
        self.transient(parent)
        self.result = False

        frame = ttk.Frame(self, padding=14)
        frame.pack(fill="both", expand=True)

        ttk.Label(frame, text=intro, wraplength=520,
                  justify="left").pack(anchor="w")

        if warning:
            ttk.Label(frame, text=warning, wraplength=520, justify="left",
                      foreground="#b00020").pack(anchor="w", pady=(8, 0))

        list_frame = ttk.Frame(frame)
        list_frame.pack(fill="both", expand=True, pady=(10, 0))
        text = tk.Text(list_frame, height=min(14, max(4, len(lines))), width=64,
                       wrap="none", borderwidth=1, relief="solid")
        scroll = ttk.Scrollbar(list_frame, command=text.yview)
        text.configure(yscrollcommand=scroll.set)
        text.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")
        text.insert("1.0", "\n".join(lines))
        text.configure(state="disabled")

        buttons = ttk.Frame(frame)
        buttons.pack(fill="x", pady=(12, 0))
        ttk.Button(buttons, text="Cancel",
                   command=self.destroy).pack(side="right")
        ttk.Button(buttons, text=confirm_label,
                   command=self._confirm).pack(side="right", padx=(0, 6))

        self.update_idletasks()
        px, py = parent.winfo_rootx(), parent.winfo_rooty()
        self.geometry(f"+{px + 100}+{py + 90}")
        self.grab_set()
        self.wait_window(self)

    def _confirm(self):
        self.result = True
        self.destroy()


class PreviewDialog(tk.Toplevel):
    """Shows the rendered template for review/editing before sending."""

    def __init__(self, parent, title, intro, fields, confirm_label="Send"):
        """fields: list of (label, initial_value, multiline: bool)"""
        super().__init__(parent)
        self.title(title)
        self.result = None
        self.transient(parent)
        self.grab_set()
        self.resizable(False, False)

        frame = ttk.Frame(self, padding=14)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text=intro, wraplength=440, justify="left").grid(
            row=0, column=0, columnspan=2, sticky="w", pady=(0, 10))

        self._widgets = []
        row = 1
        for label, value, multiline in fields:
            ttk.Label(frame, text=label).grid(row=row, column=0, sticky="nw", pady=3)
            if multiline:
                widget = tk.Text(frame, width=44, height=3, wrap="word")
                widget.insert("1.0", value)
            else:
                var = tk.StringVar(value=value)
                widget = ttk.Entry(frame, textvariable=var, width=44)
                widget.var = var
            widget.grid(row=row, column=1, sticky="we", pady=3)
            self._widgets.append((label, widget, multiline))
            row += 1

        buttons = ttk.Frame(frame)
        buttons.grid(row=row, column=0, columnspan=2, sticky="e", pady=(12, 0))
        ttk.Button(buttons, text="Cancel", command=self.destroy).pack(side="right", padx=(6, 0))
        ttk.Button(buttons, text=confirm_label, command=self._confirm).pack(side="right")

        self.bind("<Escape>", lambda _e: self.destroy())
        self.update_idletasks()
        px, py = parent.winfo_rootx(), parent.winfo_rooty()
        self.geometry(f"+{px + 80}+{py + 90}")
        self.wait_window()

    def _confirm(self):
        values = {}
        for label, widget, multiline in self._widgets:
            if multiline:
                values[label] = widget.get("1.0", "end").strip()
            else:
                values[label] = widget.var.get().strip()
        self.result = values
        self.destroy()


# ---------------------------------------------------------------------------
# Meraki dialogs
# ---------------------------------------------------------------------------

class MerakiOrgDialog(tk.Toplevel):
    """Pick a Meraki organization; remembered for future lookups."""

    def __init__(self, parent, orgs, settings, on_selected):
        super().__init__(parent)
        self.title("Choose Meraki organization")
        self.settings = settings
        self.on_selected = on_selected
        self.orgs = orgs
        self.transient(parent)
        self.grab_set()
        self.resizable(False, False)

        frame = ttk.Frame(self, padding=14)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="Your API key can see more than one organization.\n"
                              "Choose the one your devices live in — it will be remembered.",
                  justify="left").pack(anchor="w", pady=(0, 10))

        self.var_org = tk.StringVar()
        self.combo = ttk.Combobox(frame, textvariable=self.var_org, state="readonly",
                                  width=40, values=[o.get("name", o.get("id", "?"))
                                                    for o in orgs])
        self.combo.pack(fill="x")
        saved = str(settings.get("meraki_org_id"))
        index = next((i for i, o in enumerate(orgs) if str(o.get("id")) == saved), 0)
        if orgs:
            self.combo.current(index)

        buttons = ttk.Frame(frame)
        buttons.pack(fill="x", pady=(14, 0))
        ttk.Button(buttons, text="Cancel", command=self.destroy).pack(side="right", padx=(6, 0))
        ttk.Button(buttons, text="Use this organization",
                   command=self._select).pack(side="right")
        self.bind("<Escape>", lambda _e: self.destroy())

    def _select(self):
        index = self.combo.current()
        if not (0 <= index < len(self.orgs)):
            return
        org = self.orgs[index]
        self.settings.set("meraki_org_id", str(org.get("id")))
        self.settings.set("meraki_org_name", org.get("name", ""))
        self.settings.save()
        self.destroy()
        self.on_selected(str(org.get("id")))


class MerakiNetworkDialog(tk.Toplevel):
    """Pick a Meraki organization + network; remembered as the default."""

    def __init__(self, parent, meraki, settings, on_selected):
        super().__init__(parent)
        self.title("Choose Meraki network")
        self.meraki = meraki
        self.settings = settings
        self.on_selected = on_selected
        self.transient(parent)
        self.grab_set()
        self.geometry("460x420")
        self.minsize(380, 320)

        frame = ttk.Frame(self, padding=12)
        frame.pack(fill="both", expand=True)

        ttk.Label(frame, text="Organization").pack(anchor="w")
        self.var_org = tk.StringVar()
        self.combo_org = ttk.Combobox(frame, textvariable=self.var_org, state="readonly")
        self.combo_org.pack(fill="x", pady=(2, 8))
        self.combo_org.bind("<<ComboboxSelected>>", lambda _e: self._load_networks())

        ttk.Label(frame, text="Network").pack(anchor="w")
        self.var_filter = tk.StringVar()
        filter_entry = ttk.Entry(frame, textvariable=self.var_filter)
        filter_entry.pack(fill="x", pady=(2, 4))
        filter_entry.bind("<KeyRelease>", lambda _e: self._render_networks())

        list_frame = ttk.Frame(frame)
        list_frame.pack(fill="both", expand=True)
        self.listbox = tk.Listbox(list_frame, exportselection=False)
        scroll = ttk.Scrollbar(list_frame, command=self.listbox.yview)
        self.listbox.configure(yscrollcommand=scroll.set)
        self.listbox.pack(side="left", fill="both", expand=True)
        scroll.pack(side="left", fill="y")
        self.listbox.bind("<Double-1>", lambda _e: self._select())

        self.var_status = tk.StringVar(value="Loading organizations…")
        ttk.Label(frame, textvariable=self.var_status, foreground="gray").pack(anchor="w", pady=(6, 0))

        buttons = ttk.Frame(frame)
        buttons.pack(fill="x", pady=(8, 0))
        ttk.Button(buttons, text="Cancel", command=self.destroy).pack(side="right", padx=(6, 0))
        self.btn_select = ttk.Button(buttons, text="Use this network", command=self._select)
        self.btn_select.pack(side="right")

        self.bind("<Escape>", lambda _e: self.destroy())
        self._orgs = []
        self._networks = []
        self._shown = []
        self._load_orgs()

    def _async(self, work, done):
        def runner():
            try:
                result, error = work(), None
            except MerakiError as exc:
                result, error = None, str(exc)
            except Exception as exc:
                result, error = None, f"Unexpected error: {exc}"
            if self.winfo_exists():
                self.after(0, lambda: done(result, error))
        threading.Thread(target=runner, daemon=True).start()

    def _load_orgs(self):
        def done(orgs, error):
            if error:
                self.var_status.set(error)
                return
            self._orgs = orgs
            names = [o.get("name", o.get("id", "?")) for o in orgs]
            self.combo_org["values"] = names
            if not orgs:
                self.var_status.set("No organizations visible to this API key.")
                return
            saved = self.settings.get("meraki_org_id")
            index = next((i for i, o in enumerate(orgs) if str(o.get("id")) == str(saved)), 0)
            self.combo_org.current(index)
            self._load_networks()
        self._async(self.meraki.get_organizations, done)

    def _current_org(self):
        index = self.combo_org.current()
        return self._orgs[index] if 0 <= index < len(self._orgs) else None

    def _load_networks(self):
        org = self._current_org()
        if not org:
            return
        self.var_status.set(f"Loading networks in {org.get('name', '?')}…")
        self.listbox.delete(0, "end")
        self._async(lambda: self.meraki.get_networks(org["id"]), self._networks_done)

    def _networks_done(self, networks, error):
        if error:
            self.var_status.set(error)
            return
        self._networks = sorted(networks, key=lambda n: (n.get("name") or "").lower())
        self._render_networks()

    def _render_networks(self):
        query = self.var_filter.get().strip().lower()
        self._shown = [n for n in self._networks
                       if query in (n.get("name") or "").lower()] if query else list(self._networks)
        self.listbox.delete(0, "end")
        saved = str(self.settings.get("meraki_network_id"))
        select_index = None
        for i, network in enumerate(self._shown):
            self.listbox.insert("end", network.get("name") or network.get("id"))
            if str(network.get("id")) == saved:
                select_index = i
        if select_index is not None:
            self.listbox.selection_set(select_index)
            self.listbox.see(select_index)
        self.var_status.set(f"{len(self._shown)} network(s).")

    def _select(self):
        org = self._current_org()
        picks = self.listbox.curselection()
        if not org or not picks:
            self.var_status.set("Select a network first.")
            return
        network = self._shown[picks[0]]
        self.settings.set("meraki_org_id", str(org.get("id")))
        self.settings.set("meraki_org_name", org.get("name", ""))
        self.settings.set("meraki_network_id", str(network.get("id")))
        self.settings.set("meraki_network_name", network.get("name", ""))
        self.settings.save()
        self.destroy()
        self.on_selected(network)


class MerakiInfoDialog(tk.Toplevel):
    """Shows the Meraki client lookup result with copyable fields."""

    FIELDS = [
        ("Description",   lambda c: c.get("description") or ""),
        ("IP address",    lambda c: c.get("ip") or ""),
        ("Recent SSID",   lambda c: c.get("ssid") or ""),
        ("Connected AP",  lambda c: c.get("recentDeviceName") or ""),
        ("Last seen",     lambda c: friendly_timestamp(c.get("lastSeen"))),
        ("Status",        lambda c: c.get("status") or ""),
    ]

    def __init__(self, parent, device_name, mac, network_name, client,
                 on_change_network=None, change_label="Change network…", note=""):
        super().__init__(parent)
        self.title(f"Meraki info — {device_name}")
        self.client_record = client
        self.resizable(False, False)

        frame = ttk.Frame(self, padding=14)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text=f"{device_name}   ({normalize_mac(mac)})",
                  font=("", 13, "bold")).grid(row=0, column=0, columnspan=2, sticky="w")
        ttk.Label(frame, text=f"Network: {network_name}", foreground="gray").grid(
            row=1, column=0, columnspan=2, sticky="w", pady=(0, 10))

        row = 2
        connection = client.get("recentDeviceConnection") or ""
        self._vars = []   # keep references: unreferenced StringVars are
                          # garbage-collected and their entries go blank
        for label, getter in self.FIELDS:
            value = getter(client)
            if label == "Connected AP":
                if connection and connection.lower() != "wireless":
                    label = f"Connected via ({connection})"
                if not value:
                    value = client.get("recentDeviceMac") or ""
            ttk.Label(frame, text=label).grid(row=row, column=0, sticky="w", pady=2)
            name_label = frame.grid_slaves(row=row, column=0)[0]
            var = tk.StringVar(value=value)
            self._vars.append(var)
            entry = ttk.Entry(frame, textvariable=var, width=38, state="readonly")
            entry.grid(row=row, column=1, sticky="we", pady=2)
            for widget in (name_label, entry):
                for sequence in ("<Button-2>", "<Button-3>", "<Control-Button-1>"):
                    widget.bind(sequence,
                                lambda e, v=value, l=label: self._show_copy_menu(e, l, v))
            row += 1

        self.var_status = tk.StringVar(
            value=note or "Right-click a field to copy it.")
        ttk.Label(frame, textvariable=self.var_status, foreground="gray").grid(
            row=row, column=0, columnspan=2, sticky="w", pady=(8, 0))
        row += 1

        buttons = ttk.Frame(frame)
        buttons.grid(row=row, column=0, columnspan=2, sticky="we", pady=(10, 0))
        ttk.Button(buttons, text="Close", command=self.destroy).pack(side="right")
        ttk.Button(buttons, text="Full response…",
                   command=self._show_full).pack(side="right", padx=(0, 6))
        if on_change_network:
            ttk.Button(buttons, text=change_label,
                       command=on_change_network).pack(side="left")

        self.bind("<Escape>", lambda _e: self.destroy())

    def _copy(self, value, label):
        self.clipboard_clear()
        self.clipboard_append(value)
        self.var_status.set(f"Copied {label}: {value}" if value else f"Copied {label} (empty).")

    def _show_copy_menu(self, event, label, value):
        """Same menu shape as the device info tree, for a consistent feel."""
        menu = tk.Menu(self, tearoff=0)
        shown = value if len(value) <= 40 else value[:37] + "…"
        menu.add_command(label=f"Copy value ({shown})" if shown else "Copy value",
                         command=lambda: self._copy(value, label))
        if not value:
            menu.entryconfigure(0, state="disabled")
        menu.add_command(label="Copy field name",
                         command=lambda: self._copy(label, "field name"))
        menu.add_command(label="Copy “field: value”",
                         command=lambda: self._copy(f"{label}: {value}", label))
        menu.tk_popup(event.x_root, event.y_root)
        return "break"

    def _show_full(self):
        DeviceInfoDialog(self, f"Meraki client record — {self.title()}", self.client_record)


# ---------------------------------------------------------------------------
# Add-device dialog (search lives here now)
# ---------------------------------------------------------------------------

class AddDeviceDialog(tk.Toplevel):
    """Search Jamf Pro and add one or more results to the working list.

    Stays open after adding so several devices can be added in a row.
    """

    def __init__(self, parent, client, device_type, existing_ids, on_add):
        super().__init__(parent)
        self.client = client
        self.device_type = device_type
        self.existing_ids = existing_ids   # live set owned by the caller
        self.on_add = on_add
        noun = "computers" if device_type == "computer" else "mobile devices"
        self.title(f"Add {noun}")
        self.transient(parent)
        self.geometry("640x420")
        self.minsize(520, 320)

        top = ttk.Frame(self, padding=(12, 12, 12, 6))
        top.pack(fill="x")
        ttk.Label(top, text=f"Search {noun} by name, serial, username, or asset tag:").pack(anchor="w")
        row = ttk.Frame(top)
        row.pack(fill="x", pady=(6, 0))
        self.var_query = tk.StringVar()
        self.entry = ttk.Entry(row, textvariable=self.var_query)
        self.entry.pack(side="left", fill="x", expand=True)
        self.entry.bind("<Return>", lambda _e: self.search())
        self.btn_search = ttk.Button(row, text="Search", command=self.search)
        self.btn_search.pack(side="left", padx=(8, 0))

        mid = ttk.Frame(self, padding=(12, 6, 12, 6))
        mid.pack(fill="both", expand=True)
        columns = ("name", "serial", "username", "model")
        self.tree = ttk.Treeview(mid, columns=columns, show="headings", selectmode="extended")
        headings = {"name": "Name", "serial": "Serial", "username": "Username", "model": "Model"}
        widths = {"name": 180, "serial": 120, "username": 110, "model": 170}
        for col in columns:
            self.tree.heading(col, text=headings[col])
            self.tree.column(col, width=widths[col], anchor="w")
        scroll = ttk.Scrollbar(mid, command=self.tree.yview)
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.pack(side="left", fill="both", expand=True)
        scroll.pack(side="left", fill="y")
        self.tree.bind("<Double-1>", lambda _e: self.add_selected())
        self.tree.bind("<Return>", lambda _e: self.add_selected())
        self._results = {}

        bottom = ttk.Frame(self, padding=(12, 0, 12, 12))
        bottom.pack(fill="x")
        self.var_status = tk.StringVar(value="Type a search and press Return. Cmd-click to select several.")
        ttk.Label(bottom, textvariable=self.var_status, foreground="gray").pack(side="left")
        ttk.Button(bottom, text="Done", command=self.destroy).pack(side="right", padx=(6, 0))
        self.btn_add = ttk.Button(bottom, text="Add selected", command=self.add_selected)
        self.btn_add.pack(side="right")

        self.bind("<Escape>", lambda _e: self.destroy())
        self.entry.focus_set()

    def search(self):
        query = self.var_query.get().strip()
        self.var_status.set("Searching…")
        self.btn_search.state(["disabled"])

        def worker():
            try:
                if self.device_type == "computer":
                    results = self.client.search_computers(query)
                else:
                    results = self.client.search_mobile_devices(query)
                error = None
            except JamfError as exc:
                results, error = [], str(exc)
            except Exception as exc:
                results, error = [], f"Unexpected error: {exc}"

            def show():
                if not self.winfo_exists():
                    return
                self.btn_search.state(["!disabled"])
                if error:
                    self.var_status.set("Search failed.")
                    messagebox.showerror(APP_NAME, error, parent=self)
                    return
                self.tree.delete(*self.tree.get_children())
                self._results.clear()
                for record in results:
                    device_id = str(record.get("id"))
                    entry = {
                        "id": device_id,
                        "name": record.get("name", ""),
                        "serial": record.get("serial_number", ""),
                        "username": record.get("username", ""),
                        "wifi_mac": record.get("wifi_mac_address", "") or "",
                        "ip": "",
                        "model": record.get("model", ""),
                    }
                    self._results[device_id] = entry
                    tags = ("added",) if device_id in self.existing_ids else ()
                    self.tree.insert("", "end", iid=device_id, tags=tags,
                                     values=(entry["name"], entry["serial"],
                                             entry["username"], entry["model"]))
                self.tree.tag_configure("added", foreground="gray")
                already = sum(1 for i in self._results if i in self.existing_ids)
                note = f" ({already} already in your list, shown in gray)" if already else ""
                self.var_status.set(f"{len(results)} result(s){note}.")

            self.after(0, show)

        threading.Thread(target=worker, daemon=True).start()

    def add_selected(self):
        selection = self.tree.selection()
        if not selection:
            self.var_status.set("Select one or more results to add.")
            return
        added, skipped = [], 0
        for device_id in selection:
            if device_id in self.existing_ids:
                skipped += 1
                continue
            added.append(self._results[device_id])
        if added:
            self.on_add(added)   # caller updates existing_ids
            for entry in added:
                self.tree.item(entry["id"], tags=("added",))
        parts = []
        if added:
            parts.append(f"Added {len(added)} device(s)")
        if skipped:
            parts.append(f"{skipped} already in your list")
        self.var_status.set((". ".join(parts) + ".") if parts else "Nothing to add.")


# ---------------------------------------------------------------------------
# Main application window
# ---------------------------------------------------------------------------

class ColumnsDialog(tk.Toplevel):
    """Choose which columns the device list shows, and in what order."""

    def __init__(self, app):
        super().__init__(app)
        self.app = app
        self.title("Arrange Columns")
        self.transient(app)
        self.resizable(False, False)

        frame = ttk.Frame(self, padding=12)
        frame.pack(fill="both", expand=True)

        ttk.Label(frame, text="Available").grid(row=0, column=0, sticky="w")
        ttk.Label(frame, text="Shown (top = left)").grid(row=0, column=2, sticky="w")

        self.lst_available = tk.Listbox(frame, height=14, width=20,
                                        exportselection=False)
        self.lst_available.grid(row=1, column=0, sticky="nsew", pady=(4, 0))
        self.lst_shown = tk.Listbox(frame, height=14, width=20,
                                    exportselection=False)
        self.lst_shown.grid(row=1, column=2, sticky="nsew", pady=(4, 0))

        mid = ttk.Frame(frame, padding=(8, 0))
        mid.grid(row=1, column=1, sticky="ns")
        ttk.Button(mid, text="Add →", command=self._add).pack(pady=(30, 4), fill="x")
        ttk.Button(mid, text="← Remove", command=self._remove).pack(pady=4, fill="x")
        ttk.Separator(mid).pack(fill="x", pady=8)
        ttk.Button(mid, text="Move Up", command=lambda: self._move(-1)).pack(pady=4, fill="x")
        ttk.Button(mid, text="Move Down", command=lambda: self._move(1)).pack(pady=4, fill="x")

        self.lst_available.bind("<Double-1>", lambda _e: self._add())
        self.lst_shown.bind("<Double-1>", lambda _e: self._remove())

        buttons = ttk.Frame(frame)
        buttons.grid(row=2, column=0, columnspan=3, sticky="we", pady=(12, 0))
        ttk.Button(buttons, text="Reset to Defaults",
                   command=self._reset).pack(side="left")
        ttk.Button(buttons, text="Cancel", command=self.destroy).pack(side="right")
        ttk.Button(buttons, text="OK", command=self._ok).pack(side="right", padx=(0, 6))

        self._load(self.app._visible_columns())

        self.update_idletasks()
        px, py = app.winfo_rootx(), app.winfo_rooty()
        self.geometry(f"+{px + 120}+{py + 90}")
        self.grab_set()
        self.lst_shown.focus_set()

    # -- helpers -------------------------------------------------------------
    def _load(self, shown_fields):
        self.lst_available.delete(0, "end")
        self.lst_shown.delete(0, "end")
        for field in shown_fields:
            self.lst_shown.insert("end", COLUMN_HEADINGS[field])
        for field in CATALOG_FIELDS:
            if field not in shown_fields:
                self.lst_available.insert("end", COLUMN_HEADINGS[field])

    def _shown_fields(self):
        heading_to_field = {h: f for f, h in COLUMN_HEADINGS.items()}
        return [heading_to_field[self.lst_shown.get(i)]
                for i in range(self.lst_shown.size())]

    def _add(self):
        sel = self.lst_available.curselection()
        if not sel:
            return
        heading = self.lst_available.get(sel[0])
        self.lst_available.delete(sel[0])
        self.lst_shown.insert("end", heading)
        self.lst_shown.selection_clear(0, "end")
        self.lst_shown.selection_set("end")

    def _remove(self):
        sel = self.lst_shown.curselection()
        if not sel:
            return
        if self.lst_shown.size() == 1:
            return                       # keep at least one column
        heading = self.lst_shown.get(sel[0])
        self.lst_shown.delete(sel[0])
        # reinsert into Available at catalog position to keep it tidy
        remaining = [self.lst_available.get(i) for i in range(self.lst_available.size())]
        catalog_order = [COLUMN_HEADINGS[f] for f in CATALOG_FIELDS]
        remaining.append(heading)
        remaining.sort(key=catalog_order.index)
        self.lst_available.delete(0, "end")
        for h in remaining:
            self.lst_available.insert("end", h)

    def _move(self, direction):
        sel = self.lst_shown.curselection()
        if not sel:
            return
        index = sel[0]
        target = index + direction
        if target < 0 or target >= self.lst_shown.size():
            return
        heading = self.lst_shown.get(index)
        self.lst_shown.delete(index)
        self.lst_shown.insert(target, heading)
        self.lst_shown.selection_clear(0, "end")
        self.lst_shown.selection_set(target)
        self.lst_shown.see(target)

    def _reset(self):
        self._load(list(DEFAULT_COLUMNS))

    def _ok(self):
        self.app.set_columns(self._shown_fields())
        self.destroy()


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(f"{APP_NAME} - {APP_VERSION}")
        self.minsize(1020, 460)
        self._restore_geometry()

        self.settings = Settings()
        self.client = None
        self._rebuild_client()

        self._build_toolbar()
        self._build_menu()
        self._build_body()
        self._build_statusbar()
        self._populate_tree()

        self.log(f"Welcome to {APP_NAME} - {APP_VERSION}. "
                 + ("Click “Add…” to search for devices and build your list."
                    if self.settings.get("jamf_url")
                    else "Open Settings (Cmd+,) to connect to Jamf Pro."))

        self.protocol("WM_DELETE_WINDOW", self._on_close)

        if not self.settings.get("jamf_url"):
            self.after(300, lambda: self.winfo_exists() and self.open_settings())

    # -- window geometry -----------------------------------------------------
    def _restore_geometry(self):
        """Reopen at the saved size/position, or centered on first launch."""
        default_w, default_h = 1100, 560
        # Settings isn't loaded yet in __init__ order, so read the file directly.
        saved = ""
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
                saved = (json.load(fh) or {}).get("window_geometry", "")
        except Exception:
            saved = ""
        if saved and self._geometry_on_screen(saved):
            self.geometry(saved)
            return
        # center a default-sized window on the display it will open on
        self.update_idletasks()
        screen_w = self.winfo_screenwidth()
        screen_h = self.winfo_screenheight()
        x = max(0, (screen_w - default_w) // 2)
        y = max(0, (screen_h - default_h) // 3)
        self.geometry(f"{default_w}x{default_h}+{x}+{y}")

    def _geometry_on_screen(self, geometry):
        """Guard against restoring onto a monitor that's no longer attached."""
        match = re.match(r"(\d+)x(\d+)\+(-?\d+)\+(-?\d+)", geometry)
        if not match:
            return False
        w, h, x, y = (int(g) for g in match.groups())
        screen_w = self.winfo_screenwidth()
        screen_h = self.winfo_screenheight()
        # at least a chunk of the title bar must be visible to be grabbable
        if x > screen_w - 100 or y > screen_h - 60:
            return False
        if x + w < 100 or y + h < 60:
            return False
        return True

    def _on_close(self):
        try:
            self.settings.set("window_geometry", self.geometry())
            self.settings.save()
        except Exception:
            pass
        self.destroy()

    # -- construction --------------------------------------------------------
    def _build_menu(self):
        menubar = tk.Menu(self, tearoff=0)

        # Application menu. macOS always shows this first and titles it with
        # the running bundle's name (see the .app bundling note in the README);
        # the label here is only used on other platforms. macOS itself adds the
        # standard Services / Hide / Quit items to it.
        app_menu = tk.Menu(menubar, tearoff=0, name="apple")
        app_menu.add_command(label=f"About {APP_NAME}", command=self._about)
        menubar.add_cascade(label=APP_NAME, menu=app_menu)

        file_menu = tk.Menu(menubar, tearoff=0)
        file_menu.add_command(label="Add Devices…", accelerator="Cmd+N",
                              command=self.open_add_dialog)
        file_menu.add_command(label="Refresh Info", accelerator="Cmd+R",
                              command=self.refresh_list)
        file_menu.add_separator()
        file_menu.add_command(label="Remove from List", accelerator="Delete",
                              command=self.remove_selected)
        file_menu.add_separator()
        file_menu.add_command(label="Close Window", accelerator="Cmd+W",
                              command=self._close_window)
        menubar.add_cascade(label="File", menu=file_menu)

        edit_menu = tk.Menu(menubar, tearoff=0)
        edit_menu.add_command(label="Copy", accelerator="Cmd+C", command=self.copy_rows)
        edit_menu.add_command(label="Select All", accelerator="Cmd+A",
                              command=self._select_all)
        menubar.add_cascade(label="Edit", menu=edit_menu)

        # Every action button also lives here, so the whole app is reachable
        # from the keyboard and discoverable without hunting the sidebar.
        # Contents are filled in by _sync_device_menu based on device type.
        device_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label="Device", menu=device_menu)
        self._device_menu = device_menu
        self._sync_device_menu()

        # macOS fills these two in with its standard items.
        window_menu = tk.Menu(menubar, tearoff=0, name="window")
        menubar.add_cascade(label="Window", menu=window_menu)

        help_menu = tk.Menu(menubar, tearoff=0, name="help")
        help_menu.add_command(label=f"{APP_NAME} Help", command=self.open_help)
        menubar.add_cascade(label="Help", menu=help_menu)

        self.config(menu=menubar)

        # Hook the native macOS menu items rather than duplicating them:
        # this is what puts Settings in the application menu where it belongs.
        for name, handler in (("tk::mac::ShowPreferences", self.open_settings),
                              ("tk::mac::ShowHelp", self.open_help),
                              ("tk::mac::Quit", self._quit)):
            try:
                self.createcommand(name, handler)
            except tk.TclError:
                pass  # not running on macOS

        self.bind_all("<Command-comma>", lambda _e: self.open_settings())
        self.bind_all("<Command-f>", lambda _e: self.open_add_dialog())
        self.bind_all("<Command-n>", lambda _e: self.open_add_dialog())
        self.bind_all("<Command-r>", lambda _e: self.refresh_list())
        self.bind_all("<Command-a>", lambda _e: self._select_all())
        self.bind_all("<Command-w>", lambda _e: self._close_window())

    def _select_all(self):
        self.tree.selection_set(self.tree.get_children())

    def _close_window(self):
        """Cmd+W closes the front dialog; the main window stays put."""
        focused = self.focus_get()
        if focused is None:
            return
        top = focused.winfo_toplevel()
        if top is not self:
            top.destroy()

    def _quit(self):
        self._on_close()

    def _sync_device_menu(self):
        """Rebuild the Device menu from the unified action list. Mobile-only
        entries are shown disabled (not removed) for computers, so the menu
        layout is identical for both types."""
        menu = self._device_menu
        menu.delete(0, "end")
        needs_ellipsis = {"Toggle Lost Mode", "Lock Device", "Rename Device"}
        # the menu is built before the tree exists on first launch
        count = len(self.tree.selection()) if hasattr(self, "tree") else 0
        for label, method, mobile_only, bulk in self.ACTIONS:
            menu_label = f"{label}…" if label in needs_ellipsis else label
            handler = getattr(self, method)
            enabled = self._action_available(mobile_only)
            if count > 1:
                # multi-select: only the bulk-capable actions stay live
                if bulk:
                    handler = getattr(self, bulk)
                    menu_label = f"{menu_label.rstrip('…')} ({count})" + \
                                 ("…" if label in needs_ellipsis else "")
                else:
                    enabled = False
            menu.add_command(label=menu_label,
                             state="normal" if enabled else "disabled",
                             command=handler)
            if label in ("Network Info", "Update Inventory"):
                menu.add_separator()

    def _build_toolbar(self):
        bar = ttk.Frame(self, padding=(12, 10, 12, 6))
        bar.pack(fill="x")

        self.var_type = tk.StringVar(value="computer")
        ttk.Radiobutton(bar, text="Computers", value="computer",
                        variable=self.var_type).pack(side="left")
        ttk.Radiobutton(bar, text="Mobile devices", value="mobile",
                        variable=self.var_type).pack(side="left", padx=(8, 16))

        ttk.Button(bar, text="Add…", command=self.open_add_dialog).pack(side="left")
        ttk.Button(bar, text="Remove", command=self.remove_selected).pack(side="left", padx=(6, 0))
        ttk.Button(bar, text="Refresh info", command=self.refresh_list).pack(side="left", padx=(6, 0))
        ttk.Separator(bar, orient="vertical").pack(side="left", fill="y", padx=8)
        ttk.Button(bar, text="↑", width=3,
                   command=lambda: self.move_selected(-1)).pack(side="left")
        ttk.Button(bar, text="↓", width=3,
                   command=lambda: self.move_selected(1)).pack(side="left", padx=(4, 0))
        ttk.Button(bar, text="Export…", command=self.export_list).pack(side="left", padx=(8, 0))

        ttk.Button(bar, text="Help", command=self.open_help).pack(side="right")
        ttk.Button(bar, text="Settings", command=self.open_settings).pack(side="right", padx=(0, 6))

    def _build_body(self):
        # The device list and the activity log share a vertical PanedWindow so
        # the divider between them can be dragged to resize the log. The aqua
        # ttk theme draws the sash as a near-invisible hairline (and it varies
        # by macOS/Tk version), so we add an explicit grip strip that's obvious
        # to grab. Its colors come from the active theme so it matches the app
        # background in both light and dark mode.
        style = ttk.Style(self)
        self._paned = ttk.PanedWindow(self, orient="vertical")
        self._paned.pack(fill="both", expand=True, padx=(12, 0), pady=0)

        # working device list (persists between launches)
        list_frame = ttk.Frame(self._paned)
        self._paned.add(list_frame, weight=1)

        self.tree = ttk.Treeview(list_frame, show="headings",
                                 selectmode="extended")
        self._sort_state = {}   # column -> ascending bool
        vscroll = ttk.Scrollbar(list_frame, command=self.tree.yview)
        hscroll = ttk.Scrollbar(list_frame, orient="horizontal",
                                command=self.tree.xview)
        self.tree.configure(yscrollcommand=vscroll.set, xscrollcommand=hscroll.set)
        self.tree.grid(row=0, column=0, sticky="nsew")
        vscroll.grid(row=0, column=1, sticky="ns")
        hscroll.grid(row=1, column=0, sticky="ew")
        list_frame.rowconfigure(0, weight=1)
        list_frame.columnconfigure(0, weight=1)
        self._configure_tree_columns()
        self.tree.bind("<Double-1>", self._on_double_click)
        self.tree.bind("<BackSpace>", lambda _e: self.remove_selected())
        self.tree.bind("<Delete>", lambda _e: self.remove_selected())
        self.tree.bind("<Command-Up>", lambda _e: self.move_selected(-1) or "break")
        self.tree.bind("<Command-Down>", lambda _e: self.move_selected(1) or "break")
        # right-click (or two-finger/ctrl-click) for copying and actions; Cmd+C copies
        self.tree.bind("<Button-2>", self._show_copy_menu)
        self.tree.bind("<Button-3>", self._show_copy_menu)
        self.tree.bind("<Control-Button-1>", self._show_copy_menu)
        self.tree.bind("<Command-c>", lambda _e: self.copy_rows())
        # the Device menu labels show the selection count, so refresh on change
        self.tree.bind("<<TreeviewSelect>>",
                       lambda _e: self._sync_device_menu() if hasattr(self, "_device_menu") else None)

        self.var_type.trace_add("write", lambda *_: self._on_type_changed())

        # Bottom pane: a visible grip strip on top of the activity log. The
        # grip is the reliable, always-visible drag target; it forwards drag
        # events to the paned window's sash so behaviour matches dragging the
        # sash directly.
        bottom = ttk.Frame(self._paned)
        self._paned.add(bottom, weight=0)

        grip_bg = self._theme_background(style)
        dot_color = self._contrast_shade(grip_bg)
        grip = tk.Frame(bottom, height=12, cursor="sb_v_double_arrow",
                        background=grip_bg, highlightthickness=0)
        grip.pack(fill="x", side="top")
        grip.pack_propagate(False)
        dots = tk.Frame(grip, background=grip_bg)
        dots.place(relx=0.5, rely=0.5, anchor="center")
        for i in range(3):
            tk.Frame(dots, width=3, height=3, background=dot_color).grid(
                row=0, column=i, padx=2)
        for widget in (grip, dots):
            widget.bind("<Button-1>", self._grip_press)
            widget.bind("<B1-Motion>", self._grip_drag)

        log_frame = ttk.LabelFrame(bottom, text="Activity", padding=6)
        log_frame.pack(fill="both", expand=True)
        self.log_text = tk.Text(log_frame, height=6, wrap="word", state="disabled",
                                borderwidth=0, highlightthickness=0, font=("Menlo", 11))
        log_scroll = ttk.Scrollbar(log_frame, command=self.log_text.yview)
        self.log_text.configure(yscrollcommand=log_scroll.set)
        self.log_text.pack(side="left", fill="both", expand=True)
        log_scroll.pack(side="right", fill="y")
        for sequence in ("<Button-2>", "<Button-3>", "<Control-Button-1>"):
            self.log_text.bind(sequence, self._show_log_menu)

    def _theme_background(self, style):
        """The active ttk theme's frame background, so widgets we draw by hand
        match the app (and follow light/dark mode). Falls back to the root
        window's background if the theme doesn't report one."""
        for option in (("TFrame", "background"), ("TLabel", "background")):
            try:
                color = style.lookup(*option)
                if color:
                    return color
            except tk.TclError:
                pass
        try:
            return self.cget("background")
        except tk.TclError:
            return "#ececec"

    def _contrast_shade(self, background):
        """A muted color that reads against `background` — lighten a dark
        theme, darken a light one — so the grip dots stay visible either way."""
        try:
            r, g, b = self.winfo_rgb(background)          # 16-bit per channel
            r, g, b = r // 256, g // 256, b // 256
        except tk.TclError:
            return "#808080"
        luminance = 0.299 * r + 0.587 * g + 0.114 * b
        if luminance < 128:                                # dark bg -> lighter dots
            shade = lambda c: min(255, c + 90)
        else:                                              # light bg -> darker dots
            shade = lambda c: max(0, c - 90)
        return f"#{shade(r):02x}{shade(g):02x}{shade(b):02x}"

    def _grip_press(self, event):
        # remember where the drag started, in screen coordinates
        self._grip_start_y = event.y_root

    def _grip_drag(self, event):
        """Translate a drag on the grip strip into a sash move on the paned
        window, so the visible handle resizes the log even when the native
        aqua sash is invisible."""
        if not self._paned.panes():
            return
        delta = event.y_root - getattr(self, "_grip_start_y", event.y_root)
        self._grip_start_y = event.y_root
        try:
            current = self._paned.sashpos(0)
        except tk.TclError:
            return
        new = current + delta
        # keep both panes usable
        height = self._paned.winfo_height()
        new = max(80, min(new, height - 60))
        try:
            self._paned.sashpos(0, new)
        except tk.TclError:
            pass

    # Action definitions per device type. Update Inventory and Toggle Lost Mode
    # are mobile-only: the classic computercommands endpoint has no equivalent
    # MDM command for Macs (a Mac's inventory updates via `jamf recon` locally).
    # These drive the Device menu, the list's right-click menu, and the
    # double-click setting. A single ordered list keeps every action at the
    # same position for both device types — the mobile-only entries are shown
    # disabled (not removed) for computers, so muscle-memory targeting stays
    # consistent. Each entry: (label, method, mobile_only, bulk_method).
    # bulk_method is None for actions that only make sense one at a time.
    ACTIONS = [
        ("Show Info", "action_show_info", False, None),
        ("Network Info", "action_meraki_info", False, None),
        ("Toggle Lost Mode", "action_toggle_lost_mode", True, "bulk_toggle_lost_mode"),
        ("Lock Device", "action_lock", False, "bulk_lock"),
        ("Rename Device", "action_rename", False, "bulk_rename"),
        ("Update Inventory", "action_update_inventory", True, None),
        ("Open in Jamf Pro", "action_open_in_jamf", False, "bulk_open_in_jamf"),
    ]
    ALL_ACTIONS = [(label, method) for label, method, _mo, _bulk in ACTIONS]

    def _action_available(self, mobile_only):
        """An action is available unless it's mobile-only and we're on computers."""
        return (not mobile_only) or self.var_type.get() == "mobile"

    def _on_double_click(self, _event):
        method = self.settings.get("double_click_action", "action_open_in_jamf")
        handler = getattr(self, method, None)
        if handler is None:                       # stale/unknown value in settings
            handler = self.action_open_in_jamf
        handler()

    def _on_type_changed(self):
        self._sort_state = {}
        if hasattr(self, "_device_menu"):
            self._sync_device_menu()
        self._populate_tree()

    # -- activity log ----------------------------------------------------------
    def _show_log_menu(self, event):
        menu = tk.Menu(self, tearoff=0)
        has_content = bool(self.log_text.get("1.0", "end").strip())
        menu.add_command(label="Copy log", command=self.copy_log)
        menu.add_command(label="Clear log", command=self.clear_log)
        if not has_content:
            menu.entryconfigure("Copy log", state="disabled")
            menu.entryconfigure("Clear log", state="disabled")
        menu.tk_popup(event.x_root, event.y_root)
        return "break"

    def copy_log(self):
        text = self.log_text.get("1.0", "end").strip()
        if not text:
            return
        self.clipboard_clear()
        self.clipboard_append(text)
        self.status.set(f"Copied log ({len(text.splitlines())} lines).")

    def clear_log(self):
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.configure(state="disabled")
        self.status.set("Activity log cleared.")

    def _build_statusbar(self):
        self.status = tk.StringVar(value="Ready")
        ttk.Label(self, textvariable=self.status, padding=(12, 2)).pack(fill="x", side="bottom")

    # -- helpers -------------------------------------------------------------
    def _rebuild_client(self):
        url = self.settings.get("jamf_url")
        if not url:
            self.client = None
            return
        method = self.settings.get("auth_method", "oauth")
        if method == "oauth":
            a = self.settings.get_secret("client_id")
            b = self.settings.get_secret("client_secret")
        else:
            a = self.settings.get_secret("username")
            b = self.settings.get_secret("password")
        self.client = JamfClient(
            url, method, a, b,
            ssl_verify=bool(self.settings.get("ssl_verify", True)),
            ssl_ca_bundle=self.settings.get("ssl_ca_bundle", ""),
        )

    def log(self, message):
        stamp = datetime.datetime.now().strftime("%H:%M:%S")
        self.log_text.configure(state="normal")
        self.log_text.insert("end", f"[{stamp}] {message}\n")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _busy(self, message):
        self.status.set(message)
        self.configure(cursor="watch")

    def _idle(self):
        self.status.set("Ready")
        self.configure(cursor="")

    def _run_async(self, work, on_done):
        """Run `work()` in a thread; call `on_done(result, error)` on the UI thread."""
        def runner():
            result, error = None, None
            try:
                result = work()
            except JamfError as exc:
                error = str(exc)
            except MerakiError as exc:
                error = str(exc)
            except Exception as exc:  # unexpected — still surface it
                error = f"Unexpected error: {exc}"
            self.after(0, lambda: on_done(result, error))
        threading.Thread(target=runner, daemon=True).start()

    def _require_client(self):
        if self.client is None:
            messagebox.showinfo(APP_NAME, "Add your Jamf Pro URL and credentials in Settings first.")
            self.open_settings()
            return False
        return True

    def _selected_device(self):
        selection = self.tree.selection()
        if not selection:
            messagebox.showinfo(APP_NAME, "Select a device in the list first.")
            return None
        if len(selection) > 1:
            messagebox.showinfo(APP_NAME, "Select a single device for actions. "
                                          "(Multiple selection is for Remove.)")
            return None
        item = self.tree.item(selection[0])
        device_id = selection[0]
        values = item["values"]
        return {"id": device_id, "name": values[0], "type": self.var_type.get()}

    # -- working device lists ------------------------------------------------
    def _list_key(self, device_type=None):
        device_type = device_type or self.var_type.get()
        return "device_list_computer" if device_type == "computer" else "device_list_mobile"

    def _current_list(self):
        return self.settings.get(self._list_key(), [])

    # -- columns ---------------------------------------------------------------
    def _visible_columns(self):
        """The user's chosen columns, validated against the catalog."""
        chosen = self.settings.get("list_columns") or []
        valid = [f for f in chosen if f in CATALOG_FIELDS]
        return valid or list(DEFAULT_COLUMNS)

    def _configure_tree_columns(self):
        """(Re)build the tree's columns from settings. Called at startup and
        whenever the user changes the column set or order."""
        columns = self._visible_columns()
        self.tree.configure(columns=columns)
        for col in columns:
            self.tree.heading(col, text=COLUMN_HEADINGS[col],
                              command=lambda c=col: self.sort_by_column(c))
            self.tree.column(col, width=COLUMN_WIDTHS[col], anchor="w",
                             stretch=False, minwidth=40)
        self._sort_state = {}

    def set_columns(self, columns):
        """Persist a new column selection/order and redraw the list."""
        valid = [f for f in columns if f in CATALOG_FIELDS]
        if not valid:
            valid = list(DEFAULT_COLUMNS)
        self.settings.set("list_columns", valid)
        self.settings.save()
        self._configure_tree_columns()
        self._populate_tree()

    def reset_columns(self):
        self.set_columns(list(DEFAULT_COLUMNS))
        self.log("Columns reset to defaults.")

    def _toggle_column(self, field):
        columns = self._visible_columns()
        if field in columns:
            if len(columns) == 1:
                self.status.set("At least one column must stay visible.")
                return
            columns.remove(field)
        else:
            columns.append(field)
        self.set_columns(columns)

    def _show_column_menu(self, event):
        """Right-click on the column headers: toggle fields on/off, open the
        arrange dialog, or reset to defaults."""
        visible = set(self._visible_columns())
        menu = tk.Menu(self, tearoff=0)
        self._column_menu_vars = []          # keep BooleanVars alive
        for field in CATALOG_FIELDS:
            var = tk.BooleanVar(value=field in visible)
            self._column_menu_vars.append(var)
            menu.add_checkbutton(label=COLUMN_HEADINGS[field], variable=var,
                                 command=lambda f=field: self._toggle_column(f))
        menu.add_separator()
        menu.add_command(label="Arrange Columns…", command=self.open_columns_dialog)
        menu.add_command(label="Reset to Default Columns", command=self.reset_columns)
        menu.tk_popup(event.x_root, event.y_root)
        return "break"

    def open_columns_dialog(self):
        ColumnsDialog(self)

    def _entry_values(self, entry):
        return tuple(entry.get(field, "") for field in self._visible_columns())

    def _populate_tree(self):
        # clear any sort-arrow indicator when the list is (re)drawn for a switch
        if hasattr(self, "_sort_state") and not self._sort_state:
            for col in self._visible_columns():
                self.tree.heading(col, text=COLUMN_HEADINGS[col])
        self.tree.delete(*self.tree.get_children())
        for entry in self._current_list():
            self.tree.insert("", "end", iid=str(entry["id"]),
                             values=self._entry_values(entry))

    def _update_list_entry(self, device_type, device_id, fields):
        """Update a stored entry (e.g. after a rename) and refresh its row.
        `fields` is a dict — passed positionally, not as **kwargs, so catalog
        field names (like "device_id") can never collide with parameters."""
        key = self._list_key(device_type)
        for entry in self.settings.get(key, []):
            if str(entry["id"]) == str(device_id):
                entry.update(fields)
                self.settings.save()
                if device_type == self.var_type.get() and self.tree.exists(str(device_id)):
                    self.tree.item(str(device_id), values=self._entry_values(entry))
                return

    def open_add_dialog(self):
        if not self._require_client():
            return
        device_type = self.var_type.get()
        existing_ids = {str(e["id"]) for e in self._current_list()}

        def on_add(entries):
            key = self._list_key(device_type)
            stored = self.settings.get(key, [])
            for entry in entries:
                # normalize to the full catalog; _fetch_entry_details fills
                # in the rest right after
                for field in CATALOG_FIELDS:
                    entry.setdefault(field, "")
                stored.append(entry)
                existing_ids.add(str(entry["id"]))
            self.settings.set(key, stored)
            self.settings.save()
            if device_type == self.var_type.get():
                self._populate_tree()
            names = ", ".join(e["name"] or e["serial"] or e["id"] for e in entries)
            self.log(f"Added to list: {names}")
            # fill in model / MAC / IP right away
            self._fetch_entry_details(device_type, [str(e["id"]) for e in entries])

        AddDeviceDialog(self, self.client, device_type, existing_ids, on_add)

    def _fetch_entry_details(self, device_type, ids):
        """Fetch full records for the given ids and fill in all list fields."""
        ids = [str(i) for i in ids]

        def work():
            updated, missing = [], []
            for device_id in ids:
                try:
                    if device_type == "computer":
                        record = self.client.get_computer(device_id)
                    else:
                        record = self.client.get_mobile_device(device_id)
                except JamfError as exc:
                    if "404" in str(exc):
                        missing.append(device_id)
                        continue
                    raise
                updated.append(entry_from_record(record, device_type, device_id))
            return updated, missing

        def done(result, error):
            if error:
                self.log(f"Could not fetch device details: {error}")
                return
            updated, missing = result
            for entry in updated:
                self._update_list_entry(device_type, entry["id"],
                                        {f: entry[f] for f in CATALOG_FIELDS})
            if missing:
                self.log(f"{len(missing)} device(s) not found while fetching details.")

        self._run_async(work, done)

    def move_selected(self, direction):
        """Move the selected row(s) up (-1) or down (+1) in the saved order."""
        selection = list(self.tree.selection())
        if not selection:
            return
        key = self._list_key()
        entries = self.settings.get(key, [])
        order = [str(e["id"]) for e in entries]
        by_id = {str(e["id"]): e for e in entries}
        indices = sorted(order.index(i) for i in selection if i in order)
        if not indices:
            return
        # bail if the block is already against the edge it's moving toward
        if direction < 0 and indices[0] == 0:
            return
        if direction > 0 and indices[-1] == len(order) - 1:
            return
        for idx in (indices if direction < 0 else reversed(indices)):
            order[idx], order[idx + direction] = order[idx + direction], order[idx]
        self.settings.set(key, [by_id[i] for i in order])
        self.settings.save()
        self._sort_state = {}          # manual order overrides any column sort
        self._populate_tree()
        self.tree.selection_set(selection)
        self.tree.see(selection[0])

    def sort_by_column(self, column):
        """Sort the current list by a column; click again to reverse."""
        key = self._list_key()
        entries = list(self.settings.get(key, []))
        if not entries:
            return
        ascending = not self._sort_state.get(column, False)
        self._sort_state = {column: ascending}

        def sort_key(entry):
            value = str(entry.get(column, ""))
            # IPs sort numerically by octet; everything else case-insensitively
            if column == "ip" and value:
                try:
                    return (0, tuple(int(p) for p in value.split(".")))
                except ValueError:
                    return (1, value.lower())
            return (0, value.lower()) if value else (2, "")   # blanks last

        entries.sort(key=sort_key, reverse=not ascending)
        self.settings.set(key, entries)
        self.settings.save()
        self._populate_tree()
        arrow = " ▲" if ascending else " ▼"
        for col in self._visible_columns():
            self.tree.heading(col, text=COLUMN_HEADINGS[col] + (arrow if col == column else ""))

    def export_list(self):
        """Export the current list to CSV or Excel."""
        entries = self._current_list()
        if not entries:
            messagebox.showinfo(APP_NAME, "The list is empty — nothing to export.")
            return
        kind = "Computers" if self.var_type.get() == "computer" else "Mobile Devices"
        default_name = f"Jamf {kind} {datetime.datetime.now():%Y-%m-%d}"
        path = filedialog.asksaveasfilename(
            parent=self, title="Export list",
            initialfile=default_name, defaultextension=".csv",
            filetypes=[("CSV file", "*.csv"), ("Excel workbook", "*.xlsx")])
        if not path:
            return
        try:
            if path.lower().endswith(".xlsx"):
                self._export_xlsx(path, entries)
            else:
                self._export_csv(path, entries)
        except Exception as exc:
            messagebox.showerror(APP_NAME, f"Could not export the list:\n{exc}")
            return
        self.log(f"Exported {len(entries)} {kind.lower()} to {os.path.basename(path)}.")
        if messagebox.askyesno(APP_NAME, "Export complete. Reveal the file in Finder?"):
            try:
                subprocess.run(["open", "-R", path], check=False)
            except Exception:
                pass

    def _export_csv(self, path, entries):
        # utf-8-sig writes a BOM so Excel opens accented names correctly
        with open(path, "w", newline="", encoding="utf-8-sig") as fh:
            fh.write(self._entries_to_csv(entries))

    def _export_xlsx(self, path, entries):
        """Write a minimal .xlsx with no third-party libraries."""
        import zipfile
        from xml.sax.saxutils import escape

        def col_letter(n):
            letters = ""
            while n >= 0:
                letters = chr(n % 26 + 65) + letters
                n = n // 26 - 1
            return letters

        columns = self._visible_columns()
        rows = [[COLUMN_HEADINGS[f] for f in columns]]
        rows += [[str(entry.get(f, "")) for f in columns] for entry in entries]

        sheet_rows = []
        for r, row in enumerate(rows, start=1):
            cells = []
            for c, value in enumerate(row):
                ref = f"{col_letter(c)}{r}"
                cells.append(
                    f'<c r="{ref}" t="inlineStr"><is><t xml:space="preserve">'
                    f'{escape(value)}</t></is></c>')
            sheet_rows.append(f'<row r="{r}">{"".join(cells)}</row>')
        sheet = (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            f'<sheetData>{"".join(sheet_rows)}</sheetData></worksheet>')
        content_types = (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
            '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
            '</Types>')
        root_rels = (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
            '</Relationships>')
        workbook = (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<sheets><sheet name="Devices" sheetId="1" r:id="rId1"/></sheets></workbook>')
        workbook_rels = (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
            '</Relationships>')
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("[Content_Types].xml", content_types)
            zf.writestr("_rels/.rels", root_rels)
            zf.writestr("xl/workbook.xml", workbook)
            zf.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
            zf.writestr("xl/worksheets/sheet1.xml", sheet)

    def remove_selected(self):
        selection = self.tree.selection()
        if not selection:
            messagebox.showinfo(APP_NAME, "Select one or more devices to remove from the list.")
            return
        key = self._list_key()
        stored = self.settings.get(key, [])
        removed = [e for e in stored if str(e["id"]) in selection]
        self.settings.set(key, [e for e in stored if str(e["id"]) not in selection])
        self.settings.save()
        self._populate_tree()
        names = ", ".join(e.get("name") or e.get("serial") or str(e["id"]) for e in removed)
        self.log(f"Removed from list: {names}")

    def refresh_list(self):
        """Re-fetch every field for every device in the current list."""
        if not self._require_client():
            return
        device_type = self.var_type.get()
        entries = list(self._current_list())
        if not entries:
            self.log("Nothing to refresh — the list is empty.")
            return
        self._busy(f"Refreshing {len(entries)} device(s)…")

        def work():
            updated, missing = [], []
            for entry in entries:
                try:
                    if device_type == "computer":
                        record = self.client.get_computer(entry["id"])
                    else:
                        record = self.client.get_mobile_device(entry["id"])
                except JamfError as exc:
                    if "404" in str(exc):
                        missing.append(entry)
                        continue
                    raise
                updated.append(entry_from_record(record, device_type, entry["id"]))
            return updated, missing

        def done(result, error):
            self._idle()
            if error:
                self.log(f"Refresh failed: {error}")
                messagebox.showerror(APP_NAME, error)
                return
            updated, missing = result
            self.settings.set(self._list_key(device_type), updated)
            self.settings.save()
            if device_type == self.var_type.get():
                self._populate_tree()
            message = f"Refreshed {len(updated)} device(s)."
            if missing:
                names = ", ".join(e.get("name") or str(e["id"]) for e in missing)
                message += f" Dropped {len(missing)} no longer in Jamf Pro: {names}"
            self.log(message)

        self._run_async(work, done)

    # -- copying -------------------------------------------------------------
    def _copy_text(self, text, what):
        self.clipboard_clear()
        self.clipboard_append(text)
        self.log(f"Copied {what}: {text}" if "\n" not in text
                 else f"Copied {what} ({len(text.splitlines())} lines).")

    def _show_copy_menu(self, event):
        row = self.tree.identify_row(event.y)
        if not row:
            # Right-click on the header (or empty space): offer column options.
            return self._show_column_menu(event)
        if row not in self.tree.selection():
            self.tree.selection_set(row)
        columns = self._visible_columns()
        column_id = self.tree.identify_column(event.x)   # e.g. '#4'
        try:
            field = columns[int(column_id.lstrip("#")) - 1]
        except (ValueError, IndexError):
            field = columns[0]
        values = self.tree.item(row)["values"]
        cell = str(values[columns.index(field)])

        menu = tk.Menu(self, tearoff=0)

        # Actions first, in a fixed order for both device types. An action is
        # enabled only when a single row is selected AND it applies to this
        # type — mobile-only actions stay visible-but-disabled on computers so
        # every action keeps the same position in the menu.
        count = len(self.tree.selection())
        for label, method, mobile_only, bulk in self.ACTIONS:
            handler = getattr(self, method)
            menu_label = label
            enabled = self._action_available(mobile_only)
            if count > 1:
                if bulk:
                    handler = getattr(self, bulk)
                    menu_label = f"{label} ({count})"
                else:
                    enabled = False
            menu.add_command(label=menu_label,
                             state="normal" if enabled else "disabled",
                             command=handler)
        menu.add_separator()

        shown = cell if len(cell) <= 40 else cell[:37] + "…"
        heading = COLUMN_HEADINGS[field]
        menu.add_command(label=f"Copy {heading} ({shown})" if shown else f"Copy {heading}",
                         command=lambda: self._copy_text(cell, heading))
        if not cell:
            menu.entryconfigure(menu.index("end"), state="disabled")
        menu.add_separator()
        menu.add_command(label="Copy row", command=self.copy_rows)
        selected = len(self.tree.selection())
        csv_label = "Copy rows as CSV" if selected > 1 else "Copy row as CSV"
        menu.add_command(label=csv_label, command=self.copy_rows_as_csv)
        menu.add_command(label="Copy list as CSV", command=self.copy_list_as_csv)
        menu.tk_popup(event.x_root, event.y_root)
        return "break"

    def copy_rows(self):
        """Copy selected row(s) as tab-separated text (Cmd+C)."""
        selection = self.tree.selection()
        if not selection:
            return
        lines = []
        for row in selection:
            values = self.tree.item(row)["values"]
            lines.append("\t".join(str(v) for v in values))
        what = "row" if len(lines) == 1 else "rows"
        self._copy_text("\n".join(lines), what)

    def _entries_to_csv(self, entries):
        """Render entries (with a header row) as CSV text."""
        import csv
        import io
        buffer = io.StringIO()
        writer = csv.writer(buffer)
        columns = self._visible_columns()
        writer.writerow([COLUMN_HEADINGS[f] for f in columns])
        for entry in entries:
            writer.writerow([entry.get(f, "") for f in columns])
        return buffer.getvalue()

    def copy_rows_as_csv(self):
        """Copy the selected row(s) as CSV, including a header row."""
        selection = self.tree.selection()
        if not selection:
            return
        by_id = {str(e["id"]): e for e in self._current_list()}
        entries = [by_id[i] for i in selection if i in by_id]
        if not entries:
            return
        what = "row as CSV" if len(entries) == 1 else f"{len(entries)} rows as CSV"
        self._copy_text(self._entries_to_csv(entries), what)

    def copy_list_as_csv(self):
        """Copy the entire current list as CSV, including a header row."""
        entries = self._current_list()
        if not entries:
            self.status.set("The list is empty — nothing to copy.")
            return
        self._copy_text(self._entries_to_csv(entries), f"list as CSV ({len(entries)} rows)")

    # -- shared action plumbing ----------------------------------------------
    def _selected_devices(self, minimum=1):
        """Every selected device, as dicts. Used by the bulk actions."""
        selection = self.tree.selection()
        if len(selection) < minimum:
            messagebox.showinfo(APP_NAME, "Select one or more devices in the list first.")
            return []
        device_type = self.var_type.get()
        by_id = {str(e["id"]): e for e in self._current_list()}
        devices = []
        for row in selection:
            entry = by_id.get(str(row), {})
            devices.append({"id": str(row),
                            "name": entry.get("name", str(row)),
                            "type": device_type})
        return devices

    # -- bulk actions ----------------------------------------------------------
    def _bulk_prefetch(self, devices, on_ready):
        """Fetch each device's record (sequentially, so we don't hammer the
        server), then hand back [(device, record, tags), …] plus any failures.
        Used by bulk actions that need per-device data to build a preview."""
        dialog = BulkProgressDialog(self, "Preparing…", len(devices))
        gathered, failures = [], []

        def work():
            for index, device in enumerate(devices, start=1):
                if dialog.cancelled:
                    break
                self.after(0, dialog.step, index - 1,
                           f"Reading {device['name']} ({index} of {len(devices)})…")
                try:
                    if device["type"] == "computer":
                        record = self.client.get_computer(device["id"])
                    else:
                        record = self.client.get_mobile_device(device["id"])
                    tags = build_tag_values(record, device["type"], device["id"])
                    gathered.append((device, record, tags))
                except (JamfError, MerakiError) as exc:
                    failures.append((device, str(exc)))
                except Exception as exc:
                    failures.append((device, f"Unexpected error: {exc}"))
            return dialog.cancelled

        def done(cancelled, error):
            dialog.finish()
            if error:
                self.log(f"Bulk preparation failed: {error}")
                messagebox.showerror(APP_NAME, error)
                return
            if cancelled:
                self.log("Bulk action cancelled while reading devices.")
                return
            for device, message in failures:
                self.log(f"Skipped {device['name']}: {message}")
            if not gathered:
                messagebox.showerror(
                    APP_NAME, "None of the selected devices could be read. "
                              "See the activity log for details.")
                return
            on_ready(gathered, failures)

        self._run_async(work, done)

    def _bulk_run(self, title, devices, work_for, on_finish=None):
        """Run `work_for(device)` for each device, one at a time, with progress
        and a Cancel button. Each result is logged; a summary closes it out."""
        dialog = BulkProgressDialog(self, title, len(devices))
        results = {"ok": 0, "failed": 0, "skipped": 0}

        def work():
            for index, device in enumerate(devices, start=1):
                if dialog.cancelled:
                    results["skipped"] = len(devices) - index + 1
                    break
                self.after(0, dialog.step, index - 1,
                           f"{device['name']} ({index} of {len(devices)})…")
                try:
                    note = work_for(device)
                    results["ok"] += 1
                    suffix = f" {note}" if isinstance(note, str) and note else ""
                    self.after(0, self.log, f"OK — {device['name']}.{suffix}")
                except (JamfError, MerakiError) as exc:
                    results["failed"] += 1
                    self.after(0, self.log, f"FAILED — {device['name']}: {exc}")
                except Exception as exc:
                    results["failed"] += 1
                    self.after(0, self.log,
                               f"FAILED — {device['name']}: Unexpected error: {exc}")
            return results

        def done(res, error):
            dialog.finish()
            if error:
                messagebox.showerror(APP_NAME, error)
                return
            parts = [f"{res['ok']} succeeded"]
            if res["failed"]:
                parts.append(f"{res['failed']} failed")
            if res["skipped"]:
                parts.append(f"{res['skipped']} skipped (cancelled)")
            summary = ", ".join(parts) + "."
            self.log(f"{title}: {summary}")
            self.status.set(summary)
            if res["failed"]:
                messagebox.showwarning(
                    APP_NAME, f"{title}\n\n{summary}\n\n"
                              "See the activity log for the devices that failed.")
            if on_finish:
                on_finish(res)

        self._run_async(work, done)

    def _list_preview(self, lines, limit=200):
        """Cap absurdly long confirmation lists so the dialog stays usable."""
        if len(lines) <= limit:
            return lines
        return lines[:limit] + [f"… and {len(lines) - limit} more"]

    def bulk_rename(self):
        """Rename every selected device using the type's default template."""
        if not self._require_client():
            return
        devices = self._selected_devices()
        if not devices:
            return
        device_type = devices[0]["type"]
        template_key = ("rename_format_mobile" if device_type == "mobile"
                        else "rename_format_computer")
        template = self.settings.get(template_key)

        def ready(gathered, _failures):
            planned = []
            for device, _record, tags in gathered:
                new_name = render_template(template, tags)
                if new_name and new_name != device["name"]:
                    planned.append((device, new_name))
                else:
                    reason = "name already matches" if new_name else "template produced an empty name"
                    self.log(f"Skipped {device['name']}: {reason}.")
            if not planned:
                messagebox.showinfo(APP_NAME, "Nothing to rename — every selected "
                                              "device already matches the template.")
                return
            lines = self._list_preview([f"{d['name']}  →  {n}" for d, n in planned])
            confirm = BulkConfirmDialog(
                self, "Rename Devices",
                f"{len(planned)} device(s) will be renamed using the template "
                f"“{template}”. Review the new names below.",
                lines, f"Rename {len(planned)} Device(s)")
            if not confirm.result:
                self.log("Bulk rename cancelled.")
                return
            names = dict((d["id"], n) for d, n in planned)

            def work_for(device):
                new_name = names[device["id"]]
                if device["type"] == "computer":
                    note = self.client.rename_computer(device["id"], new_name)
                else:
                    note = self.client.rename_mobile_device(device["id"], new_name)
                self.after(0, self._update_list_entry, device["type"], device["id"],
                           {"name": new_name})
                return note

            self._bulk_run("Rename devices", [d for d, _n in planned], work_for)

        self._bulk_prefetch(devices, ready)

    def bulk_toggle_lost_mode(self):
        """Enable or disable Lost Mode on every selected mobile device."""
        if not self._require_client():
            return
        devices = self._selected_devices()
        if not devices:
            return
        if devices[0]["type"] != "mobile":
            messagebox.showinfo(APP_NAME, "Lost Mode is only available for mobile devices.")
            return

        def ready(gathered, _failures):
            on, off, unknown = [], [], []
            for device, _record, tags in gathered:
                state = lost_mode_enabled(_record)
                (on if state is True else off if state is False else unknown).append(
                    (device, tags))
            summary = (f"Currently on: {len(on)}   off: {len(off)}   "
                       f"not reported: {len(unknown)}")
            lines = self._list_preview(
                [f"{d['name']}  —  {'ON' if (d, t) in on else 'OFF' if (d, t) in off else 'unknown'}"
                 for d, t in on + off + unknown])
            choice = messagebox.askyesnocancel(
                APP_NAME,
                f"{len(gathered)} mobile device(s) selected.\n{summary}\n\n"
                "Yes — enable Lost Mode on all of them\n"
                "No — disable Lost Mode on all of them\n"
                "Cancel — do nothing\n\n"
                "Applying one direction to every device keeps the result "
                "predictable when the devices are in mixed states.")
            if choice is None:
                self.log("Bulk Lost Mode cancelled.")
                return

            targets = [(d, t) for d, t in on + off + unknown]
            if choice:
                message_tpl = self.settings.get("lost_mode_message")
                phone_tpl = self.settings.get("lost_mode_phone")
                footnote_tpl = self.settings.get("lost_mode_footnote")
                sound = bool(self.settings.get("lost_mode_sound", False))
                preview = self._list_preview(
                    [f"{d['name']}  →  {render_template(message_tpl, t)}"
                     for d, t in targets])
                confirm = BulkConfirmDialog(
                    self, "Enable Lost Mode",
                    f"Lost Mode will be enabled on {len(targets)} device(s), "
                    "locking each one and showing this message on its screen.",
                    preview, f"Enable on {len(targets)} Device(s)",
                    warning="Each device becomes unusable until Lost Mode is "
                            "turned off.")
                if not confirm.result:
                    self.log("Bulk Enable Lost Mode cancelled.")
                    return
                tag_map = {d["id"]: t for d, t in targets}

                def work_for(device):
                    tags = tag_map[device["id"]]
                    return self.client.enable_lost_mode(
                        device["id"],
                        render_template(message_tpl, tags),
                        render_template(phone_tpl, tags),
                        render_template(footnote_tpl, tags),
                        sound)

                self._bulk_run("Enable Lost Mode", [d for d, _t in targets], work_for)
            else:
                confirm = BulkConfirmDialog(
                    self, "Disable Lost Mode",
                    f"Lost Mode will be turned off on {len(targets)} device(s).",
                    self._list_preview([d["name"] for d, _t in targets]),
                    f"Disable on {len(targets)} Device(s)")
                if not confirm.result:
                    self.log("Bulk Disable Lost Mode cancelled.")
                    return

                def work_for(device):
                    return self.client.disable_lost_mode(device["id"])

                self._bulk_run("Disable Lost Mode", [d for d, _t in targets], work_for)

        self._bulk_prefetch(devices, ready)

    def bulk_lock(self):
        """Lock every selected device."""
        if not self._require_client():
            return
        devices = self._selected_devices()
        if not devices:
            return
        device_type = devices[0]["type"]
        lines = self._list_preview([d["name"] for d in devices])

        if device_type == "computer":
            message = render_template(self.settings.get("lock_message"), {})
            pin_dialog = PreviewDialog(
                self, "Lock computers",
                f"Lock {len(devices)} Mac(s). The PIN below will be required to "
                "unlock every one of them — record it before continuing.",
                [("6-digit PIN", "", False), ("Lock message", message, True)],
                confirm_label="Continue")
            if pin_dialog.result is None:
                self.log("Bulk lock cancelled.")
                return
            passcode = (pin_dialog.result.get("6-digit PIN") or "").strip()
            message = pin_dialog.result.get("Lock message", message)
            if not (passcode.isdigit() and len(passcode) == 6):
                messagebox.showerror(APP_NAME, "The PIN must be exactly 6 digits.")
                return
            confirm = BulkConfirmDialog(
                self, "Lock Computers",
                f"{len(devices)} Mac(s) will be locked immediately and will "
                f"require the PIN {passcode} to unlock.",
                lines, f"Lock {len(devices)} Mac(s)",
                warning="Write this PIN down now — the same PIN unlocks every "
                        "device in this batch.")
            if not confirm.result:
                self.log("Bulk lock cancelled.")
                return
            self.log(f"Bulk lock PIN for this batch: {passcode}")

            def work_for(device):
                return self.client.lock_computer(device["id"], passcode, message)
        else:
            confirm = BulkConfirmDialog(
                self, "Lock Devices",
                f"{len(devices)} mobile device(s) will be locked immediately. "
                "Each one locks with its existing passcode.",
                lines, f"Lock {len(devices)} Device(s)")
            if not confirm.result:
                self.log("Bulk lock cancelled.")
                return

            def work_for(device):
                return self.client.lock_mobile_device(device["id"])

        self._bulk_run("Lock devices", devices, work_for)

    def bulk_open_in_jamf(self):
        """Open every selected device's Jamf Pro page in the browser."""
        if not self._require_client():
            return
        devices = self._selected_devices()
        if not devices:
            return
        if len(devices) > 10 and not messagebox.askyesno(
                APP_NAME,
                f"This will open {len(devices)} browser tabs. Continue?"):
            return
        base = self.client.base_url.rstrip("/")
        page = "computers.html" if devices[0]["type"] == "computer" else "mobileDevices.html"
        for device in devices:
            webbrowser.open(f"{base}/{page}?id={device['id']}&o=r")
        self.log(f"Opened {len(devices)} device(s) in Jamf Pro.")

    def _with_device_detail(self, device, next_step):
        """Fetch the full record (for tags), then call next_step(record, tags)."""
        self._busy(f"Fetching {device['name']}…")

        def work():
            if device["type"] == "computer":
                return self.client.get_computer(device["id"])
            return self.client.get_mobile_device(device["id"])

        def done(record, error):
            self._idle()
            if error:
                self.log(f"Could not load device record: {error}")
                messagebox.showerror(APP_NAME, error)
                return
            tags = build_tag_values(record, device["type"], device["id"])
            next_step(record, tags)

        self._run_async(work, done)

    def _send(self, description, work, on_success=None):
        self._busy(description)

        def done(result, error):
            self._idle()
            if error:
                self.log(f"FAILED — {description}: {error}")
                messagebox.showerror(APP_NAME, error)
            else:
                note = f" {result}" if isinstance(result, str) else ""
                self.log(f"OK — {description}.{note}")
                if on_success:
                    on_success()

        self._run_async(work, done)

    # -- actions -------------------------------------------------------------
    def _meraki_client(self):
        key = self.settings.get_secret("meraki_api_key")
        if not key:
            messagebox.showinfo(APP_NAME, "Add your Meraki Dashboard API key in "
                                          "Settings > Meraki first.")
            self.open_settings()
            return None
        return MerakiClient(key,
                            ssl_verify=bool(self.settings.get("ssl_verify", True)),
                            ssl_ca_bundle=self.settings.get("ssl_ca_bundle", ""))

    def action_meraki_info(self):
        meraki = self._meraki_client()
        if meraki is None:
            return
        device = self._selected_device()
        if not device:
            return
        if not self._require_client():
            return

        stored = next((e for e in self._current_list()
                       if str(e["id"]) == str(device["id"])), {})
        cached_mac = str(stored.get("wifi_mac", "")).strip()

        # Always re-read the MAC from Jamf Pro rather than trusting the saved
        # list row: querying Meraki with a stale MAC returns a confident answer
        # about the wrong device.
        def step(record, tags):
            entry = entry_from_record(record, device["type"], device["id"])
            self._update_list_entry(device["type"], device["id"],
                                    {f: entry[f] for f in CATALOG_FIELDS})
            mac = tags["wifi_mac"]
            if not mac:
                messagebox.showinfo(
                    APP_NAME,
                    f"Jamf Pro has no MAC address on record for “{device['name']}”.\n\n"
                    "Try “Update inventory” and check back once the device has "
                    "reported in.")
                return
            if cached_mac and normalize_mac(cached_mac) != normalize_mac(mac):
                self.log(f"Note: MAC for {device['name']} changed since it was added "
                         f"({cached_mac} → {mac}). Using the current one.")
            self._meraki_ensure_network(meraki, device, mac)

        self._with_device_detail(device, step)

    def _meraki_ensure_network(self, meraki, device, mac):
        """Org-wide search needs no network. Only fall back to the per-network
        lookup if the user asks for it."""
        self._meraki_ensure_org(meraki, lambda org_id: self._meraki_search(
            meraki, device, mac, org_id))

    def _meraki_ensure_org(self, meraki, then):
        org_id = self.settings.get("meraki_org_id")
        if org_id:
            then(org_id)
            return
        self._busy("Loading Meraki organizations…")

        def done(orgs, error):
            self._idle()
            if error:
                self.log(f"Meraki lookup failed: {error}")
                messagebox.showerror(APP_NAME, error)
                return
            if not orgs:
                messagebox.showinfo(APP_NAME, "That Meraki API key can't see any "
                                              "organizations. Check the key in Settings > Meraki.")
                return
            if len(orgs) == 1:
                # nothing to choose — remember it silently
                self.settings.set("meraki_org_id", str(orgs[0].get("id")))
                self.settings.set("meraki_org_name", orgs[0].get("name", ""))
                self.settings.save()
                then(str(orgs[0].get("id")))
                return
            MerakiOrgDialog(self, orgs, self.settings, then)

        self._run_async(meraki.get_organizations, done)

    def _meraki_ap_name(self, meraki, network_id, ap_mac):
        """Resolve an AP's MAC to its Dashboard name, caching per network."""
        if not ap_mac:
            return ""
        ap_mac = normalize_mac(ap_mac)
        cache = getattr(self, "_ap_cache", None)
        if cache is None:
            cache = self._ap_cache = {}
        if network_id not in cache:
            try:
                cache[network_id] = {
                    normalize_mac(hardware.get("mac", "")):
                        (hardware.get("name") or hardware.get("mac", ""))
                    for hardware in meraki.get_devices(network_id)
                }
            except MerakiError:
                cache[network_id] = {}
        return cache[network_id].get(ap_mac, "")

    def _meraki_search(self, meraki, device, mac, org_id):
        """One org-wide call: finds the client and the network it's on."""
        org_name = self.settings.get("meraki_org_name") or org_id
        self._busy(f"Searching Meraki for {device['name']}…")

        def work():
            payload = meraki.search_client(org_id, mac)
            if not payload:
                return None
            # newest sighting first
            records = sorted(payload.get("records", []),
                             key=lambda r: r.get("lastSeen") or 0, reverse=True)
            record = dict(records[0])
            network = record.get("network") or {}
            record.setdefault("manufacturer", payload.get("manufacturer", ""))
            if not record.get("recentDeviceName"):
                record["recentDeviceName"] = self._meraki_ap_name(
                    meraki, network.get("id"), record.get("recentDeviceMac"))
            return {"record": record, "network": network,
                    "count": len(records), "payload": payload}

        def done(result, error):
            self._idle()
            if error:
                self.log(f"Meraki lookup failed: {error}")
                messagebox.showerror(APP_NAME, error)
                return
            if result is None:
                self.log(f"Meraki: {normalize_mac(mac)} not found in “{org_name}”.")
                if messagebox.askyesno(
                        APP_NAME,
                        f"No client with MAC {normalize_mac(mac)} was found anywhere "
                        f"in the “{org_name}” organization.\n\n"
                        "This usually means the device hasn't been on the Wi-Fi "
                        "recently. Search one specific network instead?"):
                    self._meraki_pick_network(meraki, device, mac)
                return

            record = result["record"]
            network = result["network"]
            network_name = network.get("name") or "unknown network"
            note = "Right-click a field to copy it."
            if result["count"] > 1:
                note = (f"Seen on {result['count']} networks — showing the most "
                        "recent. See Full response… for all.")
            ap = record.get("recentDeviceName") or record.get("recentDeviceMac") or "?"
            self.log(f"Meraki: {device['name']} — network “{network_name}”, "
                     f"SSID “{record.get('ssid') or '?'}”, AP “{ap}”, "
                     f"last seen {friendly_timestamp(record.get('lastSeen')) or '?'}.")
            MerakiInfoDialog(
                self, device["name"], mac, network_name, record,
                on_change_network=lambda: self._meraki_pick_network(meraki, device, mac),
                change_label="Search a network…",
                note=note)

        self._run_async(work, done)

    def _meraki_pick_network(self, meraki, device, mac):
        MerakiNetworkDialog(self, meraki, self.settings,
                            lambda _network: self._meraki_lookup(meraki, device, mac))

    def _meraki_lookup(self, meraki, device, mac):
        """Fallback: look the client up in one specific network."""
        network_id = self.settings.get("meraki_network_id")
        network_name = self.settings.get("meraki_network_name") or network_id
        self._busy(f"Looking up {device['name']} in Meraki ({network_name})…")

        def work():
            client = meraki.get_client(network_id, mac)
            # Some Dashboard responses include only the AP's MAC; resolve it
            # to the device name the user actually knows.
            if client and not client.get("recentDeviceName"):
                client["recentDeviceName"] = self._meraki_ap_name(
                    meraki, network_id, client.get("recentDeviceMac"))
            return client

        def done(client, error):
            self._idle()
            if error:
                self.log(f"Meraki lookup failed: {error}")
                messagebox.showerror(APP_NAME, error)
                return
            if client is None:
                self.log(f"Meraki: {normalize_mac(mac)} not found in “{network_name}”.")
                if messagebox.askyesno(
                        APP_NAME,
                        f"No client with MAC {normalize_mac(mac)} was found in the "
                        f"“{network_name}” network.\n\nLook in a different network?"):
                    self._meraki_pick_network(meraki, device, mac)
                return
            ap = client.get("recentDeviceName") or client.get("recentDeviceMac") or "?"
            self.log(f"Meraki: {device['name']} — SSID “{client.get('ssid') or '?'}”, "
                     f"AP “{ap}”, last seen {friendly_timestamp(client.get('lastSeen')) or '?'}.")
            MerakiInfoDialog(
                self, device["name"], mac, network_name, client,
                on_change_network=lambda: self._meraki_pick_network(meraki, device, mac),
                change_label="Change network…")

        self._run_async(work, done)

    def action_show_info(self):
        if not self._require_client():
            return
        device = self._selected_device()
        if not device:
            return

        def step(record, _tags):
            noun = "Computer" if device["type"] == "computer" else "Mobile device"
            DeviceInfoDialog(
                self, f"{device['name']} — {noun} info (ID {device['id']})", record)
            self.log(f"Showing device info for {device['name']}.")

        self._with_device_detail(device, step)

    def action_rename(self):
        if not self._require_client():
            return
        device = self._selected_device()
        if not device:
            return

        def step(_record, tags):
            template_key = ("rename_format_mobile" if device["type"] == "mobile"
                            else "rename_format_computer")
            proposed = render_template(self.settings.get(template_key), tags)
            new_name = proposed
            if self.settings.get("verify_notes", True):
                dialog = PreviewDialog(
                    self, "Rename device",
                    f"Rename “{device['name']}” using your configured format. "
                    "Edit the result below if needed.",
                    [("New name", proposed, False)], confirm_label="Rename")
                if dialog.result is None:
                    self.log("Rename cancelled.")
                    return
                new_name = dialog.result["New name"]
            if not new_name:
                messagebox.showwarning(APP_NAME, "The new name is empty — check your rename format.")
                return

            update_row = lambda: self._update_list_entry(device["type"], device["id"],
                                                         {"name": new_name})
            if device["type"] == "mobile":
                self._send(f"Rename {device['name']} → {new_name}",
                           lambda: self.client.rename_mobile_device(device["id"], new_name),
                           on_success=update_row)
            else:
                self._send(f"Rename {device['name']} → {new_name}",
                           lambda: self.client.rename_computer(device["id"], new_name),
                           on_success=update_row)

        self._with_device_detail(device, step)

    def action_toggle_lost_mode(self):
        """One button for both directions: read the device's current Lost Mode
        state, then offer the opposite action."""
        if not self._require_client():
            return
        device = self._selected_device()
        if not device:
            return
        if device["type"] != "mobile":
            messagebox.showinfo(APP_NAME, "Lost Mode is only available for mobile devices.")
            return

        def step(record, tags):
            state = lost_mode_enabled(record)
            if state is True:
                self.log(f"Lost Mode is currently ON for {device['name']}.")
                self._disable_lost_mode(device)
            elif state is False:
                self.log(f"Lost Mode is currently OFF for {device['name']}.")
                self._enable_lost_mode(device, tags)
            else:
                # Record didn't report a state — ask rather than guess, since
                # guessing wrong either strands a device or unlocks a lost one.
                self.log(f"Jamf Pro did not report a Lost Mode state for {device['name']}.")
                choice = messagebox.askyesnocancel(
                    APP_NAME,
                    f"Jamf Pro didn't report whether Lost Mode is on for "
                    f"“{device['name']}”.\n\n"
                    "Yes — enable Lost Mode\n"
                    "No — disable Lost Mode\n"
                    "Cancel — do nothing")
                if choice is None:
                    self.log("Lost Mode cancelled.")
                elif choice:
                    self._enable_lost_mode(device, tags)
                else:
                    self._disable_lost_mode(device)

        self._with_device_detail(device, step)

    def _enable_lost_mode(self, device, tags):
        message = render_template(self.settings.get("lost_mode_message"), tags)
        phone = render_template(self.settings.get("lost_mode_phone"), tags)
        footnote = render_template(self.settings.get("lost_mode_footnote"), tags)
        sound = bool(self.settings.get("lost_mode_sound", False))

        if self.settings.get("verify_notes", True):
            dialog = PreviewDialog(
                self, "Enable Lost Mode",
                f"Lost Mode will lock \u201c{device['name']}\u201d and show this on its screen. "
                "The device becomes unusable until Lost Mode is turned off.",
                [("Message", message, True),
                 ("Phone", phone, False),
                 ("Footnote", footnote, False)],
                confirm_label="Enable Lost Mode")
            if dialog.result is None:
                self.log("Enable Lost Mode cancelled.")
                return
            message = dialog.result["Message"]
            phone = dialog.result["Phone"]
            footnote = dialog.result["Footnote"]

        self._send(f"Enable Lost Mode on {device['name']}",
                   lambda: self.client.enable_lost_mode(
                       device["id"], message, phone, footnote, sound))

    def _disable_lost_mode(self, device):
        if not messagebox.askyesno(
                APP_NAME,
                f"Lost Mode is on for \u201c{device['name']}\u201d.\n\nTurn it off?"):
            self.log("Disable Lost Mode cancelled.")
            return
        self._send(f"Disable Lost Mode on {device['name']}",
                   lambda: self.client.disable_lost_mode(device["id"]))

    def action_lock(self):
        if not self._require_client():
            return
        device = self._selected_device()
        if not device:
            return

        def step(_record, tags):
            message = render_template(self.settings.get("lock_message"), tags)

            if device["type"] == "mobile":
                # The mobile DeviceLock command takes no PIN — the device
                # locks immediately with its existing passcode.
                if not messagebox.askyesno(
                        APP_NAME,
                        f"Lock “{device['name']}” now?\n\n"
                        "The device will lock with its existing passcode "
                        "(mobile device locks do not use a PIN). If the device "
                        "has no passcode, it can be unlocked with a swipe."):
                    self.log("Lock cancelled.")
                    return
                self._send(f"Lock {device['name']}",
                           lambda: self.client.lock_mobile_device(device["id"]))
                return

            dialog = PreviewDialog(
                self, "Lock device",
                f"Lock “{device['name']}”. The PIN below will be required to unlock it — "
                "record it before continuing.",
                [("6-digit PIN", "", False), ("Lock message", message, True)],
                confirm_label="Lock")
            if dialog.result is None:
                self.log("Lock cancelled.")
                return
            pin = dialog.result["6-digit PIN"]
            if not (pin.isdigit() and len(pin) == 6):
                messagebox.showwarning(APP_NAME, "The PIN must be exactly 6 digits.")
                return
            self.log(f"Lock PIN for {device['name']}: {pin}  (save this!)")
            self._send(f"Lock {device['name']}",
                       lambda: self.client.lock_computer(
                           device["id"], pin, dialog.result.get("Lock message", "")))

        self._with_device_detail(device, step)

    def action_update_inventory(self):
        if not self._require_client():
            return
        device = self._selected_device()
        if not device:
            return
        if device["type"] == "computer":
            messagebox.showinfo(
                APP_NAME,
                "Jamf Pro has no remote \u201cUpdate Inventory\u201d command for "
                "computers \u2014 a Mac reports inventory by running its own "
                "recon (e.g. `sudo jamf recon`, or on the device's next "
                "check-in). This action is available for mobile devices only.")
            return
        self._send(f"Update inventory for {device['name']}",
                   lambda: self.client.update_inventory_mobile(device["id"]))

    def action_open_in_jamf(self):
        if not self._require_client():
            return
        device = self._selected_device()
        if not device:
            return
        url = self.client.device_web_url(device["type"], device["id"])
        webbrowser.open(url)
        self.log(f"Opened {device['name']} in your browser.")

    # -- dialogs -------------------------------------------------------------
    def open_settings(self):
        SettingsDialog(self, self.settings, on_saved=self._on_settings_saved)

    def _on_settings_saved(self):
        self._rebuild_client()
        self.log("Settings saved.")

    def open_help(self):
        HelpDialog(self)

    def _about(self):
        messagebox.showinfo(
            f"About {APP_NAME}",
            f"{APP_NAME} {APP_VERSION}\n\n"
            "A quick-task utility for the Jamf Pro API.\n"
            "Settings live in ~/Library/Application Support/JamfToolbox.")


def main():
    app = App()
    app.mainloop()


if __name__ == "__main__":
    main()
