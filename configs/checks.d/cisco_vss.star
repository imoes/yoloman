def main(ctx, params):
    if params.get("_discover"):
        base = ".1.3.6.1.4.1.9.9.388"
        sysdesc = ctx.run(["snmpget", "-v2c", "-c",
                           params.get("community", "public"), "-Oqv",
                           params.get("host", "localhost"),
                           ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if sysdesc.rc == 127 or sysdesc.rc != 0:
            return {"changed": False, "msg": "snmp not available",
                    "data": {"discovery": []}}
        if ("Catalyst 45" not in sysdesc.stdout and
                "Catalyst 65" not in sysdesc.stdout and
                "s72033_rp" not in sysdesc.stdout):
            return {"changed": False, "msg": "not a VSS-capable device",
                    "data": {"discovery": []}}
        exists_res = ctx.run(["snmpget", "-v2c", "-c",
                              params.get("community", "public"), "-Oqv",
                              params.get("host", "localhost"),
                              base + ".1.1.1.0"], mutates=False)
        if exists_res.rc != 0:
            return {"changed": False, "msg": "VSS not present on device",
                    "data": {"discovery": []}}
        walk = ctx.run(["snmpwalk", "-v2c", "-c",
                        params.get("community", "public"), "-Oqn",
                        params.get("host", "localhost"),
                        base + ".1.2.2.1.2"], mutates=False)
        if walk.rc != 0:
            return {"changed": False, "msg": "no chassis entries",
                    "data": {"discovery": []}}
        found = False
        for line in walk.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            role = parts[1].strip().strip('"')
            if role in ("2", "3"):
                found = True
                break
        if not found:
            return {"changed": False, "msg": "no active/standby chassis",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["vss_chassis", "vsl_ports"]}]}}
        return {"changed": False, "msg": "no match", "data": {"discovery": []}}

    # CHECK MODE
    base = ".1.3.6.1.4.1.9.9.388"
    comm = params.get("community", "public")
    host = params.get("host", "localhost")

    sysdesc = ctx.run(["snmpget", "-v2c", "-c", comm, "-Oqv",
                       host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
    if sysdesc.rc == 127 or sysdesc.rc != 0:
        return {"changed": False, "msg": "snmp not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if ("Catalyst 45" not in sysdesc.stdout and
            "Catalyst 65" not in sysdesc.stdout and
            "s72033_rp" not in sysdesc.stdout):
        return {"changed": False, "msg": "not a VSS-capable device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    exists_res = ctx.run(["snmpget", "-v2c", "-c", comm, "-Oqv",
                          host, base + ".1.1.1.0"], mutates=False)
    if exists_res.rc != 0:
        return {"changed": False, "msg": "VSS not present on device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    chassis_walk = ctx.run(["snmpwalk", "-v2c", "-c", comm, "-Oqn",
                            host, base + ".1.2.2.1.2"], mutates=False)
    if chassis_walk.rc != 0:
        return {"changed": False, "msg": "no chassis data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    chassis = []
    for line in chassis_walk.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        oid = parts[0]
        idx = oid.rsplit(".", 1)[-1]
        role = parts[1].strip().strip('"')
        chassis.append((idx, role))

    ports_walk = ctx.run(["snmpwalk", "-v2c", "-c", comm, "-Oqn",
                          host, base + ".1.3.1.1"], mutates=False)
    ports = []
    if ports_walk.rc == 0:
        cols = {"2": [], "3": [], "5": [], "6": []}
        indices = set()
        for line in ports_walk.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            oid = parts[0]
            suffix = oid[len(base + ".1.3.1.1"):]
            bits = suffix.split(".")
            if len(bits) < 3:
                continue
            col = bits[1]
            idx = bits[2]
            if col in cols:
                indices.add(idx)
        for idx in indices:
            row = {}
            for col in ["2", "3", "5", "6"]:
                r = ctx.run(["snmpget", "-v2c", "-c", comm, "-Oqv",
                             host, base + ".1.3.1.1." + col + "." + idx],
                            mutates=False)
                if r.rc == 0:
                    row[col] = r.stdout.strip().strip('"')
                else:
                    row[col] = ""
            ports.append((idx, row.get("2", ""), row.get("3", ""),
                           row.get("5", ""), row.get("6", "")))

    details = ""
    metrics = {}
    state = "OK"
    for switch_id, chassis_role in chassis:
        role_name = _role_name(chassis_role)
        if chassis_role == "1":
            state = "CRIT"
        details += "chassis %s: %s\n" % (switch_id, role_name)

    details += "%d VSL connections configured\n" % len(ports)
    for core_switch_id, operstatus, conf_portcount, op_portcount in ports:
        if operstatus == "1":
            s = "OK"
        else:
            s = "CRIT"
            if state != "CRIT":
                state = "CRIT"
        details += "core switch %s: VSL %s\n" % (core_switch_id, _operstatus_name(operstatus))

        if conf_portcount == op_portcount:
            s2 = "OK"
        else:
            s2 = "CRIT"
            if state != "CRIT":
                state = "CRIT"
        details += "%s/%s ports operational\n" % (op_portcount, conf_portcount)

    return {"changed": False, "msg": "VSS check complete",
            "data": {"state": state, "metrics": metrics, "details": details}}


def _role_name(role):
    if role == "1":
        return "standalone"
    if role == "2":
        return "active"
    if role == "3":
        return "standby"
    return "unknown"


def _operstatus_name(operstatus):
    if operstatus == "1":
        return "up"
    if operstatus == "2":
        return "down"
    return "unknown"