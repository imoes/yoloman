# ===== Checkmk check: enterasys_powersupply → Starlark =====

def main(ctx, params):
    if params.get("_discover"):
        base = ".1.3.6.1.4.1.52.4.3.1.2.1.1"
        res = ctx.run(
            [
                "snmpwalk", "-v2c",
                "-c", params.get("community", "public"),
                "-Oqn", params.get("host", "localhost"),
                base,
            ],
            mutates=False,
        )
        items = []
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = line[sp + 1:]
            idx = oid[len(base) + 1:]
            if ".1" in oid and ".2" not in oid and val == "3":
                items.append({
                    "item": idx,
                    "params": {"redundancy_ok_states": [1]},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d PSUs" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.52.4.3.1.2.1.1"

    num_res = ctx.run(
        [
            "snmpget", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv", params.get("host", "localhost"),
            base + ".1." + item,
        ],
        mutates=False,
    )
    state_res = ctx.run(
        [
            "snmpget", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv", params.get("host", "localhost"),
            base + ".2." + item,
        ],
        mutates=False,
    )
    type_res = ctx.run(
        [
            "snmpget", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv", params.get("host", "localhost"),
            base + ".3." + item,
        ],
        mutates=False,
    )
    redun_res = ctx.run(
        [
            "snmpget", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv", params.get("host", "localhost"),
            base + ".4." + item,
        ],
        mutates=False,
    )

    if (num_res.rc != 0 or state_res.rc != 0 or type_res.rc != 0
            or redun_res.rc != 0):
        return {
            "changed": False,
            "msg": "PSU %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = state_res.stdout.strip()
    typ = type_res.stdout.strip()
    redun = redun_res.stdout.strip()

    SUPPLY_TYPES = {
        "1": "ac-dc",
        "2": "dc-dc",
        "3": "notSupported",
        "4": "highOutput",
    }
    REDUNDANCY_TYPES = {
        "1": "redundant",
        "2": "notRedundant",
        "3": "notSupported",
    }

    if state == "4":
        return {
            "changed": False,
            "msg": "PSU %s: Status: installed and not operating" % item,
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }

    redun_mapped = REDUNDANCY_TYPES.get(redun, "unknown[%s]" % redun)
    ok_states = params.get("redundancy_ok_states", [1])

    if redun and int(redun) in ok_states:
        supply_type = SUPPLY_TYPES.get(typ, "unknown[%s]" % typ)
        return {
            "changed": False,
            "msg": "PSU %s: Status: working and %s (%s)" % (
                item, redun_mapped, supply_type,
            ),
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "PSU %s: Status: %s" % (item, redun_mapped),
        "data": {"state": "WARN", "metrics": {}, "details": ""},
    }