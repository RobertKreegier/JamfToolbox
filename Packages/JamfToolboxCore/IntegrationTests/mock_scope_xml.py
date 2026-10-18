# Stateful mock of profile scope XML (GET/PUT) for ScopeChangeChecks.swift. Started by run.sh.
import http.server, ssl, json, re, sys
import xml.etree.ElementTree as ET
# Stateful scope store, Jamf Classic style XML.
def scope_xml(devs=(), groups=(), users=(), ex_devs=(), ex_users=(), all_m=False):
    d = lambda i: f"<mobile_device><id>{i}</id><name>iPad-{i}</name><udid>U-{i}</udid><wifi_mac_address/></mobile_device>"
    u = lambda n: f"<user><id>{abs(hash(n))%900+1}</id><name>{n}</name></user>"
    return ("<scope>" f"<all_mobile_devices>{str(all_m).lower()}</all_mobile_devices><all_jss_users>false</all_jss_users>"
            f"<mobile_devices>{''.join(map(d, devs))}</mobile_devices><buildings/><departments/>"
            f"<mobile_device_groups>{''.join(f'<mobile_device_group><id>{i}</id><name>G{i}</name></mobile_device_group>' for i in groups)}</mobile_device_groups>"
            f"<jss_users>{''.join(map(u, users))}</jss_users><jss_user_groups/>"
            "<limitations><users><user><name>ldapbob</name></user></users><user_groups/><network_segments><network_segment><id>3</id><name>Lab</name></network_segment></network_segments><ibeacons/></limitations>"
            f"<exclusions><mobile_devices>{''.join(map(d, ex_devs))}</mobile_devices><buildings/><departments/><mobile_device_groups><mobile_device_group><id>9</id><name>G9</name></mobile_device_group></mobile_device_groups>"
            f"<users/><user_groups/><network_segments/><ibeacons/><jss_users>{''.join(map(u, ex_users))}</jss_users><jss_user_groups/></exclusions>"
            "</scope>")
S = {148: scope_xml(devs=[101, 102], groups=[7], users=["jdoe", "other"]),
     149: scope_xml(groups=[7], ex_devs=[101], ex_users=["JDoe"]),
     150: scope_xml(all_m=True),
     151: scope_xml().replace("<buildings/>", "<buildings><building><id>2</id><name>High School</name></building></buildings>", 1)}
puts = []
def to_json(el):
    kids = list(el)
    if not kids: return (el.text or "")
    if all(len(list(k)) and k.find("id") is not None or k.find("name") is not None for k in kids):
        return [{c.tag: (c.text or "") for c in k} for k in kids]
    return {k.tag: to_json(k) for k in kids}
def scope_json(i):
    j = to_json(ET.fromstring(S[i]))
    for k, v in list(j.items()):
        if v == "": j[k] = [] if k not in ("all_mobile_devices", "all_jss_users") else "false"
    for sec in ("exclusions", "limitations"):
        for k, v in list(j[sec].items()):
            if v == "": j[sec][k] = []
    return j
JS = {
 "/JSSResource/mobiledevices/id/101": {"mobile_device": {"general": {"id": 101, "name": "iPad-101", "display_name": "iPad-101"},
     "location": {"username": "jdoe"}, "mobile_device_groups": [{"id": 7, "name": "G7"}], "configuration_profiles": [{"display_name": "P148", "uuid": "U148"}]}},
 "/JSSResource/mobiledevicegroups": {"mobile_device_groups": [{"id": 7, "name": "G7", "is_smart": False}, {"id": 9, "name": "G9", "is_smart": True}]},
 "/JSSResource/mobiledeviceconfigurationprofiles": {"configuration_profiles": [{"id": i, "name": f"P{i}"} for i in (148, 149, 150, 151)]},
}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send(self, code, body, ctype):
        b = body.encode(); self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self): self.send(200, json.dumps({"token":"t","expires":"2099-01-01T00:00:00.000Z"}), "application/json")
    def do_GET(self):
        p = self.path
        if p == "/__puts": return self.send(200, json.dumps(puts), "application/json")
        if p.startswith("/JSSResource/mobiledevices/id/101/subset/Location"):
            return self.send(200, json.dumps({"mobile_device": {"location": {"username": "jdoe"}}}), "application/json")
        if p in JS: return self.send(200, json.dumps(JS[p]), "application/json")
        m = re.match(r"/JSSResource/mobiledeviceconfigurationprofiles/id/(\d+)/subset/General&Scope$", p)
        if m and int(m[1]) in S:
            i = int(m[1])
            return self.send(200, json.dumps({"configuration_profile": {"general": {"id": i, "name": f"P{i}", "uuid": f"U{i}", "payloads": ""}, "scope": scope_json(i)}}), "application/json")
        if p.startswith("/JSSResource/"): print("UNHANDLED", p, flush=True)
        m = re.match(r"/JSSResource/mobiledeviceconfigurationprofiles/id/(\d+)/subset/(\w+)$", p)
        if m and int(m[1]) in S:
            i = int(m[1])
            if m[2] == "Scope":
                return self.send(200, f'<?xml version="1.0" encoding="UTF-8"?><configuration_profile>{S[i]}</configuration_profile>', "text/xml")
            return self.send(200, json.dumps({"configuration_profile": {"general": {"id": i, "name": f"P{i}", "redeploy_on_update": "All" if i == 150 else "Newly Assigned"}}}), "application/json")
        if m and int(m[1]) == 403:
            return self.send(200, f'<configuration_profile>{scope_xml(devs=[101])}</configuration_profile>', "text/xml")
        self.send(404, "nf", "text/plain")
    def do_PUT(self):
        m = re.match(r"/JSSResource/mobiledeviceconfigurationprofiles/id/(\d+)$", self.path)
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        puts.append({"path": self.path, "ctype": self.headers.get("Content-Type"), "body": body})
        if m and int(m[1]) == 403: return self.send(403, "<html>forbidden</html>", "text/html")
        root = ET.fromstring(body)
        assert root.tag == "configuration_profile" and [c.tag for c in root] == ["scope"], body
        # Jamf fills names back in on read.
        for md in root.iter("mobile_device"):
            if md.find("name") is None: ET.SubElement(md, "name").text = "iPad-" + md.find("id").text
        S[int(m[1])] = ET.tostring(root.find("scope"), encoding="unicode")
        self.send(201, f"<configuration_profile><id>{m[1]}</id></configuration_profile>", "text/xml")
if __name__ == "__main__":   # mock_field.py imports this file for its profiles
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(sys.argv[1] + "/cert.pem", sys.argv[1] + "/key.pem")
    s = http.server.ThreadingHTTPServer(("127.0.0.1", 18448), H); s.socket = ctx.wrap_socket(s.socket, server_side=True); s.serve_forever()
