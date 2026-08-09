def _tce_state_name(s):
    return {
        "1": "unknown",
        "2": "normal",
        "3": "warning",
        "4": "degraded",
        "5": "faulted",
    }.get(s, "unknown")


def _leo_state_name(s):
    return {
        "0": "higher_than_threshold",
        "1": "normal",
        "2": "lower_than_threshold",
    }.get(s, "unknown")


def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        items = []

        # 5171 platform: CIENA-CHASSIS-MIB
        base5171 = ".1.3.6.1.4.1.1271.2.1.5.1.2.1.4.13.1"
        res5171 = ctx.run([
            "snmpwalk", "-v2c", "-c", community,
            "-Oqn", host, base5171
        ], mutates=False)
        if res5171.rc == 0:
            by_index = {}
            for line in res5171.stdout.splitlines():
                sp = line.find(" ")
                if sp < 0:
                    continue
                oid = line[:sp]
                val = line[sp+1:]
                suffix = oid[len(base5171)+1:]
                if "." not in suffix:
                    continue
                col = oid[len(base5171)+1:].rsplit(".", 1)[0]
                idx = suffix.rsplit(".", 1)[0]
                by_index.setdefault(idx, {})[col] = val
            for idx in sorted(by_index.keys()):
                cols = by_index[idx]
                # OIDEnd gives "subcategory.origin", cols are "3" (state) and "4" (temp)
                parts = idx.split(".")
                if len(parts) < 2:
                    continue
                sensor = parts[0]
                slot = parts[1]
                state = cols.get("3", "1")
                temp = cols.get("4", "")
                if not temp.lstrip("-").isdigit():
                    continue
                items.append({
                    "item": "sensor %s slot %s" % (sensor, slot),
                    "params": {"levels": (70, 80)},
                    "metrics": ["temperature"],
                })

        # 5142 platform: WWP-CHASSIS MIB
        base5142 = ".1.3.6.1.4.1.6141.2.60.11.1.1.5.1.1"
        res5142 = ctx.run([
            "snmpwalk", "-v2c", "-c", community,
            "-Oqn", host, base5142
        ], mutates=False)
        if res5142.rc == 0:
            by_index = {}
            for line in res5142.stdout.splitlines():
                sp = line.find(" ")
                if sp < 0:
                    continue
                oid = line[:sp]
                val = line[sp+1:]
                suffix = oid[len(base5142)+1:]
                col = suffix.rsplit(".", 1)[0]
                idx = suffix.rsplit(".", 1)[-1] if "." in suffix else suffix
                # col is the OID column digit, idx is the table index
                by_index.setdefault(idx, {})[col] = val
            for idx in sorted(by_index.keys()):
                cols = by_index[idx]
                # col "1"=sensor num, "5"=state, "2"=temp value
                state = cols.get("5", "0")
                temp = cols.get("2", "")
                if not temp.lstrip("-").isdigit():
                    continue
                sensor_num = cols.get("1", idx)
                items.append({
                    "item": str(sensor_num),
                    "params": {"levels": (70, 80)},
                    "metrics": ["temperature"],
                })

        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    warn = params.get("warn", 70)
    crit = params.get("crit", 80)

    # 5171 platform
    base5171 = ".1.3.6.1.4.1.1271.2.1.5.1.2.1.4.13.1"
    res5171 = ctx.run([
        "snmpwalk", "-v2c", "-c", community,
        "-Oqn", host, base5171
    ], mutates=False)
    if res5171.rc == 0:
        by_index = {}
        for line in res5171.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = line[sp+1:]
            suffix = oid[len(base5171)+1:]
            if "." not in suffix:
                continue
            col = suffix.rsplit(".", 1)[0]
            idx = suffix.rsplit(".", 1)[0]
            by_index.setdefault(idx, {})[col] = val
        for idx in sorted(by_index.keys()):
            cols = by_index[idx]
            parts = idx.split(".")
            if len(parts) < 2:
                continue
            sensor = parts[0]
            slot = parts[1]
            desc = "sensor %s slot %s" % (sensor, slot)
            if desc != item:
                continue
            temp_str = cols.get("4", "")
            state_str = cols.get("3", "1")
            if not temp_str.lstrip("-").isdigit():
                return {
                    "changed": False,
                    "msg": "no valid temperature for %s" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
                }
            temp = int(temp_str)
            dev_status_name = _tce_state_name(state_str)
            dev_status = 0 if state_str == "2" else 2
            state = "CRIT" if temp >= crit else ("WARN" if temp >= warn else "OK")
            if dev_status == 2 and dev_status_name == "warning":
                if state == "OK" or state == "WARN":
                    state = "WARN"
            if dev_status == 2 and dev_status_name in ("faulted", "degraded"):
                state = "CRIT"
            return {
                "changed": False,
                "msg": "%s: %d C (status: %s)" % (item, temp, dev_status_name),
                "data": {
                    "state": state,
                    "metrics": {"temperature": temp},
                    "details": "Dev status: %s" % dev_status_name,
                },
            }

    # 5142 platform
    base5142 = ".1.3.6.1.4.1.6141.2.60.11.1.1.5.1.1"
    res5142 = ctx.run([
        "snmpwalk", "-v2c", "-c", community,
        "-Oqn", host, base5142
    ], mutates=False)
    if res5142.rc == 0:
        by_index = {}
        for line in res5142.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = line[sp+1:]
            suffix = oid[len(base5142)+1:]
            col = suffix.rsplit(".", 1)[0]
            idx = suffix.rsplit(".", 1)[-1] if "." in suffix else suffix
            by_index.setdefault(idx, {})[col] = val
        for idx in sorted(by_index.keys()):
            cols = by_index[idx]
            sensor_num = cols.get("1", idx)
            if str(sensor_num) != item:
                continue
            temp_str = cols.get("2", "")
            state_str = cols.get("5", "0")
            if not temp_str.lstrip("-").isdigit():
                return {
                    "changed": False,
                    "msg": "no valid temperature for %s" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
                }
            temp = int(temp_str)
            dev_status_name = _leo_state_name(state_str)
            dev_status = 0 if state_str == "1" else 2
            state = "CRIT" if temp >= crit else ("WARN" if temp >= warn else "OK")
            if dev_status == 2 and dev_status_name == "higher_than_threshold":
                if state == "OK":
                    state = "WARN"
            if dev_status == 2 and dev_status_name == "lower_than_threshold":
                if state == "OK":
                    state = "WARN"
            return {
                "changed": False,
                "msg": "%s: %d C (status: %s)" % (item, temp, dev_status_name),
                "data": {
                    "state": state,
                    "metrics": {"temperature": temp},
                    "details": "Dev status: %s" % dev_status_name,
                },
            }

    return {
        "changed": False,
        "msg": "no ciena temperature sensor found for item %s" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }