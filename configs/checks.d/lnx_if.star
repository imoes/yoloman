def _parse_speed(text):
    if text == "65535Mb/s":
        return 0
    if text.endswith("Kb/s"):
        return int(float(text[:-4])) * 1000
    if text.endswith("Gb/s"):
        return int(float(text[:-4])) * 1000000000
    if text.endswith("Mb/s"):
        return int(float(text[:-4])) * 1000000
    return 0


def _get_oper(link_detected, state_infos, if_in_octets):
    if link_detected == "yes":
        return "1"
    if link_detected == "no":
        return "2"
    if state_infos != None:
        if "UP" in state_infos and "LOWER_UP" in state_infos:
            return "1"
        return "2"
    if if_in_octets > 0:
        return "1"
    return "4"


def main(ctx, params):
    if params.get("_discover"):
        ip = ctx.run(["ip", "-o", "link"], mutates=False)
        if ip.rc != 0:
            return {"changed": False, "msg": "ip command not available", "data": {"discovery": []}}
        dev = ctx.file_read("/proc/net/dev") if ctx.file_exists("/proc/net/dev") else ""
        eth = ctx.run(["ethtool", "--version"], mutates=False)
        has_ethtool = eth.rc == 0

        dev_counters = {}
        if dev:
            dlines = dev.splitlines()
            if len(dlines) > 2:
                for dl in dlines[2:]:
                    # /proc/net/dev is "  iface: c1 c2 ... c16". Split on the colon
                    # first: the whole line is one field and the byte counter may
                    # abut the colon with no space ("eth0:12345"), so a bare
                    # whitespace split would fold name+counter and lose the 16 columns.
                    if ":" not in dl:
                        continue
                    name_part, rest = dl.split(":", 1)
                    ifname = name_part.strip()
                    vals = rest.split()
                    if len(vals) >= 16:
                        ok = True
                        cnts = []
                        for v in vals[:16]:
                            if v.isdigit():
                                cnts.append(int(v))
                            else:
                                ok = False
                                break
                        if ok:
                            dev_counters[ifname] = cnts

        discovery = []
        for line in ip.stdout.splitlines():
            fields = line.split()
            if len(fields) < 2:
                continue
            raw = fields[1]
            cidx = raw.find(":")
            if cidx < 0:
                continue
            ifname = raw[:cidx]
            if ifname.startswith("veth"):
                continue

            state_infos = []
            lt = line.find("<")
            gt = line.find(">", lt) if lt >= 0 else -1
            if lt >= 0 and gt > lt:
                state_infos = line[lt+1:gt].split(",")

            counters = dev_counters.get(ifname)
            in_oct = 0
            if counters != None:
                in_oct = counters[0]

            oper = _get_oper(None, state_infos, in_oct)

            discovery.append({
                "item": ifname,
                "params": {"warn": 80, "crit": 90},
                "metrics": [
                    "if_in_oct_bytes",
                    "if_out_oct_bytes",
                    "if_in_packets",
                    "if_out_packets",
                    "if_in_err",
                    "if_out_err",
                    "if_in_disc",
                    "if_out_disc",
                    "link_up",
                ],
            })

        hl = {"cmk/os_family": ctx.facts().get("os_family", "linux")}
        ipaddr = ctx.run(["ip", "-o", "addr"], mutates=False)
        n4 = 0
        n6 = 0
        if ipaddr.rc == 0:
            for al in ipaddr.stdout.splitlines():
                f2 = al.split()
                if len(f2) < 4:
                    continue
                fam = f2[2]
                if fam == "inet":
                    n4 = n4 + 1
                elif fam == "inet6":
                    n6 = n6 + 1
        if n4 == 1:
            hl["cmk/l3v4_topology"] = "singlehomed"
        elif n4 > 1:
            hl["cmk/l3v4_topology"] = "multihomed"
        if n6 == 1:
            hl["cmk/l3v6_topology"] = "singlehomed"
        elif n6 > 1:
            hl["cmk/l3v6_topology"] = "multihomed"

        return {
            "changed": False,
            "msg": "discovered %d interfaces" % len(discovery),
            "data": {"discovery": discovery, "host_labels": hl},
        }

    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    dev = ctx.file_read("/proc/net/dev") if ctx.file_exists("/proc/net/dev") else ""
    dev_counters = {}
    if dev:
        dlines = dev.splitlines()
        if len(dlines) > 2:
            for dl in dlines[2:]:
                # /proc/net/dev is "  iface: c1 c2 ... c16". Split on the colon
                # first: the byte counter may abut the colon with no space
                # ("eth0:12345"), so a bare whitespace split would fold
                # name+counter and never reach the 16 columns the check needs.
                if ":" not in dl:
                    continue
                name_part, rest = dl.split(":", 1)
                ifname = name_part.strip()
                vals = rest.split()
                if len(vals) >= 16:
                    ok = True
                    cnts = []
                    for v in vals[:16]:
                        if v.isdigit():
                            cnts.append(int(v))
                        else:
                            ok = False
                            break
                    if ok:
                        dev_counters[ifname] = cnts

    if item not in dev_counters:
        return {"changed": False, "msg": "interface %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    counters = dev_counters[item]
    in_oct = counters[0]
    in_pkts = counters[1]
    in_err = counters[2]
    in_disc = counters[3]
    out_oct = counters[8]
    out_pkts = counters[9]
    out_err = counters[10]
    out_disc = counters[11]

    link_detected = None
    speed = 0
    eth = ctx.run(["ethtool", item], mutates=False)
    if eth.rc == 0 and item != "lo":
        for el in eth.stdout.splitlines():
            el = el.strip()
            if el.startswith("Speed:"):
                speed = _parse_speed(el.split(":", 1)[1].strip())
            elif el.startswith("Link detected:"):
                link_detected = el.split(":", 1)[1].strip()

    ip = ctx.run(["ip", "-o", "link"], mutates=False)
    state_infos = []
    if ip.rc == 0:
        for il in ip.stdout.splitlines():
            fields = il.split()
            if len(fields) >= 2 and fields[1].startswith(item + ":"):
                lt = il.find("<")
                gt = il.find(">", lt) if lt >= 0 else -1
                if lt >= 0 and gt > lt:
                    state_infos = il[lt+1:gt].split(",")
                break

    oper = _get_oper(link_detected, state_infos, in_oct)

    link_up = 0
    if oper == "1":
        link_up = 1

    warn = params.get("warn", 80)
    crit = params.get("crit", 90)

    state = "OK"
    if oper == "2":
        state = "CRIT"
    elif oper == "3":
        state = "WARN"
    elif oper == "4":
        state = "UNKNOWN"

    msg = "Oper %s, Speed %dMb/s, In %d Out %d" % (oper, speed / 1000000, in_oct, out_oct)

    metrics = {
        "if_in_oct_bytes": in_oct,
        "if_out_oct_bytes": out_oct,
        "if_in_packets": in_pkts,
        "if_out_packets": out_pkts,
        "if_in_err": in_err,
        "if_out_err": out_err,
        "if_in_disc": in_disc,
        "if_out_disc": out_disc,
        "link_up": link_up,
    }

    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": ""}}