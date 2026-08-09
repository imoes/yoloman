def parse_timestamp(elem):
    # find "YYYY-MM-DD HH:MM:SS" without regex
    for i in range(len(elem) - 18):
        cand = elem[i:i + 19]
        ok = True
        sep = [4, 7, 10, 13, 16]
        digits = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
        for d in digits:
            if cand[d] not in "0123456789":
                ok = False
                break
        if not ok:
            continue
        if (cand[4] == "-" and cand[7] == "-" and cand[10] == " "
                and cand[13] == ":" and cand[16] == ":"):
            return cand
    return None


def parse_server_node(elem):
    idx = elem.find("SERVERNODE=")
    if idx < 0:
        return None
    rest = elem[idx + 11:]
    end = len(rest)
    for tag in (",SERVERDB", ",UID", ",PWD"):
        p = rest.find(tag)
        if p >= 0 and p < end:
            end = p
    return rest[:end]


def parse_sap_hana(string_table):
    parsed = {}
    cur_sid = None
    cur_lines = []
    for row in string_table:
        for cell in row:
            cur_lines.append(cell)
        # Heuristic: a line starting with SID/INSTANCE context ends the block.
    # The real Checkmk parser groups raw lines by SID/INSTANCE; we emulate by
    # splitting on lines containing typical header markers.
    groups = {}
    cur_key = None
    cur_vals = []
    for row in string_table:
        for cell in row:
            if cell.startswith("SID") or cell.startswith("INSTANCE"):
                if cur_key != None:
                    groups[cur_key] = cur_vals
                cur_key = cell
                cur_vals = [cell]
            elif cur_key != None:
                cur_vals.append(cell)
    if cur_key != None:
        groups[cur_key] = cur_vals
    # Fall back: single group if no recognizable header
    if not groups:
        all_vals = []
        for row in string_table:
            for cell in row:
                all_vals.append(cell)
        groups["default"] = all_vals
    return groups


_SAP_HANA_CONNECT_STATE_MAP = {
    "Worker: OK": lambda inp: inp == "0",
    "Standby: OK": lambda inp: inp == "1",
    "No connect": lambda inp: inp not in ("0", "1"),
}


_STATE_OK = 0
_STATE_WARN = 1
_STATE_CRIT = 2
_STATE_UNKNOWN = 3


def state_to_str(s):
    return {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}.get(s, "UNKNOWN")


def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real data source: the hdbsql binary.
        probe = ctx.run(["hdbsql", "-version"], mutates=False)
        if probe.rc == 127:
            return {"changed": False, "msg": "hdbsql not installed",
                    "data": {"discovery": []}}
        # Gather connect data via hdbsql if available
        res = ctx.run(["hdbsql", "-host", "localhost", "-port", "30015",
                       "-j", "SELECT NOW()"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no SAP HANA connect data",
                    "data": {"discovery": []}}
        parsed = parse_sap_hana_connect_text(res.stdout)
        out = []
        for sid in parsed:
            out.append({"item": sid, "params": {}, "metrics": []})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["hdbsql", "-host", "localhost", "-port", "30015",
                   "-j", "SELECT NOW()"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "hdbsql unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parsed = parse_sap_hana_connect_text(res.stdout)
    if item not in parsed:
        return {"changed": False, "msg": "no such instance: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = parsed[item]
    details = ("ODBC Driver Version: %s, Server Node: %s, Timestamp: %s" %
               (data["driver_version"], data["server_node"], data["timestamp"]))
    return {"changed": False,
            "msg": data["message"],
            "data": {"state": state_to_str(data["cmk_state"]),
                     "metrics": {}, "details": details}}


def parse_sap_hana_connect_text(text):
    string_table = []
    for line in text.splitlines():
        if line.strip():
            string_table.append([line.strip()])
    groups = parse_sap_hana(string_table)
    parsed = {}
    for sid_instance, lines in groups.items():
        inst = parsed.setdefault(
            sid_instance,
            {"server_node": "not found", "driver_version": "not found",
             "timestamp": "not found", "cmk_state": _STATE_UNKNOWN,
             "message": " ".join(lines[0]) if lines else ""})
        for elem in lines:
            if "retcode" in elem:
                rc = elem.split("retcode")[1].lstrip(": ").split(",")[0].strip()
                for k, evaluator in _SAP_HANA_CONNECT_STATE_MAP.items():
                    if evaluator(rc):
                        inst["cmk_state"] = {"Worker: OK": _STATE_OK,
                                             "Standby: OK": _STATE_OK,
                                             "No connect": _STATE_CRIT}.get(k, _STATE_UNKNOWN)
                        inst["message"] = k
                        break
            if "Driver version" in elem:
                inst["driver_version"] = elem.split("Driver version")[1].lstrip()
            if "Connect string:" in elem:
                sn = parse_server_node(elem)
                if sn != None:
                    inst["server_node"] = sn
            if "Select now()" in elem:
                ts = parse_timestamp(elem)
                if ts != None:
                    inst["timestamp"] = ts
    return parsed