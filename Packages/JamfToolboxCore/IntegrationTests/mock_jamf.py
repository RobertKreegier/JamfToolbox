# Mock Jamf Pro server (Classic + Jamf Pro API, JSON) for ReportChecks.swift. Started by run.sh.
import http.server, re, ssl, json, sys, time, urllib.parse
from datetime import datetime, timedelta, timezone
now = datetime.now(timezone.utc)
iso = lambda days: (now - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
G = lambda i, n: {"id": i, "name": n}
def scope(all_c=False, comps=(), groups=(), ex_groups=(), ex_comps=(), mobile=False, all_m=False, mgroups=(), ex_mgroups=(), mdevs=(), ex_mdevs=(), users=(), ex_users=()):
    s = {"all_computers": all_c, "computers": [G(i,"") for i in comps], "computer_groups": [G(i,n) for i,n in groups],
         "buildings": [], "departments": [],
         "exclusions": {"computers": [G(i,"") for i in ex_comps], "computer_groups": [G(i,n) for i,n in ex_groups]}}
    if mobile:
        s = {"all_mobile_devices": all_m, "mobile_devices": [G(i,"") for i in mdevs], "mobile_device_groups": [G(i,n) for i,n in mgroups],
             "buildings": [], "departments": [], "jss_users": [G(9,u) for u in users],
             "exclusions": {"mobile_devices": [G(i,"") for i in ex_mdevs], "mobile_device_groups": [G(i,n) for i,n in ex_mgroups], "jss_users": [G(9,u) for u in ex_users]}}
    return s
def plist(*types): return "<plist><dict>" + "".join(f"<dict><key>PayloadType</key><string>{t}</string></dict>" for t in types) + "<key>PayloadType</key><string>Configuration</string></dict></plist>"
def L(key, items): return {key: [dict(id=i, name=n, **e) for i, n, e in items]}
D = {}
D["/JSSResource/computergroups"] = L("computer_groups", [(1,"Lab Macs",{"is_smart":False}),(2,"All Faculty",{"is_smart":False}),(3,"Lab Macs - Old OS",{"is_smart":True}),(4,"Empty Static",{"is_smart":False}),(5,"Lab-Macs",{"is_smart":False})])
D["/JSSResource/computergroups/id/1"] = {"computer_group": {"id":1,"name":"Lab Macs","is_smart":False,"computers":[{"id":1,"name":"MBP-1","serial_number":"C1"},{"id":2,"name":"MBP-2","serial_number":"C2"},{"id":3,"name":"MBP-3","serial_number":"C3x"}]}}
D["/JSSResource/computergroups/id/2"] = {"computer_group": {"id":2,"name":"All Faculty","is_smart":False,"computers":[{"id":4,"name":"MBP-4","serial_number":"C4"}]}}
D["/JSSResource/computergroups/id/3"] = {"computer_group": {"id":3,"name":"Lab Macs - Old OS","is_smart":True,"criteria":[{"name":"Computer Group","search_type":"member of","value":"Lab Macs"}],"computers":[{"id":2,"name":"MBP-2"}]}}
D["/JSSResource/computergroups/id/4"] = {"computer_group": {"id":4,"name":"Empty Static","is_smart":False,"computers":[]}}
D["/JSSResource/computergroups/id/5"] = {"computer_group": {"id":5,"name":"Lab-Macs","is_smart":False,"computers":[{"id":1,"name":"MBP-1"}]}}
D["/JSSResource/mobiledevicegroups"] = L("mobile_device_groups", [(7,"Grade 5 iPads",{"is_smart":False}),(8,"Unused Carts",{"is_smart":False}),(9,"Old iPadOS",{"is_smart":True})])
D["/JSSResource/mobiledevicegroups/id/7"] = {"mobile_device_group": {"id":7,"name":"Grade 5 iPads","is_smart":False,"mobile_devices":[{"id":101,"name":"iPad-101","serial_number":"DMP1","udid":"U-101","wifi_mac_address":"AA:00:00:00:01:01"},{"id":102,"name":"iPad-102","serial_number":"DMP2"},{"id":103,"name":"iPad-103","serial_number":"DMP3"}]}}
D["/JSSResource/mobiledevicegroups/id/8"] = {"mobile_device_group": {"id":8,"name":"Unused Carts","is_smart":False,"mobile_devices":[{"id":104,"name":"iPad-104"}]}}
D["/JSSResource/mobiledevicegroups/id/9"] = {"mobile_device_group": {"id":9,"name":"Old iPadOS","is_smart":True,"criteria":[{"name":"Mobile Device Group","search_type":"member of","value":"Grade 5 iPads"}],"mobile_devices":[{"id":102,"name":"iPad-102"}]}}
pol = {}
pol[10] = ("Install Office", {"enabled": True, "frequency":"Once per computer","trigger_checkin":True}, scope(groups=[(2,"All Faculty")], ex_groups=[(1,"Lab Macs")]))
pol[11] = ("Lab Cleanup", {"enabled": True, "frequency":"Once per day","trigger_checkin":True}, scope(groups=[(1,"Lab Macs")]))
pol[12] = ("Old Policy", {"enabled": False, "frequency":"Once per computer"}, scope(groups=[(2,"All Faculty")]))
pol[13] = ("Nothing", {"enabled": True, "frequency":"Once per computer","trigger_checkin":True}, scope())
pol[14] = ("Ongoing None", {"enabled": True, "frequency":"Ongoing","trigger_other":""}, scope(all_c=True))
pol[15] = ("Ongoing Checkin", {"enabled": True, "frequency":"Ongoing","trigger_checkin":True}, scope(all_c=True))
pol[16] = ("Ongoing Self Service", {"enabled": True, "frequency":"Ongoing"}, scope(all_c=True))
pol[23] = ("User Scoped", {"enabled": True, "frequency":"Once per computer","trigger_checkin":True},
    {"all_computers":False,"all_jss_users":False,"computers":[],"buildings":[],"departments":[],"computer_groups":[],"jss_users":{"user":{"id":3188,"name":"PVE142"}},"jss_user_groups":{},"limitations":{"users":[],"user_groups":[],"network_segments":[],"ibeacons":[]},"exclusions":{"computers":[],"buildings":[],"departments":[],"computer_groups":[],"users":[],"user_groups":[],"network_segments":[],"ibeacons":[],"jss_users":{},"jss_user_groups":{}},"limit_to_users":{"user_groups":[]}})
pol[24] = ("Two Users Wrapped", {"enabled": True, "frequency":"Once per computer","trigger_checkin":True},
    {"all_computers":False,"computers":[],"computer_groups":[],"jss_users":{"user":[{"id":1,"name":"a"},{"id":2,"name":"b"}]},"jss_user_groups":{},"limitations":{},"exclusions":{"jss_users":{}},"limit_to_users":{"user_groups":[{"id":5,"name":"Legacy"}]}})
pol[25] = ("Only Legacy Limit", {"enabled": True, "frequency":"Once per computer","trigger_checkin":True},
    {"all_computers":False,"computers":[],"computer_groups":[],"jss_users":{},"jss_user_groups":{},"limitations":{},"exclusions":{},"limit_to_users":{"user_groups":[{"id":5,"name":"Legacy"}]}})
D["/JSSResource/policies"] = L("policies", [(i, v[0], {}) for i, v in pol.items()])
for i, (n, g, s) in pol.items():
    D[f"/JSSResource/policies/id/{i}/subset/General&Scope&SelfService"] = {"policy": {"general": dict(id=i, name=n, **g), "scope": s, "self_service": {"use_for_self_service": i == 16}}}
mac = {20: ("Wi-Fi Labs", scope(groups=[(1,"Lab Macs")]), ["com.apple.wifi.managed"]),
       21: ("Dock A", scope(all_c=True), ["com.apple.dock"]),
       22: ("Dock B", scope(groups=[(1,"Lab Macs")]), ["com.apple.dock"]),
       23: ("Unscoped", scope(), ["com.apple.screensaver"]),
       24: ("Conflict", scope(groups=[(2,"All Faculty")], ex_groups=[(2,"All Faculty")]), ["com.apple.loginwindow"]),
       25: ("Ghost Group", scope(groups=[(99,"Deleted Group")]), ["com.apple.notificationsettings"]),
       26: ("Empty Target", scope(groups=[(4,"Empty Static")]), ["com.apple.SoftwareUpdate"])}
D["/JSSResource/osxconfigurationprofiles"] = L("os_x_configuration_profiles", [(i, v[0], {}) for i, v in mac.items()])
for i, (n, s, t) in mac.items():
    D[f"/JSSResource/osxconfigurationprofiles/id/{i}/subset/General&Scope"] = {"os_x_configuration_profile": {"general": {"id": i, "name": n, "payloads": plist(*t)}, "scope": s}}
mob = {30: ("Wallpaper Lock", scope(mobile=True, mgroups=[(7,"Grade 5 iPads")]), ["com.apple.wallpaper"], "U30"),
       31: ("Restrictions", scope(mobile=True, mgroups=[(7,"Grade 5 iPads")]), ["com.apple.applicationaccess"], "U31"),
       32: ("Wallpaper Alt", scope(mobile=True, mgroups=[(7,"Grade 5 iPads")]), ["com.apple.wallpaper"], "U32"),
       33: ("Old", scope(mobile=True, mdevs=[101]), ["com.apple.webClip.managed"], "U33"),
       34: ("Excluded One", scope(mobile=True, all_m=True, ex_mgroups=[(9,"Old iPadOS")]), ["com.apple.dnsSettings.managed"], "U34"),
       35: ("Carts Only", scope(mobile=True, mgroups=[(8,"Unused Carts")]), ["com.apple.homescreenlayout"], "U35"),
       36: ("Direct Exclude", scope(mobile=True, mdevs=[101], ex_mdevs=[101]), ["com.apple.notificationsettings"], "U36"),
       37: ("User Target", scope(mobile=True, users=["jdoe"]), ["com.apple.font"], "U37"),
       38: ("User Excluded", scope(mobile=True, mgroups=[(7,"Grade 5 iPads")], ex_users=["JDOE"]), ["com.apple.font"], "U38"),
       39: ("Someone Else", scope(mobile=True, users=["other"]), ["com.apple.font"], "U39"),
       40: ("High School Only", dict(scope(mobile=True), buildings=[G(2,"High School")], jss_user_groups=[G(3,"Staff")]), ["com.apple.font"], "U40"),
       41: ("Tech Dept", dict(scope(mobile=True), departments=[G(4,"Tech")]), ["com.apple.font"], "U41"),
       42: ("Staff Only", dict(scope(mobile=True), jss_user_groups=[G(3,"Staff")]), ["com.apple.font"], "U42"),
       43: ("Not Tech", (lambda x: (x["exclusions"].update(departments=[G(4,"tech")]), x)[1])(scope(mobile=True, all_m=True)), ["com.apple.font"], "U43"),
       44: ("Middle School", dict(scope(mobile=True), buildings=[G(5,"Middle School")], jss_user_groups=[G(6,"Teachers")]), ["com.apple.font"], "U44"),
       45: ("No Staff", (lambda x: (x["exclusions"].update(jss_user_groups=[G(3,"Staff")]), x)[1])(scope(mobile=True, all_m=True)), ["com.apple.font"], "U45"),
       46: ("All Users", dict(scope(mobile=True), all_jss_users=True), ["com.apple.font"], "U46"),
       47: ("Unreadable Group", dict(scope(mobile=True), jss_user_groups=[G(99,"Secret")]), ["com.apple.font"], "U47")}
mob[48] = ("Wrapped User", (lambda x: (x.update(jss_users={"user": {"id": 9, "name": "JDOE"}}, jss_user_groups={}), x["exclusions"].update(jss_users={}, jss_user_groups={}), x)[2])(scope(mobile=True)), ["com.apple.font"], "U48")
D["/JSSResource/usergroups/id/3"] = {"user_group": {"id": 3, "name": "Staff", "is_smart": True, "users": [{"id": 9, "username": "JDoe", "full_name": "J Doe"}]}}
D["/JSSResource/usergroups/id/6"] = {"user_group": {"id": 6, "name": "Teachers", "is_smart": False, "users": [{"id": 8, "username": "other"}]}}
D["/JSSResource/mobiledeviceconfigurationprofiles"] = L("configuration_profiles", [(i, v[0], {}) for i, v in mob.items()])
for i, (n, s, t, u) in mob.items():
    D[f"/JSSResource/mobiledeviceconfigurationprofiles/id/{i}/subset/General&Scope"] = {"configuration_profile": {"general": {"id": i, "name": n, "uuid": u, "payloads": plist(*t)}, "scope": s}}
D["/JSSResource/macapplications"] = L("mac_applications", [(40,"Keynote",{})])
D["/JSSResource/macapplications/id/40/subset/General&Scope"] = {"mac_application": {"scope": scope()}}
D["/JSSResource/mobiledeviceapplications"] = L("mobile_device_applications", [(50,"Seesaw",{})])
D["/JSSResource/mobiledeviceapplications/id/50/subset/General&Scope"] = {"mobile_device_application": {"scope": scope(mobile=True, mgroups=[(7,"Grade 5 iPads")])}}
D["/JSSResource/ebooks"] = L("ebooks", [(60,"Handbook",{})])
D["/JSSResource/ebooks/id/60/subset/General&Scope"] = {"ebook": {"scope": {"computer_groups":[G(1,"Lab Macs")], "mobile_device_groups":[G(7,"Grade 5 iPads")]}}}
D["/JSSResource/advancedcomputersearches"] = L("advanced_computer_searches", [(70,"Lab report",{})])
D["/JSSResource/advancedcomputersearches/id/70"] = {"advanced_computer_search": {"criteria":[{"name":"Computer Group","search_type":"not member of","value":"lab macs"}]}}
D["/JSSResource/advancedmobiledevicesearches"] = {"advanced_mobile_device_searches": []}
D["/JSSResource/computers/id/1"] = {"computer": {"general": {"id":1,"name":"MBP-1"}, "groups_accounts": {"computer_group_memberships": ["Lab Macs", "Lab Macs - Old OS", "Lab-Macs"]},
    "configuration_profiles": [{"id":20,"name":"","uuid":"","is_removable":True},{"id":23,"name":"","uuid":""},{"id":-1,"name":"","uuid":"MDM-PROFILE"}]}}
D["/JSSResource/mobiledevices/id/101"] = {"mobile_device": {"general": {"id":101,"name":"iPad-101","display_name":"iPad-101"}, "location": {"username": "JDoe", "building": "High School", "department": "Tech"},
    "mobile_device_groups": [G(7,"Grade 5 iPads"), G(9,"Old iPadOS")],
    "configuration_profiles": [{"display_name":"Wallpaper Lock","uuid":"U30","identifier":"x"},{"display_name":"Old","uuid":"U33"},{"display_name":"Stray","uuid":"U-STRAY"},{"display_name":"Tech Dept","uuid":"U41"},{"display_name":"Staff Only","uuid":"U42"}]}}
def logs(*entries): return {"computer_history": {"policy_logs": [dict(policy_id=p, policy_name=n, status=s, date_completed_epoch=int((now - timedelta(days=d)).timestamp()*1000)) for p, n, s, d in entries]}}
D["/JSSResource/computerhistory/id/1/subset/PolicyLogs"] = logs((11,"Lab Cleanup","Failed",2),(10,"Install Office","Completed",1))
D["/JSSResource/computerhistory/id/2/subset/PolicyLogs"] = logs((11,"Lab Cleanup","Failed",5))
D["/JSSResource/computerhistory/id/3/subset/PolicyLogs"] = logs((10,"Install Office","Failed",100))
D["/JSSResource/computerhistory/id/4/subset/PolicyLogs"] = logs()
def comp(i, name, seen, serial, user, os, fv, fvstate):
    g = {"name": name, "managementId": f"mc{i}", "remoteManagement": {"managed": True}}
    if seen is not None: g["lastContactTime"] = iso(seen)
    return {"id": str(i), "general": g, "hardware": {"serialNumber": serial}, "userAndLocation": {"username": user},
            "operatingSystem": {"version": os}, "diskEncryption": {"fileVault2Enabled": fv, "bootPartitionEncryptionDetails": ({"partitionFileVault2State": fvstate} if fvstate else {})}}
COMPUTERS = [comp(1,"MBP-1",2,"C1","jdoe","15.4",True,"ENCRYPTED"), comp(2,"MBP-2",60,"C2","asmith","14.7",False,"UNENCRYPTED"),
             comp(3,"MBP-3",None,"C1","","13.6",False,None), comp(4,"MBP-4",0,"C4","bjones","15.10",True,"ENCRYPTED")]
def mobile(i, sup, managed, seen, os, user, serial, loc=None):
    return {"mobileDeviceId": str(i), "deviceType": "iOS", "general": {"displayName": f"iPad-{i}", "supervised": sup, "managed": managed,
            "lastInventoryUpdateDate": iso(seen), "osVersion": os, "managementId": f"mm{i}"}, "hardware": {"serialNumber": serial}, "userAndLocation": dict({"username": user}, **(loc or {}))}
# iPad-101 comes in the flat shape newer Jamf Pro versions send; the others are sectioned.
def mobile_flat(i, sup, managed, seen, os, user, serial, loc=None):
    return {"id": str(i), "name": f"iPad-{i}", "serialNumber": serial, "osVersion": os, "managed": managed,
            "lastInventoryUpdateTimestamp": iso(seen), "managementId": f"mm{i}", "type": "ios",
            "location": dict({"username": user, "realName": "J Doe"}, **(loc or {})), "ios": {"supervised": sup, "model": "iPad"},
            "tvos": None, "groups": [{"groupId": "7", "groupName": "Grade 5 iPads", "smart": False}]}
MOBILES = [mobile_flat(101,True,True,1,"18.3","JDoe","DMP1",{"buildingId": "2", "departmentId": "4"}), mobile(102,False,True,3,"17.7","kid2","DMP2",{"departmentName": "TECH"}),
           mobile(103,True,True,90,"18.0","","DMP3"), mobile(104,False,False,2,"16.0","kid4","C4")]
def cmd(mid, ctype, state, ctype2, days, profile=None, err=""):
    c = {"uuid": "x", "client": {"managementId": mid, "clientType": ctype}, "commandState": state, "commandType": ctype2, "dateSent": iso(days)}
    if profile: c["profileId"] = profile
    if err: c["commandError"] = {"errorEnglishDescription": err}
    return c
PENDING = [cmd("mm102","MOBILE_DEVICE","PENDING","SETTINGS",d) for d in (1,2,3,40)] + [cmd("mm102","MOBILE_DEVICE","PENDING","DEVICE_INFORMATION",d) for d in (1,2)] \
        + [cmd("mm102","MOBILE_DEVICE","PENDING","INSTALL_PROFILE",4,31), cmd("mc1","COMPUTER","PENDING","DEVICE_LOCK",1)]
ERRORS = [cmd("mm101","MOBILE_DEVICE","ERROR","INSTALL_PROFILE",2,31,"Profile installation failed"), cmd("mc2","COMPUTER","ERROR","INSTALL_PROFILE",3,20,"The payload is invalid")]
REQS = []
ERASES = []
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def j(self,c,o):
        b=json.dumps(o).encode(); self.send_response(c); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        m = re.match(r"^/api/v2/mobile-devices/(\d+)/erase$", self.path)
        if m:   # Wipe with options; only iPad-101 exists.
            if m.group(1) != "101": return self.j(404, {"httpStatus": 404, "errors": []})
            ERASES.append({"path": self.path, "contentType": self.headers.get("Content-Type"), "body": json.loads(body)})
            return self.j(200, {"deviceId": m.group(1), "commandUuid": "erase-uuid"})
        self.j(200,{"token":"t","expires":"2099-01-01T00:00:00Z"})
    def do_GET(self):
        REQS.append(self.path)
        if self.path == "/__reqs": return self.j(200, REQS)
        if self.path == "/__erases": return self.j(200, ERASES)
        u = urllib.parse.urlsplit(self.path); q = urllib.parse.parse_qs(u.query)
        if self.command != "GET": return self.j(405, {})
        if u.path == "/JSSResource/restrictedsoftware": return self.j(403, {})
        if u.path == "/api/v3/computers-inventory": return self.j(404, {})
        if u.path == "/api/v1/computers-inventory":
            page, size = int(q["page"][0]), int(q["page-size"][0])
            assert "DISK_ENCRYPTION" in q.get("section", [])
            return self.j(200, {"totalCount": len(COMPUTERS), "results": COMPUTERS[page*size:(page+1)*size]})
        if u.path == "/api/v2/mobile-devices/detail":
            page, size = int(q["page"][0]), int(q["page-size"][0])
            return self.j(200, {"totalCount": len(MOBILES), "results": MOBILES[page*size:(page+1)*size]})
        if u.path == "/api/v2/mdm/commands":
            f = q.get("filter", [""])[0]
            if f == "status==Pending": return self.j(200, {"totalCount": len(PENDING), "results": PENDING})
            if f == "status==Error": return self.j(200, {"totalCount": len(ERRORS), "results": ERRORS})
            return self.j(400, {"errors": ["bad filter " + f]})
        if self.path in D: return self.j(200, D[self.path])
        self.j(404, {})
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 18446), H)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain(sys.argv[1] + "/cert.pem", sys.argv[1] + "/key.pem"); srv.socket = c.wrap_socket(srv.socket, server_side=True); srv.serve_forever()
