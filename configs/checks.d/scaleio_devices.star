def _make_state_readable(raw_state):
    return raw_state.replace("_", " ").lower()

def _parse_scli_output(stdout):
    devices = {}
    current_id = ""
    for line in stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        key = parts[0]
        value = parts[1]
        if key == "DEVICE":
            current_id = value.rstrip(":")
            devices[current_id] = {"DEVICE": current_id}
        elif current_id != "" and key in ("ID", "SDS_ID", "STORAGE_POOL_ID", "STATE", "ERR_STATE"):
            devices[current_id][key] = value

    parsed = {}
    for attrs in devices.values():
        sds_id = attrs.get("SDS_ID", "")
        if sds_id == "":
            continue
        if sds_id not in parsed:
            parsed[sds_id] = []
        parsed[sds_id].append(attrs)
    return parsed

def main(ctx, params):
    mdm_ip = params.get("mdm_ip", "")
    cmd = ["scli", "--query_all_devices", "--approve_certificate"]
    if mdm_ip != "":
        cmd = ["scli", "--mdm_ip", mdm_ip, "--query_all_devices", "--approve_certificate"]

    res = ctx.run(cmd, mutates=False, ok_codes=[0, 1, 2, 3])

    if params.get("_discover"):
        if res.rc != 0:
            return {"changed": False,
                    "msg": "scli failed (rc=%d): %s" % (res.rc, res.stderr),
                    "data": {"discovery": []}}
        section = _parse_scli_output(res.stdout)
        discovery = [
            {"item": sds_id, "params": {}, "metrics": []}
            for sds_id in section
        ]
        return {"changed": False,
                "msg": "discovered %d SDS items" % len(discovery),
                "data": {"discovery": discovery}}

    if res.rc != 0:
        return {"changed": False,
                "msg": "scli failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _parse_scli_output(res.stdout)
    item = params.get("item", "")
    devices = section.get(item)

    if devices == None:
        return {"changed": False,
                "msg": "SDS not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    num_devices = len(devices)
    error_devices = []
    long_output = []

    for device in devices:
        err_state = device.get("ERR_STATE", "n/a")
        if err_state == "NO_ERROR":
            continue
        dev_id = device.get("DEVICE", "n/a")
        state_readable = _make_state_readable(device.get("STATE", "n/a"))
        err_state_readable = _make_state_readable(err_state)
        error_devices.append(dev_id)
        long_output.append(
            "Device %s: Error: %s, State: %s (ID: %s, Storage pool ID: %s)" % (
                dev_id,
                state_readable,
                err_state_readable,
                dev_id,
                device.get("STORAGE_POOL_ID", "n/a"),
            )
        )

    if error_devices:
        state = "CRIT"
        msg = "%d devices, %d errors (%s)" % (
            num_devices, len(error_devices), ", ".join(error_devices))
    else:
        state = "OK"
        msg = "%d devices, no errors" % num_devices

    return {"changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": {}, "details": "\n".join(long_output)}}