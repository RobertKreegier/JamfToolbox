# Demo Jamf Pro + Meraki server for trying the apps by hand (not used by run.sh):
# device search and records, Lost Mode that follows the commands sent, Meraki
# client lookups under /meraki, and the stateful profile scopes of
# mock_scope_xml.py so Scoped Profiles can exclude and un-exclude iPad-101.
#
#   python3 mock_field.py <folder with cert.pem and key.pem>
#   Jamf Pro URL: https://127.0.0.1:18450 (any username and password; turn
#   Verify SSL off). Debug builds read JAMFTOOLBOX_MERAKI_BASE for Meraki:
#   https://127.0.0.1:18450/meraki (any API key).
#   MOCK_TOKEN_DELAY=3 makes sign-in take 3 seconds, like a slow server.
import http.server, json, os, re, ssl, sys, time, urllib.parse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mock_scope_xml as sx

now = time.time()
DEVICES = {
    101: dict(name="iPad-101", serial="DMPXK2Q1AB12", user="jdoe", real="Jane Doe", building="High School", room="114",
              os="18.6", ip="10.42.8.117", mac="a4:c3:61:0e:2b:9f", model="iPad (9th generation)", asset="RR-0101",
              ap="AP-HS-B114", network="High School", seen=4 * 60),
    102: dict(name="iPad-102", serial="DMPXK2Q1AB34", user="mlee", real="Morgan Lee", building="High School", room="Library",
              os="18.5", ip="10.42.9.23", mac="a4:c3:61:0e:2c:11", model="iPad (10th generation)", asset="RR-0102",
              ap="AP-HS-LIB2", network="High School", seen=2 * 3600),
    103: dict(name="iPad-103", serial="DMPXK2Q1AB56", user="", real="", building="Middle School", room="Cart 3",
              os="18.6", ip="", mac="a4:c3:61:0e:2d:42", model="iPad (9th generation)", asset="RR-0103",
              ap=None, network=None, seen=None),
    104: dict(name="Library Cart 7", serial="F9FXK2Q1AB78", user="kpatel", real="Kai Patel", building="Middle School", room="Library",
              os="17.7", ip="10.43.1.50", mac="", model="iPad Air (5th generation)", asset="RR-0104",
              ap=None, network=None, seen=None),
}
LOST = {i: False for i in DEVICES}
COMPUTERS = {
    1: dict(name="MBP-ARIVERA", serial="C02XK2Q1MD6R", user="arivera", real="Alex Rivera", building="District Office", room="210",
            os="15.4", ip="10.40.2.31", mac="3c:22:fb:10:aa:01", model="MacBook Pro (14-inch, 2023)", asset="RR-M001"),
}

def mobile_record(i):
    d = DEVICES[i]
    base = sx.JS["/JSSResource/mobiledevices/id/101"]["mobile_device"] if i == 101 else {}
    return {"mobile_device": {
        "general": {"id": i, "name": d["name"], "display_name": d["name"], "serial_number": d["serial"],
                    "os_version": d["os"], "ip_address": d["ip"], "wifi_mac_address": d["mac"], "model": d["model"],
                    "asset_tag": d["asset"], "udid": f"UDID-{i}", "last_inventory_update": "2026-10-17 08:15:00"},
        "location": {"username": d["user"], "realname": d["real"], "email_address": f"{d['user']}@rrps.example" if d["user"] else "",
                     "building": d["building"], "room": d["room"], "department": "", "position": ""},
        "security": {"lost_mode_enabled": LOST[i]},
        "mobile_device_groups": base.get("mobile_device_groups", []),
        "configuration_profiles": base.get("configuration_profiles", []),
    }}

def computer_record(i):
    d = COMPUTERS[i]
    return {"computer": {
        "general": {"id": i, "name": d["name"], "serial_number": d["serial"], "mac_address": d["mac"],
                    "last_reported_ip": d["ip"], "asset_tag": d["asset"], "udid": f"UDID-M{i}", "report_date": "2026-10-17 07:50:00"},
        "hardware": {"model": d["model"], "os_version": d["os"]},
        "location": {"username": d["user"], "realname": d["real"], "building": d["building"], "room": d["room"]},
    }}

def matches(table, pattern):
    q = urllib.parse.unquote(pattern).strip("*").lower()
    return [i for i, d in table.items() if not q or q in d["name"].lower() or q in d["serial"].lower() or q in d["user"].lower()]

def meraki_client(mac):
    mac = mac.lower()
    for d in DEVICES.values():
        if d["mac"] and d["mac"] == mac and d["ap"]:
            return {"mac": mac, "manufacturer": "Apple", "records": [{
                "network": {"id": "N_" + d["network"].replace(" ", ""), "name": d["network"]},
                "recentDeviceName": d["ap"], "recentDeviceMac": "e0:55:3d:00:00:01", "ssid": "RRPS-Staff",
                "lastSeen": int(now - d["seen"]), "ip": d["ip"], "description": d["name"], "status": "Online"}]}
    return None

class H(sx.H):
    def json(self, code, obj): self.send(code, json.dumps(obj), "application/json")

    def do_POST(self):
        p = self.path
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        if p.endswith("/token"):
            time.sleep(float(os.environ.get("MOCK_TOKEN_DELAY", "0")))
            return self.json(200, {"token": "t", "expires": "2099-01-01T00:00:00.000Z"})
        if p == "/JSSResource/mobiledevicecommands/command":
            command = re.search(r"<command>(\w+)</command>", body)[1]
            i = int(re.search(r"<id>(\d+)</id>", body)[1])
            if command == "EnableLostMode": LOST[i] = True
            return self.send(201, "<mobile_device_command><id>1</id></mobile_device_command>", "text/xml")
        if p == "/api/v2/mdm/commands":
            j = json.loads(body)
            i = int(j["clientData"][0]["managementId"].removeprefix("mm"))
            kind = j["commandData"]["commandType"]
            if kind == "ENABLE_LOST_MODE": LOST[i] = True
            if kind == "DISABLE_LOST_MODE": LOST[i] = False
            if kind == "SETTINGS" and "deviceName" in j["commandData"]: DEVICES[i]["name"] = j["commandData"]["deviceName"]
            return self.json(201, [{"id": "c1", "href": "/api/v2/mdm/commands/c1"}])
        self.json(201, {})

    def do_GET(self):
        u = urllib.parse.urlsplit(self.path); p = u.path
        m = re.match(r"/JSSResource/mobiledevices/match/(.+)$", p)
        if m:
            return self.json(200, {"mobile_devices": [{"id": i, "name": DEVICES[i]["name"], "serial_number": DEVICES[i]["serial"],
                                                         "username": DEVICES[i]["user"], "wifi_mac_address": DEVICES[i]["mac"],
                                                         "model": DEVICES[i]["model"]} for i in matches(DEVICES, m[1])]})
        m = re.match(r"/JSSResource/computers/match/(.+)$", p)
        if m:
            return self.json(200, {"computers": [{"id": i, "name": COMPUTERS[i]["name"], "serial_number": COMPUTERS[i]["serial"],
                                                   "username": COMPUTERS[i]["user"], "model": COMPUTERS[i]["model"]} for i in matches(COMPUTERS, m[1])]})
        m = re.match(r"/JSSResource/mobiledevices/id/(\d+)$", p)
        if m and int(m[1]) in DEVICES: return self.json(200, mobile_record(int(m[1])))
        m = re.match(r"/JSSResource/computers/id/(\d+)$", p)
        if m and int(m[1]) in COMPUTERS: return self.json(200, computer_record(int(m[1])))
        m = re.match(r"/api/v2/mobile-devices/(\d+)/detail$", p)
        if m: return self.json(200, {"managementId": f"mm{m[1]}"})
        if p == "/meraki/organizations": return self.json(200, [{"id": "1", "name": "RRPS"}])
        if p == "/meraki/organizations/1/networks":
            return self.json(200, [{"id": "N_HighSchool", "name": "High School"}, {"id": "N_MiddleSchool", "name": "Middle School"}])
        if p == "/meraki/organizations/1/clients/search":
            found = meraki_client(urllib.parse.parse_qs(u.query)["mac"][0])
            return self.json(200, found) if found else self.json(404, {"errors": ["Not found"]})
        m = re.match(r"/meraki/networks/(\w+)/devices$", p)
        if m: return self.json(200, [])
        super().do_GET()

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(sys.argv[1] + "/cert.pem", sys.argv[1] + "/key.pem")
server = http.server.ThreadingHTTPServer(("127.0.0.1", 18450), H)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
print("Demo Jamf Pro on https://127.0.0.1:18450, Meraki at /meraki", flush=True)
server.serve_forever()
