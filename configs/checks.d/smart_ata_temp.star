# Translated from Checkmk check: smart_ata_temp
# Monitors the temperature of ATA hard drives.
# Source data is gathered by running `smartctl` directly on the host,
# replicating the data the Checkmk agent plugin would parse.

# The threshold levels from the Checkmk plugin's default parameters
# check_default_parameters={"levels": (35.0, 40.0)}
DEFAULT_TEMP_WARN = 35.0
DEFAULT_TEMP_CRIT = 40.0


def _parse_smartctl_json(stdout):
    """Parses the JSON output of `smartctl -a /dev/sdX -j`.
    Returns the parsed structure or None if invalid/empty."""
    if not stdout or not stdout.strip():
        return None
    return json.decode(stdout)


def _get_temp_and_name(ctx, device):
    """Queries a single device for temperature and model name.
    Returns a tuple (temperature_c, model_name) or (None, None) on failure."""
    res = ctx.run(
        ["smartctl", "-a", device, "-j"],
        mutates=False,
    )
    if res.rc != 0:
        return None, None
    data = _parse_smartctl_json(res.stdout)
    if data == None:
        return None, None
    temp_data = data.get("temperature", {})
    if type(temp_data) != "dict":
        return None, None
    current_temp = temp_data.get("current")
    if current_temp == None or (type(current_temp) != "int" and type(current_temp) != "float"):
        return None, None
    model = data.get("model_name", "")
    return float(current_temp), str(model)


def main(ctx, params):
    if params.get("_discover"):
        # ---------------------------------------------------------------
        # DISCOVERY MODE
        # Replicates discovery_smart_ata_temp by scanning for ATA devices
        # that report a temperature via smartctl.
        # ---------------------------------------------------------------

        probe = ctx.run(["smartctl", "--scan"], mutates=False)
        if probe.rc == 127 or not probe.stdout.strip():
            return {"changed": False, "msg": "no smartctl found; nothing discovered",
                    "data": {"discovery": []}}

        discovery = []
        for line in probe.stdout.splitlines():
            if not line.strip():
                continue
            device = line.split()[0]
            res = ctx.run(["smartctl", "-i", device, "-j"], mutates=False)
            if res.rc != 0:
                continue
            info = _parse_smartctl_json(res.stdout)
            if info == None:
                continue
            dev_type = info.get("device", {})
            if type(dev_type) != "dict":
                continue
            if dev_type.get("type", "") != "ata":
                continue

            temp, model = _get_temp_and_name(ctx, device)
            if temp != None:
                discovery.append({
                    "item": device,
                    "params": {"warn": DEFAULT_TEMP_WARN, "crit": DEFAULT_TEMP_CRIT},
                    "metrics": ["temperature"],
                    "service_labels": {
                        "cmk/smart/type": "ATA",
                        "cmk/smart/device": device,
                        "cmk/smart/model": model,
                    },
                })

        return {"changed": False, "msg": "discovered %d ATA temperature sensors" % len(discovery),
                "data": {"discovery": discovery}}

    # ---------------------------------------------------------------
    # CHECK MODE (single item)
    # Replicates check_smart_ata_temp using check_temperature logic.
    # ---------------------------------------------------------------
    item = params.get("item", "")

    probe = ctx.run(["smartctl", "--version"], mutates=False)
    if probe.rc == 127:
        return {"changed": False,
                "msg": "smartctl not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "smartctl is not installed"}}

    temp, model = _get_temp_and_name(ctx, item)
    if temp == None:
        return {"changed": False,
                "msg": "no readable temperature for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "device did not report a temperature"}}

    warn = params.get("warn", DEFAULT_TEMP_WARN)
    crit = params.get("crit", DEFAULT_TEMP_CRIT)

    state = "OK"
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"

    metric_val = temp
    msg = "%s: %f C (model: %s)" % (item, temp, model) if model else "%s: %f C" % (item, temp)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temperature": metric_val}, "details": ""}}