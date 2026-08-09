# Checkmk check translation: teracom_tcw241_digital
# Monitors the 4 digital sensors of a Teracom TCW241 via SNMP.

DESCRIPTIONS_BASE = ".1.3.6.1.4.1.38783.3.2.2.3"
DESCRIPTIONS_OIDS = ["1.0", "2.0", "3.0", "4.0"]
STATES_BASE = ".1.3.6.1.4.1.38783.3.3.3"
STATES_OIDS = ["1.0", "2.0", "3.0", "4.0"]
SYSOID = ".1.3.6.1.2.1.1.1.0"


def _get_desc(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _walk_states(ctx, host, community, base, oids):
    out = {}
    for oid in oids:
        full = base + "." + oid
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, full],
            mutates=False,
        )
        if res.rc != 0:
            return None
        out[oid] = res.stdout.strip()
    return out


def _probe(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Detect the Teracom device presence first.
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSOID],
        mutates=False,
    )
    if res.rc != 0:
        return None
    if "Teracom" not in res.stdout:
        return None
    return host, community


def main(ctx, params):
    # ---- DISCOVERY ----
    if params.get("_discover"):
        probed = _probe(ctx, params)
        if not probed:
            return {
                "changed": False,
                "msg": "no Teracom TCW241 device found",
                "data": {"discovery": []},
            }
        host, community = probed

        descriptions = {}
        for oid in DESCRIPTIONS_OIDS:
            full = DESCRIPTIONS_BASE + "." + oid
            val = _get_desc(ctx, host, community, full)
            if val == None:
                return {
                    "changed": False,
                    "msg": "failed to read sensor descriptions",
                    "data": {"discovery": []},
                }
            descriptions[oid] = val

        states = _walk_states(ctx, host, community, STATES_BASE, STATES_OIDS)
        if states == None:
            return {
                "changed": False,
                "msg": "failed to read sensor states",
                "data": {"discovery": []},
            }

        discovery = []
        for index in range(4):
            oid = str(index + 1) + ".0"
            sensor_state = "open" if states.get(oid) == "1" else "closed"
            full_oid = DESCRIPTIONS_BASE + "." + oid
            desc_res = _get_desc(ctx, host, community, full_oid)
            if desc_res == None:
                continue
            item = str(index + 1)
            discovery.append({
                "item": item,
                "params": {},
                "metrics": [],
                "service_labels": {
                    "description": desc_res,
                    "state": sensor_state,
                },
            })
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    # ---- CHECK ----
    item = params.get("item", "")
    probed = _probe(ctx, params)
    if not probed:
        return {
            "changed": False,
            "msg": "no Teracom TCW241 device found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "no Teracom TCW241 device responding on SNMP",
            },
        }
    host, community = probed

    try_item = int(item)
    if try_item < 1 or try_item > 4:
        return {
            "changed": False,
            "msg": "invalid sensor item: " + str(item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "sensor number must be between 1 and 4",
            },
        }

    # Read description for this sensor.
    desc_oid = DESCRIPTIONS_BASE + "." + str(try_item) + ".0"
    description = _get_desc(ctx, host, community, desc_oid)
    if description == None:
        return {
            "changed": False,
            "msg": "failed to read description for sensor " + str(item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Read state for this sensor.
    state_oid = STATES_BASE + "." + str(try_item) + ".0"
    state_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, state_oid],
        mutates=False,
    )
    if state_res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to read state for sensor " + str(item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    raw_state = state_res.stdout.strip()
    sensor_state = "open" if raw_state == "1" else "closed"
    verdict = "OK" if sensor_state == "open" else "CRIT"

    return {
        "changed": False,
        "msg": "[%s] is %s" % (description, sensor_state),
        "data": {
            "state": verdict,
            "metrics": {},
            "details": "",
        },
    }