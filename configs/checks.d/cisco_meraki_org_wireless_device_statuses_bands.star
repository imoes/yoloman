def main(ctx, params):
    # Agent data is expected to be in /var/lib/check-mk-agent/cache/cisco_meraki_org_wireless_device_statuses
    cache_path = "/var/lib/check-mk-agent/cache/cisco_meraki_org_wireless_device_statuses"

    if not ctx.file_exists(cache_path):
        return {
            "changed": False,
            "msg": "Agent cache not found: " + cache_path,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    content = ctx.file_read(cache_path)
    if not content.strip():
        return {
            "changed": False,
            "msg": "Agent cache empty: " + cache_path,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Guard before decoding: ensure non-empty string
    if not content:
        return {
            "changed": False,
            "msg": "Agent cache content empty",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Decode JSON — assume well-formed per Checkmk agent spec
    data = json.decode(content)

    # Expect: [[payload]] where payload is a JSON array with one device status object
    if not isinstance(data, list) or len(data) != 1 or not isinstance(data[0], list) or len(data[0]) != 1:
        return {
            "changed": False,
            "msg": "Unexpected agent data format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    payload_str = data[0][0]
    if not isinstance(payload_str, str) or not payload_str:
        return {
            "changed": False,
            "msg": "Payload is empty or not a string",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    payload = json.decode(payload_str)
    if not isinstance(payload, list) or len(payload) != 1:
        return {
            "changed": False,
            "msg": "Payload must contain exactly one device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    device = payload[0]
    if not isinstance(device, dict):
        return {
            "changed": False,
            "msg": "Device entry is not a JSON object",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract basicServiceSets (list of SSID objects)
    bss_list = device.get("basicServiceSets")
    if not isinstance(bss_list, list) or len(bss_list) == 0:
        return {
            "changed": False,
            "msg": "No basicServiceSets found in device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Map band -> first BasicServiceSet with that band (Checkmk logic)
    bands_map = {}
    for ssid in bss_list:
        if not isinstance(ssid, dict):
            continue
        band = ssid.get("band")
        if isinstance(band, str) and band not in bands_map:
            bands_map[band] = ssid

    # DISCOVERY MODE
    if params.get("_discover"):
        out = []
        for band in sorted(bands_map.keys()):
            ssid = bands_map[band]
            metrics = ["channel", "channel_width", "signal_power"]
            out.append({"item": band, "params": {}, "metrics": metrics})
        return {
            "changed": False,
            "msg": "discovered %d radios" % len(out),
            "data": {"discovery": out}
        }

    # CHECK MODE
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    ssid = bands_map.get(item)
    if ssid == None:
        return {
            "changed": False,
            "msg": "band %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract fields
    channel = ssid.get("channel")
    channel_width = ssid.get("channelWidth")
    power = ssid.get("power")
    broadcasting = ssid.get("broadcasting")

    # Normalize channel_width (e.g., "20 MHz" -> 20000000)
    channel_width_norm = None
    if isinstance(channel_width, str):
        parts = channel_width.split()
        if len(parts) >= 2 and parts[0].isdigit():
            channel_width_norm = int(parts[0]) * 1000000

    # Normalize power (e.g., "100 mW" -> 100)
    power_norm = None
    if isinstance(power, str):
        parts = power.split()
        if len(parts) >= 2 and parts[0].isdigit():
            power_norm = int(parts[0])

    # Build output
    msg_parts = []
    metrics = {}
    details = ""

    if isinstance(channel, int):
        msg_parts.append("Channel: %d" % channel)
        metrics["channel"] = channel

    if isinstance(channel_width, str):
        msg_parts.append("Channel width: %s" % channel_width)
        if channel_width_norm != None:
            metrics["channel_width"] = channel_width_norm

    if isinstance(power, str):
        msg_parts.append("Power: %s" % power)
        if power_norm != None:
            metrics["signal_power"] = power_norm

    if isinstance(broadcasting, bool):
        details += "Broadcasting: %s" % broadcasting

    summary = ", ".join(msg_parts) if msg_parts else "No radio data"
    if details:
        summary += " | " + details

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": ""
        }
    }