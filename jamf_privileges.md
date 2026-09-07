# Jamf Toolbox — Required Jamf Pro Privileges

This lists the Jamf Pro account privileges each Jamf Toolbox action needs.
Because the app is used by multiple people, the recommended setup is:

- Give each operator their **own Jamf user account** (personal credential,
  per-person audit trail, no shared secret).
- Put those accounts in **one Jamf group** and grant the privileges below to
  the group, so you configure it once instead of per person.

The app authenticates by exchanging the user's name and password for a
short-lived Bearer token (`/api/v1/auth/token`) and uses that token for every
call — so the accounts must be allowed to obtain a token. If you use SSO,
confirm the accounts can still authenticate to `/api/v1/auth/token` directly;
if not, use local Jamf or LDAP accounts for API access.

Privilege names vary slightly between Jamf Pro versions. If an action returns
**HTTP 403**, the message names the endpoint — match it to the row below and
add the missing privilege.

---

## Minimum (everyone needs these)

The app can't do anything without reading device records, and the token
exchange must be allowed.

| Privilege | Type | Why |
|---|---|---|
| Read Computers | Objects | Search, Show Info, and details for computers |
| Read Mobile Devices | Objects | Search, Show Info, and details for mobile devices |

Reading is enough for: **Search / Add to list**, **Refresh info**,
**Show Info**, **Open in Jamf Pro**, and supplying the Wi-Fi MAC that
**Network Info** (Meraki) looks up.

---

## Per-action privileges

Add these on top of the minimum, for the actions your team will actually use.

### Rename Device — mobile
| Privilege | Type |
|---|---|
| Read Mobile Devices | Objects |
| Send Mobile Device Set Device Name Command | Jamf Pro Server Actions |
| Send Mobile Device Remote Command to Mobile Devices | Jamf Pro Server Actions |

The rename now goes through the modern MDM commands endpoint
(`POST /api/v2/mdm/commands`, `SETTINGS` / `deviceName`), which reads the
device's managementId from `/api/v2/mobile-devices/{id}/detail`. Some Jamf
versions also require **Create Mobile Devices** for the set-name command —
add it if rename returns 403 after the two above.

### Rename Device — computer
| Privilege | Type |
|---|---|
| Update Computers | Objects |
| Send Computer Remote Command to Download and Install macOS Update, or the "Send Computer Set Name" / MDM command privilege in your version | Jamf Pro Server Actions |

Computer rename updates the record name (needs **Update Computers**) and then
sends `SET_COMPUTER_NAME` via `/api/v2/mdm/commands`, reading managementId
from `/api/v1/computers-inventory-detail/{id}`.

### Lock Device — mobile
| Privilege | Type |
|---|---|
| Send Mobile Device Lock Command | Jamf Pro Server Actions |

### Lock Device — computer
| Privilege | Type |
|---|---|
| Send Computer Remote Lock Command | Jamf Pro Server Actions |

### Toggle Lost Mode — mobile only
| Privilege | Type |
|---|---|
| Send Mobile Device Lost Mode Command | Jamf Pro Server Actions |
| Send Mobile Device Disable Lost Mode Command | Jamf Pro Server Actions |
| Read Mobile Devices | Objects |

Some versions expose these as a single "Lost Mode" command privilege; grant
whichever your version shows. Lost Mode also requires the device to be
**supervised** — a Jamf setting on the device, not an account privilege.

Disabling Lost Mode (and enabling it, on servers that have removed the
classic command) goes through the modern MDM endpoint
(`POST /api/v2/mdm/commands`), which reads the device's managementId from
`/api/v2/mobile-devices/{id}/detail` — hence the Read privilege above and
the same MDM command privilege used by rename.

### Update Inventory — mobile only
| Privilege | Type |
|---|---|
| Send Mobile Device Update Inventory Command (a.k.a. Send Inventory Requests to Mobile Devices) | Jamf Pro Server Actions |

(There is no computer equivalent — a Mac reports inventory by running its own
`jamf recon`, so the app doesn't offer this for computers.)

---

## Endpoint → privilege quick reference

For matching a 403 error to a privilege:

| Endpoint the app calls | Needs |
|---|---|
| `POST /api/v1/auth/token` | account allowed to get a token |
| `GET /JSSResource/computers/match/…` | Read Computers |
| `GET /JSSResource/computers/id/…` | Read Computers |
| `GET /JSSResource/mobiledevices/match/…` | Read Mobile Devices |
| `GET /JSSResource/mobiledevices/id/…` | Read Mobile Devices |
| `PUT /JSSResource/computers/id/…` | Update Computers |
| `GET /api/v1/computers-inventory-detail/…` | Read Computers |
| `GET /api/v2/mobile-devices/…/detail` | Read Mobile Devices |
| `POST /api/v2/mdm/commands` (SETTINGS / SET_COMPUTER_NAME) | the matching Send … Command privilege above |
| `POST /JSSResource/mobiledevicecommands/command` (lock, lost mode, inventory) | the matching Send Mobile Device … Command |
| `POST /JSSResource/computercommands/command` (lock) | Send Computer Remote Lock Command |

---

## A safe starting group

If you want one privilege set that enables every current feature, grant the
group:

- Read Computers, Update Computers
- Read Mobile Devices *(add Create Mobile Devices only if mobile rename 403s)*
- Send Computer Remote Lock Command
- Send Mobile Device Lock Command
- Send Mobile Device Set Device Name Command
- Send Mobile Device Remote Command to Mobile Devices
- Send Mobile Device Lost Mode Command
- Send Mobile Device Disable Lost Mode Command
- Send Mobile Device Update Inventory Command
- The MDM command privilege your version uses for `/api/v2/mdm/commands`

Grant only the rows for actions your team should be able to perform — e.g.
omit the Lock privileges if front-line staff shouldn't lock devices. Because
each person signs in as themselves, Jamf's logs will show who did what.

---

## Meraki (separate system)

**Network Info** talks to the Meraki Dashboard, not Jamf, so it needs no Jamf
privileges. It uses the Meraki API key from Settings → Meraki, which should be
generated from a Meraki account with **read-only** organization access (client
lookups only read data). That key is also a shared secret if distributed, so
the same caution applies — prefer a read-only key.

---

## Command types this app sends (Jamf Pro 11.x)

Modern MDM commands go to `POST /api/v2/mdm/commands` with a `managementId`
read from the device's detail endpoint. Command types confirmed available on
Jamf Pro 11.x:

| App action | commandType |
|---|---|
| Rename (mobile and computer) | `SETTINGS` (+ `deviceName`) |
| Lock Device (mobile) | `DEVICE_LOCK` |
| Lock Device (computer) | `DEVICE_LOCK` (+ `pin`) |
| Update Inventory (mobile) | `DEVICE_INFORMATION` |
| Enable Lost Mode | `ENABLE_LOST_MODE` |
| Lost Mode sound | `PLAY_LOST_MODE_SOUND` |
| Disable Lost Mode | `DISABLE_LOST_MODE` |

The classic `mobiledevicecommands` / `computercommands` endpoints are kept
only as a fallback for older servers; current Jamf Pro versions reject
several of these commands with HTTP 400 "Invalid command".
