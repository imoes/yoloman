# Starlark module: mcdata_fcport check (read-only, SNMP-based)
# Translated from Checkmk plugin: cmk.plugins.brocade.mcdata_fcport

# Mappings defined at module top level (as required)
mcdata_fcport_speedbits = {"2": 1000000000, "3": 2000000000}
mcdata_fcport_opstatus = {"1": "1", "2": "2", "3": "testing", "4": "faulty"}

def _bin_to_64(bin_):
    # Convert list of integers (big-endian base-265) to int without using ** or try/except
    total = 0
    base = 265
    n = len(bin_)
    for i in range(n):
        idx = n - 1 - i
        b = int(bin_[idx])
        power = 1
        for _ in range(i):
            power = power * base
        total = total + b * power
    return total

def _line_to_interface(line):
    # Extract and parse fields from the SNMP line
    idx = "%d" % int(str(line[0]))
    opStatus = str(line[1]) if line[1] != None else ""
    speed = str(line[2]) if line[2] != None else ""
    txWords64 = line[3] if line[3] != None else []
    rxWords64 = line[4] if line[4] != None else []
    txFrames64 = line[5] if line[5] != None else []
    rxFrames64 = line[6] if line[6] != None else []
    c3Discards64 = line[7] if line[7] != None else []
    crcs = str(line[8]) if line[8] != None else ""

    # Compute counters
    in_octets = _bin_to_64(rxWords64) * 4
    in_ucast = _bin_to_64(rxFrames64)
    in_err = int(crcs) if crcs.isdigit() else 0
    out_octets = _bin_to_64(txWords64) * 4
    out_ucast = _bin_to_64(txFrames64)
    out_disc = _bin_to_64(c3Discards64)

    speed_val = mcdata_fcport_speedbits.get(speed, 0)
    oper_status = mcdata_fcport_opstatus.get(opStatus, "unknown")

    return {
        "index": idx,
        "descr": idx,
        "alias": idx,
        "type": "6",
        "speed": speed_val,
        "oper_status": oper_status,
        "in_octets": in_octets,
        "in_ucast": in_ucast,
        "in_err": in_err,
        "out_octets": out_octets,
        "out_ucast": out_ucast,
        "out_disc": out_disc,
    }

def main(ctx, params):
    # Discovery mode: enumerate ports
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.289.2.1.1.2.3.1.1"
        ], mutates=False)

        # Parse snmpwalk output into sections per line
        # Expected output format: .1.3.6.1.4.1.289.2.1.1.2.3.1.1.1 = INTEGER: 1
        # We need all 9 OID values per port. Build a dict keyed by base OID index.
        data = {}  # key: index suffix (e.g., "1"), value: dict of OID -> value
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 3:
                continue
            oid_part = parts[0]
            val = parts[2]
            # Extract base OID and suffix
            base = ".1.3.6.1.4.1.289.2.1.1.2.3.1.1."
            if oid_part.startswith(base):
                suffix = oid_part[len(base):]
                if suffix.isdigit():
                    if not suffix in data:
                        data[suffix] = {}
                    oid_num = oid_part.rsplit(".", 1)[-1]
                    data[suffix][oid_num] = val

        # Gather interfaces
        out = []
        for suffix in sorted(data.keys(), key=lambda x: int(x) if x.isdigit() else 0):
            d = data[suffix]
            # Map OID numbers to line indices (1-based to 0-based indices)
            # 1:ef6000PortIndex, 3:ef6000PortOpStatus, 11:ef6000PortSpeed,
            # 67:TxWords64, 68:RxWords64, 69:TxFrames64, 70:RxFrames64,
            # 83:C3Discards64, 65:Crcs
            line = [
                d.get("1", ""),
                d.get("3", ""),
                d.get("11", ""),
                d.get("67", []),
                d.get("68", []),
                d.get("69", []),
                d.get("70", []),
                d.get("83", []),
                d.get("65", "")
            ]
            iface = _line_to_interface(line)
            item = iface["index"]
            out.append({
                "item": item,
                "params": {},
                "metrics": [
                    "in_octets", "in_ucast", "in_err", "out_octets", "out_ucast", "out_disc",
                    "speed", "oper_status"
                ]
            })

        return {
            "changed": False,
            "msg": "discovered %d ports" % len(out),
            "data": {"discovery": out}
        }

    # Check mode: process one item (port)
    item = params.get("item", "")
    # Run snmpwalk for this specific port's base OID
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.289.2.1.1.2.3.1.1." + str(int(item))
    ], mutates=False)

    lines = res.stdout.splitlines()
    if not lines:
        return {
            "changed": False,
            "msg": "no data for port " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse the lines to build data dictionary
    d = {}
    for line in lines:
        l = line.strip().split()
        if len(l) < 3:
            continue
        oid_full = l[0]
        val = l[2]
        if oid_full.startswith(".1.3.6.1.4.1.289.2.1.1.2.3.1.1."):
            suffix = oid_full[len(".1.3.6.1.4.1.289.2.1.1.2.3.1.1."):]
            # Safely convert to int if it's a number string
            if suffix.isdigit():
                d[suffix] = val

    # Construct line: [1,3,11,67,68,69,70,83,65]
    line = [
        d.get("1", ""),
        d.get("3", ""),
        d.get("11", ""),
        d.get("67", []),
        d.get("68", []),
        d.get("69", []),
        d.get("70", []),
        d.get("83", []),
        d.get("65", "")
    ]

    iface = _line_to_interface(line)

    # Map to interface state (OK/WARN/CRIT) using Checkmk's if64 generic logic:
    # oper_status: "up"/"down"/"testing"/"faulty"/"unknown"
    # For simplicity: map operational status
    status_map = {
        "1": "OK", "2": "OK", "up": "OK",
        "testing": "WARN",
        "faulty": "CRIT", "down": "CRIT",
        "unknown": "UNKNOWN"
    }
    state = status_map.get(iface["oper_status"], "UNKNOWN")

    msg = "Port %s: %s, %d bps" % (item, iface["oper_status"], iface["speed"])
    metrics = {
        "in_octets": iface["in_octets"],
        "in_ucast": iface["in_ucast"],
        "in_err": iface["in_err"],
        "out_octets": iface["out_octets"],
        "out_ucast": iface["out_ucast"],
        "out_disc": iface["out_disc"],
        "speed": iface["speed"],
        "oper_status": 1 if iface["oper_status"] in ["1", "2", "up"] else (2 if iface["oper_status"] in ["testing"] else (3 if iface["oper_status"] in ["faulty","down"] else 0))
    }

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }