# Cisco Meraki org wireless device statuses - bands (Radio %s)
# Translates the Checkmk agent-based check_plugin for the "cisco_meraki_org_wireless_device_statuses_bands"
# check into a read-only Starlark check module for the yolo-man agent.
#
# This check is SNMP/Cloud-API driven in Checkmk (a special/datasource agent provides the
# <<<cisco_meraki_org_wireless_device_statuses>>> section). Since the on-host agent here has no
# Checkmk and no Meraki datasource special agent, the data must be fetched from the Meraki
# Management API over the network, keyed by the organization + network + device.
#
# The module is READ-ONLY: it never mutates the system, always reports changed=False.

_ORG_WIRELESS_BASE = "https://api.meraki.com/api/v1/organizations"
_MHZ_TO_HZ = 1000000


def _strip_type_and_quotes(raw):
    # Remove a leading "<TYPE>: " prefix (SNMP) and surrounding quotes, if present.
    s = raw
    if s.startswith("STRING: ") or s.startswith("INTEGER: ") or s.startswith("OID: "):
        s = s.split(": ", 1)[1]
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        s = s[1:-1]
    return s


def _parse_ssid_entry(raw):
    # Parse one basicServiceSet dict from Meraki JSON into the normalized form.
    band = raw.get("band", "")
    channel = raw.get("channel")
    channel_width = raw.get("channelWidth")
    power = raw.get("power")
    broadcasting = raw.get("broadcasting", False)
    visible = raw.get("visible", False)

    cw_val = None
    if channel_width != None:
        parts = channel_width.split()
        if len(parts) > 0 and parts[0].lstrip("-").isdigit():
            cw_val = int(parts[0]) * _MHZ_TO_HZ

    pw_val = None
    if power != None:
        parts = power.split()
        if len(parts) > 0 and parts[0].lstrip("-").isdigit():
            pw_val = int(parts[0])

    return {
        "band": band,
        "channel": channel,
        "channel_width": channel_width,
        "power": power,
        "broadcasting": broadcasting,
        "visible": visible,
        "normalized_channel_width": cw_val,
        "normalized_power": pw_val,
    }


def _fetch_meraki_statuses(ctx, host, org_id, network_id, serial, api_key):
    # Query the Meraki API for the wireless device status payload.
    # Meraki does not expose per-device SSID/BSS via a single endpoint in the
    # free-tier; this mirrors the special-agent data the Checkmk plugin expects:
    # a JSON array whose first element contains {"basicServiceSets": [...]}.
    url = "%s/%s/wireless/controller/%s/statuses?serial=%s" % (
        _ORG_WIRELESS_BASE, org_id, network_id, serial
    )
    res = ctx.run(
        ["curl", "-sS", "-m", "15", "-H", "X-Cisco-Meraki-API-Key: " + api_key, url],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        # No data: treat as not installed / unreachable here.
        return None
    return res.stdout


def _build_section(ctx, params):
    # Build the in-memory Section (WirelessDeviceStatusInfo equivalent) from the Meraki API.
    host = params.get("host", "api.meraki.com")
    org_id = params.get("org_id")
    network_id = params.get("network_id")
    serial = params.get("serial")
    api_key = params.get("api_key")

    if org_id == None or network_id == None or serial == None or api_key == None:
        return None

    payload = _fetch_meraki_statuses(ctx, host, org_id, network_id, serial, api_key)
    if payload == None:
        return None

    # The Checkmk section holds a single JSON document as one string.
    decoded = json.decode(payload)
    if type(decoded) == "list" and len(decoded) > 0:
        status = decoded[0]
    elif type(decoded) == "dict":
        status = decoded
    else:
        return None

    bss = status.get("basicServiceSets", [])
    ssids = {}
    bands = {}
    for raw in bss:
        if type(raw) != "dict":
            continue
        entry = _parse_ssid_entry(raw)
        if entry["band"] != "":
            bands[entry["band"]] = entry
        # Use the SSID name/number as the SSID item key when available.
        name = raw.get("ssidName", raw.get("ssid_number", ""))
        if name != "":
            ssids[name] = entry
    return {"ssids": ssids, "bands": bands}


def main(ctx, params):
    # DISCOVERY MODE
    if params.get("_discover"):
        section = _build_section(ctx, params)
        if section == None:
            return {"changed": False, "msg": "no Meraki wireless data available",
                    "data": {"discovery": []}}
        out = []
        for band in section["bands"]:
            out.append({"item": band, "params": {}, "metrics": ["channel", "channel_width", "signal_power"]})
        return {"changed": False, "msg": "discovered %d radios" % len(out),
                "data": {"discovery": out}}

    # CHECK MODE for one band item
    item = params.get("item", "")
    section = _build_section(ctx, params)
    if section == None:
        return {"changed": False, "msg": "no Meraki wireless data available for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ssid = section["bands"].get(item)
    if ssid == None:
        return {"changed": False, "msg": "no such radio band: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Reproduce the check's summaries (all OK in the source).
    detail_lines = [
        "Channel: %s" % (ssid["channel"] if ssid["channel"] != None else ""),
        "Channel width: %s" % (ssid["channel_width"] if ssid["channel_width"] != None else ""),
        "Power: %s" % (ssid["power"] if ssid["power"] != None else ""),
        "Broadcasting: %s" % ssid["broadcasting"],
    ]
    summary = "; ".join(detail_lines)

    metrics = {}
    if ssid["channel"] != None:
        metrics["channel"] = ssid["channel"]
    if ssid["normalized_channel_width"] != None:
        metrics["channel_width"] = ssid["normalized_channel_width"]
    if ssid["normalized_power"] != None:
        metrics["signal_power"] = ssid["normalized_power"]

    return {"changed": False, "msg": summary,
            "data": {"state": "OK", "metrics": metrics, "details": summary}}