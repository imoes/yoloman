DISCOVERY_DEFAULT_PARAMETERS = {
    "admstates": [1, 3, 4],
    "phystates": [3, 4, 5, 6, 7, 8, 9, 10],
    "opstates": [1, 2, 3, 4],
    "use_portname": True,
    "show_isl": True,
}

OID_BASE_PORT_INFO = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1"
OID_BASE_PORT_ISL = ".1.3.6.1.4.1.1588.2.1.1.1.2.9.1"
OID_BASE_SFP = ".1.3.6.1.4.1.1588.2.1.1.1.28.1.1"

# SNMP OIDs (for snmpwalk/snmpget)
# Port info: index(1), phystate(3), opstate(4), admstate(5), portname(36)
OID_PORT_INDEX = OID_BASE_PORT_INFO + ".1"
OID_PORT_PHYSTATE = OID_BASE_PORT_INFO + ".3"
OID_PORT_OPSTATE = OID_BASE_PORT_INFO + ".4"
OID_PORT_ADMSTATE = OID_BASE_PORT_INFO + ".5"
OID_PORT_NAME = OID_BASE_PORT_INFO + ".36"

# ISL info
OID_PORT_ISL = OID_BASE_PORT_ISL + ".2"

# SFP metrics: temp(1), voltage(2), current(3), rx_power(4), tx_power(5)
OID_SFP_TEMP = OID_BASE_SFP + ".1"
OID_SFP_VOLTAGE = OID_BASE_SFP + ".2"
OID_SFP_CURRENT = OID_BASE_SFP + ".3"
OID_SFP_RX_POWER = OID_BASE_SFP + ".4"
OID_SFP_TX_POWER = OID_BASE_SFP + ".5"


def _parse_oid_line(line):
    """Parse one line of snmpwalk output: 'OID = TYPE: value' -> (oid_tail, value_str)"""
    if not line.strip():
        return None
    eq = line.find("=")
    if eq < 0:
        return None
    oid_part = line[:eq].strip()
    value_part = line[eq + 1:].strip()
    colon = value_part.find(": ")
    if colon < 0:
        return None
    value_str = value_part[colon + 2:].strip()
    if oid_part.startswith(OID_BASE_PORT_INFO):
        tail = oid_part[len(OID_BASE_PORT_INFO):]
    elif oid_part.startswith(OID_BASE_PORT_ISL):
        tail = oid_part[len(OID_BASE_PORT_ISL):]
    elif oid_part.startswith(OID_BASE_SFP):
        tail = oid_part[len(OID_BASE_SFP):]
    else:
        tail = ""
    return {"oid_tail": tail, "value": value_str}


def _walk_section(ctx, base_oid):
    """Walk entire section and return dict tail -> value"""
    res = ctx.run(["snmpwalk", "-v2c", "-c", ctx.get("community", "public"),
                   "-On", ctx.get("host", "localhost"), base_oid], mutates=False)
    result = {}
    for line in res.stdout.splitlines():
        parsed = _parse_oid_line(line)
        if parsed:
            tail = parsed["oid_tail"]
            result[tail] = parsed["value"]
    return result


def _brocade_fcport_inventory_this_port(admstate, phystate, opstate, settings):
    """Replicate brocade_fcport_inventory_this_port logic"""
    try_adm = admstate
    try_phi = phystate
    try_op = opstate
    if try_adm.isdigit():
        if int(try_adm) not in settings["admstates"]:
            return False
    else:
        return False
    if try_phi.isdigit():
        if int(try_phi) not in settings["phystates"]:
            return False
    else:
        return False
    return try_op.isdigit() and int(try_op) in settings["opstates"]


def _brocade_fcport_getitem(number_of_ports, index, portname, is_isl, settings):
    """Replicate brocade_fcport_getitem logic"""
    if number_of_ports == 0:
        itemname = "0"
    else:
        digits = len(str(number_of_ports))
        itemname = ("%0" + str(digits) + "d") % (index - 1)
    if is_isl and settings["show_isl"]:
        itemname += " ISL"
    if portname.strip() != "":
        itemname += " " + portname.strip()
    return itemname


def _check_temperature(value, params):
    """Replicate check_temperature behavior for simple cases"""
    warn = params.get("levels", None)
    if warn == None:
        warn = (None, None)
    elif type(warn) == "int":
        warn = (warn, warn)
    elif type(warn) == "list":
        if len(warn) < 2:
            warn = (warn[0], None) if len(warn) == 1 else (None, None)
        else:
            warn = (warn[0], warn[1])
    else:
        warn = (None, None)

    warn_lower = warn[0]
    warn_upper = warn[1]

    crit = params.get("levels_lower", None)
    if crit == None:
        crit = (None, None)
    elif type(crit) == "int":
        crit = (crit, None)
    elif type(crit) == "list":
        if len(crit) < 2:
            crit = (crit[0], None) if len(crit) == 1 else (None, None)
        else:
            crit = (crit[0], crit[1])
    else:
        crit = (None, None)

    crit_lower = crit[0]
    crit_upper = crit[1]

    if crit_lower == None and crit_upper == None:
        crit_lower = warn_lower
        crit_upper = warn_upper

    state = "OK"
    if crit_upper != None and value >= crit_upper:
        state = "CRIT"
    elif crit_lower != None and value <= crit_lower:
        state = "CRIT"
    elif warn_upper != None and value >= warn_upper:
        state = "WARN"
    elif warn_lower != None and value <= warn_lower:
        state = "WARN"

    msg = "Temperature: %f C" % value
    return state, msg


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    settings = params.get("discovery", DISCOVERY_DEFAULT_PARAMETERS)
    if settings == None:
        settings = DISCOVERY_DEFAULT_PARAMETERS

    if not isinstance(settings, dict):
        settings = DISCOVERY_DEFAULT_PARAMETERS

    if params.get("_discover"):
        port_info_section = _walk_section(ctx, OID_BASE_PORT_INFO)
        port_isl_section = _walk_section(ctx, OID_BASE_PORT_ISL)
        sfp_section = _walk_section(ctx, OID_BASE_SFP)

        port_infos = {}
        for tail, val_str in port_info_section.items():
            idx_str = tail.lstrip(".")
            if not idx_str.isdigit():
                continue
            idx = int(idx_str)
            phystate = port_info_section.get("." + str(idx) + ".3")
            opstate = port_info_section.get("." + str(idx) + ".4")
            admstate = port_info_section.get("." + str(idx) + ".5")
            portname = port_info_section.get("." + str(idx) + ".36")
            if phystate == None or opstate == None or admstate == None:
                continue

            port_infos[idx] = {
                "index": idx,
                "phystate": phystate,
                "opstate": opstate,
                "admstate": admstate,
                "portname": portname if portname != None and portname != "NA" else "",
            }

        isl_list = []
        for tail, val_str in port_isl_section.items():
            idx_str = tail.lstrip(".")
            if idx_str.isdigit():
                isl_list.append(int(idx_str))

        sfp_metrics = {}
        for tail, val_str in sfp_section.items():
            idx_str = tail.lstrip(".")
            if not idx_str.isdigit():
                continue
            idx = int(idx_str)
            temp_val = sfp_section.get(tail)
            if temp_val == None or temp_val == "NA":
                continue
            if not temp_val.isdigit():
                continue
            temp_int = int(temp_val)
            sfp_metrics[idx] = {
                "index": idx,
                "temp": temp_int,
            }

        ports = {}
        for idx, info in port_infos.items():
            if idx in sfp_metrics:
                ports[idx] = {"info": info, "values": sfp_metrics[idx]}

        discovered = []
        for idx, port in ports.items():
            info = port["info"]
            if not _brocade_fcport_inventory_this_port(
                info["admstate"], info["phystate"], info["opstate"], settings
            ):
                continue

            item = _brocade_fcport_getitem(
                len(ports),
                info["index"],
                info["portname"],
                info["index"] in isl_list,
                settings,
            )
            discovered.append({
                "item": item,
                "params": {"levels": None},
                "metrics": ["temp"],
            })

        return {
            "changed": False,
            "msg": "discovered %d SFP ports" % len(discovered),
            "data": {"discovery": discovered},
        }

    item = params.get("item", "")
    parts = item.split(" ", 1)
    idx_str = parts[0]
    if not idx_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    port_index = int(idx_str) + 1

    port_info_section = _walk_section(ctx, OID_BASE_PORT_INFO)
    port_isl_section = _walk_section(ctx, OID_BASE_PORT_ISL)
    sfp_section = _walk_section(ctx, OID_BASE_SFP)

    port_infos = {}
    for tail, val_str in port_info_section.items():
        idx_str = tail.lstrip(".")
        if not idx_str.isdigit():
            continue
        idx = int(idx_str)
        phystate = port_info_section.get("." + str(idx) + ".3")
        opstate = port_info_section.get("." + str(idx) + ".4")
        admstate = port_info_section.get("." + str(idx) + ".5")
        portname = port_info_section.get("." + str(idx) + ".36")
        if phystate == None or opstate == None or admstate == None:
            continue
        port_infos[idx] = {
            "index": idx,
            "phystate": phystate,
            "opstate": opstate,
            "admstate": admstate,
            "portname": portname if portname != None and portname != "NA" else "",
        }

    isl_list = []
    for tail, val_str in port_isl_section.items():
        idx_str = tail.lstrip(".")
        if idx_str.isdigit():
            isl_list.append(int(idx_str))

    sfp_metrics = {}
    for tail, val_str in sfp_section.items():
        idx_str = tail.lstrip(".")
        if not idx_str.isdigit():
            continue
        idx = int(idx_str)
        temp_val = sfp_section.get(tail)
        if temp_val == None or temp_val == "NA":
            continue
        if not temp_val.isdigit():
            continue
        temp_int = int(temp_val)
        sfp_metrics[idx] = {"index": idx, "temp": temp_int}

    ports = {}
    for idx, info in port_infos.items():
        if idx in sfp_metrics:
            ports[idx] = {"info": info, "values": sfp_metrics[idx]}

    port = ports.get(port_index)
    if port == None:
        return {
            "changed": False,
            "msg": "port index %d not found" % port_index,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    temp = port["values"]["temp"]
    state, msg = _check_temperature(float(temp), params)
    metrics = {"temp": float(temp)}

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }
