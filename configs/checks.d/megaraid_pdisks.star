def main(ctx, params):
    if params.get("_discover"):
        pd = _gather_pdisks(ctx)
        if len(pd) == 0:
            return {"changed": False, "msg": "no megaraid physical disks found",
                    "data": {"discovery": [], "host_labels": {}}}

        discovery = []
        seen = {}
        for item in sorted(pd.keys()):
            if not item.startswith("/c"):
                continue
            disk = pd[item]
            seen[disk["name"]] = True
            discovery.append({"item": item,
                               "params": {"levels": {disk["state"]: 0}},
                               "metrics": [],
                               "service_labels": {"state": disk["state"],
                                                   "inquiry": disk["name"]}})

        labels = {}
        labels["cmk/vendor"] = "broadcom"
        labels["cmk/product"] = "megaraid"
        return {"changed": False, "msg": "discovered %d physical disks" % len(discovery),
                "data": {"discovery": discovery, "host_labels": labels}}

    item = params.get("item", "")
    pd = _gather_pdisks(ctx)
    if len(pd) == 0:
        return {"changed": False, "msg": "no megaraid physical disks found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    disk = pd.get(item)
    if disk == None:
        return {"changed": False, "msg": "no such megaraid physical disk: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_map = dict(_FIXED_STATES)
    for key, value in params.get("levels", {}).items():
        state_map[_expand_abbreviation(key)] = value

    verdict = state_map.get(disk["state"], 3)
    if verdict >= 2:
        st = "CRIT"
    elif verdict >= 1:
        st = "WARN"
    else:
        st = "OK"

    details = "State: %s" % disk["state"]
    if disk["name"] != item:
        details = details + "\nName: %s" % disk["name"]
    if disk["failures"] != None:
        details = details + "\nPredictive fail count: %d" % disk["failures"]

    msg = disk["state"]
    if disk["failures"] != None and disk["failures"] > 0:
        msg = msg + ", pfail=%d" % disk["failures"]

    return {"changed": False, "msg": msg,
            "data": {"state": st, "metrics": {}, "details": details}}


_NORMALIZE_STATE = {
    "Unconfigured(good)": "Unconfigured Good",
    "Unconfigured(bad)": "Unconfigured Bad",
}

_FIXED_STATES = {
    "Hotspare": 0,
    "JBOD": 0,
    "Failed": 2,
    "Copyback": 1,
    "Rebuild": 1,
}

_ABBREV_MAP = {
    "UGood": "Unconfigured Good",
    "UBad": "Unconfigured Bad",
    "GHS": "Global Hotspare",
    "GNO": "Global No",
    "OSDI": "OS Drive",
    "OSDC": "OS Drive Critical",
    "MSR": "Media Shadow Reserve",
    "MSD": "Media Shadow Dirty",
}


def _expand_abbreviation(key):
    expanded = _ABBREV_MAP.get(key)
    if expanded != None:
        return expanded
    normalized = _NORMALIZE_STATE.get(key)
    if normalized != None:
        return normalized
    return key


def _gather_pdisks(ctx):
    mega = ctx.run(["/usr/sbin/megacli", "-PDList", "-aALL"], mutates=False)
    if mega.rc == 127 or (mega.rc != 0 and len(mega.stdout) == 0):
        storcli = ctx.run(["/usr/bin/storcli", "/cALL/eALL/sALL", "show"], mutates=False)
        if storcli.rc == 127 or (storcli.rc != 0 and len(storcli.stdout) == 0):
            return {}
        return _parse_storcli(storcli.stdout)

    if mega.rc != 0:
        return {}

    return _parse_megacli(mega.stdout, ctx)


def _parse_megacli(output, ctx):
    pd = {}
    adapters = {0: {}}
    current_adapter = adapters[0]
    adapter = 0
    enclosure_devid = 0
    predictive_failure_count = None
    slot = None
    firmware_state = None
    inquiry_data = None

    lines = output.splitlines()
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        stripped = line.strip()

        if stripped.startswith("Adapter "):
            parts = stripped.split()
            if len(parts) >= 2:
                cur_adapter = parts[1]
                if cur_adapter.startswith("#"):
                    adapter = int(cur_adapter[1:])
                    if adapter not in adapters:
                        adapters[adapter] = {}
                    current_adapter = adapters[adapter]
        elif stripped.startswith("Enclosure Device ID:"):
            parts = stripped.split(":")
            if len(parts) >= 2:
                val = parts[1].strip()
                if val.isdigit():
                    enclosure_devid = int(val)
                    current_adapter[enclosure_devid] = enclosure_devid
                else:
                    enclosure_devid = 0
                    current_adapter[0] = 0
        elif stripped.startswith("Slot Number:"):
            parts = stripped.split(":")
            if len(parts) >= 2:
                val = parts[1].strip()
                if val.isdigit():
                    slot = int(val)
        elif stripped.startswith("Firmware state:"):
            parts = stripped.split(":", 1)
            if len(parts) >= 2:
                firmware_state = parts[1].strip().rstrip(",")
        elif stripped.startswith("Inquiry Data:"):
            parts = stripped.split(":", 1)
            if len(parts) >= 2:
                inquiry_data = parts[1].strip()
                name = inquiry_data.strip()
                state = firmware_state
                if state == None:
                    state = "unknown"
                disk = _make_pdisk(name, state, predictive_failure_count)
                enclosure = current_adapter.get(enclosure_devid, enclosure_devid)
                item = "/c%d/e%d/s%d" % (adapter, enclosure, slot)
                pd[item] = disk
                legacy_item = "%s%d/%d" % (_legacy_adapter_letter(adapter), enclosure, slot)
                pd[legacy_item] = disk
                predictive_failure_count = None
                firmware_state = None
                inquiry_data = None
        elif stripped.startswith("Predictive Failure Count:"):
            parts = stripped.split(":")
            if len(parts) >= 2:
                val = parts[1].strip()
                if val.isdigit():
                    predictive_failure_count = int(val)

        i = i + 1

    return pd


def _legacy_adapter_letter(idx):
    letters = ["e", "f", "g", "h", "i", "j", "k", "l"]
    if idx < len(letters):
        return letters[idx]
    return "e"


def _make_pdisk(name, state, failures):
    return {"name": name, "state": _NORMALIZE_STATE.get(state, state),
            "failures": failures}


def _parse_storcli(output):
    pd = {}
    lines = output.splitlines()
    for line in lines:
        stripped = line.strip()
        if stripped == "" or stripped.startswith("TOPOLOGY") or stripped.startswith("---") \
                or stripped.startswith("DriveState") or stripped.startswith("Properties"):
            continue
        parts = stripped.split()
        if len(parts) < 4:
            continue
        if parts[0].startswith("/c") and parts[0].endswith("/s") or "/e" in parts[0]:
            item = parts[0]
            continue
    return pd