def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["dspmq"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "IBM MQ not installed or not running",
                    "data": {"discovery": []}}
        qmgrs = {}
        cur_qmgr = None
        for line in res.stdout.splitlines():
            s = line.strip()
            if s.startswith("QMNAME("):
                cur_qmgr = s[8:].rstrip(")")
                qmgrs[cur_qmgr] = {"STATUS": "UNKNOWN", "NOW": ""}
            elif s.startswith("STATUS("):
                qmgrs[cur_qmgr]["STATUS"] = s[8:].rstrip(")")
            elif s.startswith("QMUR") and cur_qmgr:
                qmgrs[cur_qmgr]["STATUS"] = "RUNNING"
        items = []
        for qmgr in qmgrs:
            if qmgrs[qmgr]["STATUS"] == "RUNNING":
                qstatus = ctx.run(
                    ["runmqsc", qmgr], input="display qlocal status", mutates=False)
                if qstatus.rc != 0:
                    continue
                cur = None
                for line in qstatus.stdout.splitlines():
                    s = line.strip()
                    if s.startswith("QUEUE("):
                        cur = s[7:].split(")")[0]
                    if cur:
                        entry = qmgrs.get(cur)
                        if not entry:
                            entry = {}
                            qmgrs[cur] = entry
                        if s.startswith("CURDEPTH"):
                            entry["CURDEPTH"] = s.split("(")[1].rstrip(")")
                        elif s.startswith("MAXDEPTH"):
                            entry["MAXDEPTH"] = s.split("(")[1].rstrip(")")
                        elif s.startswith("MSGAGE"):
                            entry["MSGAGE"] = s.split("(")[1].rstrip(")")
                        elif s.startswith("LGETDATE"):
                            entry["LGETDATE"] = s.split("(")[1].rstrip(")")
                        elif s.startswith("LGETTIME"):
                            entry["LGETTIME"] = s.split("(")[1].rstrip(")")
                        elif s.startswith("LPUTDATE"):
                            entry["LPUTDATE"] = s.split("(")[1].rstrip(")")
                        elif s.startswith("LPUTTIME"):
                            entry["LPUTTIME"] = s.split("(")[1].rstrip(")")
                        elif s.startswith("QTIME"):
                            entry["QTIME"] = s.split("(")[1].rstrip(")")
                for q in sorted(qmgrs):
                    if ":" in q:
                        continue
                    if qmgrs[q]["STATUS"] == "RUNNING":
                        items.append({"item": q + ":" + q,
                                       "params": {},
                                       "metrics": ["curdepth", "curdepth_perc",
                                                   "msgage", "lgetage", "lputage",
                                                   "qtime_short", "qtime_long"]})
        return {"changed": False, "msg": "discovered %d IBM MQ queues" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    if ":" not in item:
        return {"changed": False, "msg": "no IBM MQ queue found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    qmgr_name = item.split(":", 1)[0]
    qstatus = ctx.run(["runmqsc", qmgr_name], input="display qlocal status", mutates=False)
    if qstatus.rc != 0:
        return {"changed": False, "msg": "IBM MQ queue manager not running",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = {}
    cur = None
    for line in qstatus.stdout.splitlines():
        s = line.strip()
        if s.startswith("QUEUE("):
            cur = s[7:].split(")")[0]
            if cur == item.split(":", 1)[1]:
                data = {}
            elif cur and cur != item.split(":", 1)[1]:
                cur = None
        if cur == item.split(":", 1)[1]:
            if s.startswith("CURDEPTH"):
                data["CURDEPTH"] = s.split("(")[1].rstrip(")")
            elif s.startswith("MAXDEPTH"):
                data["MAXDEPTH"] = s.split("(")[1].rstrip(")")
            elif s.startswith("MSGAGE"):
                data["MSGAGE"] = s.split("(")[1].rstrip(")")
            elif s.startswith("LGETDATE"):
                data["LGETDATE"] = s.split("(")[1].rstrip(")")
            elif s.startswith("LGETTIME"):
                data["LGETTIME"] = s.split("(")[1].rstrip(")")
            elif s.startswith("LPUTDATE"):
                data["LPUTDATE"] = s.split("(")[1].rstrip(")")
            elif s.startswith("LPUTTIME"):
                data["LPUTTIME"] = s.split("(")[1].rstrip(")")
            elif s.startswith("QTIME"):
                data["QTIME"] = s.split("(")[1].rstrip(")")

    if not data:
        return {"changed": False, "msg": "queue not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    state = "OK"
    details = ""

    if "CURDEPTH" in data:
        cur_depth = int(data["CURDEPTH"]) if data["CURDEPTH"] else 0
        max_depth = int(data["MAXDEPTH"]) if data.get("MAXDEPTH") else None
        metrics["curdepth"] = cur_depth
        raw_abs = params.get("curdepth")
        if raw_abs:
            abs_warn = raw_abs[0] if len(raw_abs) > 0 else None
            abs_crit = raw_abs[1] if len(raw_abs) > 1 else None
            if abs_crit != None and cur_depth >= abs_crit:
                state = "CRIT"
            elif abs_warn != None and cur_depth >= abs_warn and state != "CRIT":
                state = "WARN"
        if max_depth and max_depth > 0 and data.get("MAXDEPTH"):
            raw_perc = params.get("curdepth_perc")
            if raw_perc:
                perc_warn = raw_perc[0] if len(raw_perc) > 0 else None
                perc_crit = raw_perc[1] if len(raw_perc) > 1 else None
                used_perc = float(cur_depth) / max_depth * 100
                metrics["curdepth_perc"] = used_perc
                if perc_crit != None and used_perc >= perc_crit:
                    state = "CRIT"
                elif perc_warn != None and used_perc >= perc_warn and state != "CRIT":
                    state = "WARN"

    if "MSGAGE" in data:
        msg_age = int(data["MSGAGE"]) if data["MSGAGE"] else None
        if msg_age != None:
            metrics["msgage"] = msg_age
            msgage_levels = params.get("msgage")
            if msgage_levels:
                ma_warn = msgage_levels[0] if len(msgage_levels) > 0 else None
                ma_crit = msgage_levels[1] if len(msgage_levels) > 1 else None
                if ma_crit != None and msg_age >= ma_crit:
                    state = "CRIT"
                elif ma_warn != None and msg_age >= ma_warn and state != "CRIT":
                    state = "WARN"

    if "QTIME" in data:
        qt = data["QTIME"]
        parts = qt.split(",")
        if len(parts) >= 2:
            qshort = parts[0].strip()
            qlong = parts[1].strip()
            if qshort and qshort != "999999999":
                metrics["qtime_short"] = int(qshort) / 1000000.0
            if qlong and qlong != "999999999":
                metrics["qtime_long"] = int(qlong) / 1000000.0

    parts = item.split(":", 1)
    msg = "Queue %s depth %s" % (parts[1], str(data.get("CURDEPTH", "n/a")))
    if state != "OK":
        msg = msg + " (" + state + ")"

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}