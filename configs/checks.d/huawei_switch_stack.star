# Checkmk check: huawei_switch_stack — translated read-only Starlark module.
#
# Source data comes from SNMP. The Checkmk agent plugin fetches two SNMP subtrees:
#   base1 = .1.3.6.1.4.1.2011.5.25.183.1           oids=["5"]   (stack enabled flag)
#   base2 = .1.3.6.1.4.1.2011.5.25.183.1.20.1      oids=[OIDEnd(), "3"]
#           (per-slot: index = OIDEnd suffix, col "3" = role)
#
# -Oqv gives the bare scalar value for base1.
# -Oqn gives "<full-oid> <value>" lines for base2.
# The index (OIDEnd suffix after base2) is the slot member id and becomes the item name.
# Col "3" value is mapped: "1"=master, "2"=standby, "3"=slave, else "unknown".
#
# Detection (DETECT_HUAWEI_SWITCH) = sysObjectID startswith ".1.3.6.1.4.1.2011.2.23".

_STACK_ROLE_NAMES = {
    "1": "master",
    "2": "standby",
    "3": "slave",
}

_UNKNOWN_ROLE = "unknown"

_BASE1 = ".1.3.6.1.4.1.2011.5.25.183.1"
_COL5 = "5"          # stack enabled flag under base1
_BASE2 = ".1.3.6.1.4.1.2011.5.25.183.1.20.1"
_COL3 = "3"          # role column under base2

_DETECT_PREFIX = ".1.3.6.1.4.1.2011.2.23"


def _role_name(value):
    return _STACK_ROLE_NAMES.get(value, _UNKNOWN_ROLE)


def _snmp_enabled(ctx, params):
    """Read the stack-enabled scalar. Returns True if enabled."""
    res = ctx.run(
        [
            "snmpget",
            "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv",
            params.get("host", "localhost"),
            _BASE1 + "." + _COL5,
        ],
        mutates=False,
    )
    if res.rc != 0:
        return False
    val = res.stdout.strip()
    if val == "" or val == "Null":
        return False
    return val == "1"


def _snmp_walk_roles(ctx, params):
    """Walk base2 col 3; return dict {index: role_raw_value}. Empty if none."""
    res = ctx.run(
        [
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-Oqn",
            params.get("host", "localhost"),
            _BASE2 + "." + _COL3,
        ],
        mutates=False,
    )
    if res.rc != 0 and res.rc != 126:
        return {}
    roles = {}
    base_len = len(_BASE2) + 1  # +1 for the dot before the column number
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        # oid is like ".<col>.<index>"; drop the leading column portion.
        # base2 + "." + col3 + "." + index  ->  oid suffix after that prefix is the index.
        prefix = _BASE2 + "." + _COL3 + "."
        if not oid.startswith(prefix):
            continue
        index = oid[len(prefix):]
        if index == "":
            continue
        roles[index] = value
    return roles


def _is_huawei_switch(ctx, params):
    res = ctx.run(
        [
            "snmpget",
            "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv",
            params.get("host", "localhost"),
            ".1.3.6.1.2.1.1.2.0",
        ],
        mutates=False,
    )
    if res.rc != 0:
        return False
    return res.stdout.strip().startswith(_DETECT_PREFIX)


def main(ctx, params):
    if params.get("_discover"):
        if not _is_huawei_switch(ctx, params):
            return {
                "changed": False,
                "msg": "device is not a Huawei switch",
                "data": {"discovery": []},
            }
        enabled = _snmp_enabled(ctx, params)
        if not enabled:
            return {
                "changed": False,
                "msg": "stack not enabled on this device",
                "data": {"discovery": []},
            }
        roles = _snmp_walk_roles(ctx, params)
        if not roles:
            return {
                "changed": False,
                "msg": "no stack members found",
                "data": {"discovery": []},
            }
        discovery = []
        for index in sorted(roles.keys()):
            role = _role_name(roles[index])
            discovery.append({
                "item": index,
                "params": {"expected_role": role},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d stack members" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if not _is_huawei_switch(ctx, params):
        return {
            "changed": False,
            "msg": "device is not a Huawei switch",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    enabled = _snmp_enabled(ctx, params)
    if not enabled:
        return {
            "changed": False,
            "msg": "stack not enabled on this device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    roles = _snmp_walk_roles(ctx, params)
    if not roles:
        return {
            "changed": False,
            "msg": "no stack members found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    role_raw = roles.get(item)
    if role_raw == None:
        return {
            "changed": False,
            "msg": "no such stack member: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    role = _role_name(role_raw)
    expected_role = params.get("expected_role", "unknown")
    if role == _UNKNOWN_ROLE:
        state = "CRIT"
        summary = role
    elif role == expected_role:
        state = "OK"
        summary = role
    else:
        state = "CRIT"
        summary = "Unexpected role: %s (Expected: %s)" % (role, expected_role)
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""},
    }