def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    if params.get("_discover"):
        detect = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Ov", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if detect.rc != 0:
            return {"changed": False, "msg": "not an Atto FibreBridge device",
                    "data": {"discovery": []}}
        if not detect.stdout.startswith(".1.3.6.1.4.1.4547"):
            return {"changed": False, "msg": "not an Atto Fibrebridge device",
                    "data": {"discovery": []}}

        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
             "1.3.6.1.4.1.4547.2.3.3.2.1.2"],
            mutates=False,
        )
        found = []
        indices = {}
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, val = parts
            base = "1.3.6.1.4.1.4547.2.3.3.2.1.2."
            if oid.startswith(base):
                idx = oid[len(base):]
                indices[idx] = val
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            base = "1.3.6.1.4.1.4547.2.3.3.2.1.2."
            if oid.startswith(base):
                idx = oid[len(base):]
                port_name = indices.get(idx, "")
                if port_name not in [f["item"] for f in found]:
                    found.append({"item": port_name,
                                  "params": {"fc_tx_words": None, "fc_rx_words": None},
                                  "metrics": ["fc_tx_words", "fc_rx_words"]})
        return {"changed": False,
                "msg": "discovered %d fc ports" % len(found),
                "data": {"discovery": found,
                         "host_labels": {"cmk/os_family": "snmp"}}}

    if not item and not indices:
        get_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             "1.3.6.1.4.1.4547.2.3.3.2.1.2.%s" % item],
            mutates=False,
        )
        if get_res.rc != 0 or not get_res.stdout:
            return {"changed": False, "msg": "no fc port found",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    tx_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         "1.3.6.1.4.1.4547.2.3.3.2.1.2.%s" % item],
        mutates=False,
    )
    rx_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         "1.3.6.1.4.1.4547.2.3.3.2.1.3.%s" % item],
        mutates=False,
    )

    if tx_res.rc != 0 or rx_res.rc != 0 or not tx_res.stdout or not rx_res.stdout:
        return {"changed": False, "msg": "no fc port data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    tx = int(tx_res.stdout)
    rx = int(rx_res.stdout)

    tx_warn = params.get("fc_tx_words_warn")
    tx_crit = params.get("fc_tx_words_crit")
    rx_warn = params.get("fc_rx_words_warn")
    rx_crit = params.get("fc_rx_words_crit")

    tx_state = "OK"
    if tx_warn != None and tx_crit != None:
        if tx >= float(tx_crit):
            tx_state = "CRIT"
        elif tx >= float(tx_warn):
            tx_state = "WARN"
    rx_state = "OK"
    if rx_warn != None and rx_crit != None:
        if rx >= float(rx_crit):
            rx_state = "CRIT"
        elif rx >= float(rx_warn):
            rx_state = "WARN"

    state = "OK"
    if tx_state == "CRIT" or rx_state == "CRIT":
        state = "CRIT"
    elif tx_state == "WARN" or rx_state == "WARN":
        state = "WARN"

    return {"changed": False,
            "msg": "TX: %d words/s, RX: %d words/s" % (tx, rx),
            "data": {"state": state,
                     "metrics": {"fc_tx_words": tx, "fc_rx_words": rx},
                     "details": ""}}