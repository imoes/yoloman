def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["dspmq", "-a", "-m", "*"], mutates=False)
        sections = {}
        current_qmgr = None
        current_queue = None
        lines = res.stdout.splitlines()
        for line in lines:
            line = line.strip()
            if not line:
                continue
            if line.startswith("QMNAME(") and "STATUS(" in line:
                start = line.find("QMNAME(") + 7
                end = line.find(")", start)
                if end != -1:
                    qmgr = line[start:end]
                    current_qmgr = qmgr
                    sections[qmgr] = {"NOW": "", "STATUS": ""}
                    s_start = line.find("STATUS(") + 7
                    s_end = line.find(")", s_start)
                    if s_end != -1:
                        sections[qmgr]["STATUS"] = line[s_start:s_end]
            elif line.startswith("QUEUE(") and current_qmgr:
                start = line.find("QUEUE(") + 6
                end = line.find(")", start)
                if end != -1:
                    queue_name = line[start:end]
                    current_queue = current_qmgr + ":" + queue_name
                    sections[current_queue] = {}
            elif current_queue and "=" in line:
                idx = line.find("=")
                key = line[:idx].strip()
                val = line[idx+1:].strip()
                if val.startswith("(") and val.endswith(")"):
                    val = val[1:-1]
                if key in ("LGETTIME", "LPUTTIME", "LPUTDATE"):
                    val = val.replace(".", ":")
                sections[current_queue][key] = val
        now = ctx.run(["date", "+%Y-%m-%dT%H:%M:%S"], mutates=False)
        now_ts = now.stdout.strip()
        for qmgr in sections:
            if ":" not in qmgr:
                sections[qmgr]["NOW"] = now_ts
        items = []
        for svc_name in sections:
            if ":" not in svc_name:
                continue
            items.append({"item": svc_name, "params": {}, "metrics": [
                "curdepth", "msgage", "lgetage", "lputage",
                "ipprocs", "opprocs", "qtime_short", "qtime_long"
            ]})
        return {"changed": False, "msg": "discovered %d queues" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    res = ctx.run(["dspmq", "-a", "-m", "*"], mutates=False)
    sections = {}
    current_qmgr = None
    current_queue = None
    lines = res.stdout.splitlines()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if line.startswith("QMNAME(") and "STATUS(" in line:
            start = line.find("QMNAME(") + 7
            end = line.find(")", start)
            if end != -1:
                qmgr = line[start:end]
                current_qmgr = qmgr
                sections[qmgr] = {"NOW": "", "STATUS": ""}
                s_start = line.find("STATUS(") + 7
                s_end = line.find(")", s_start)
                if s_end != -1:
                    sections[qmgr]["STATUS"] = line[s_start:s_end]
        elif line.startswith("QUEUE(") and current_qmgr:
            start = line.find("QUEUE(") + 6
            end = line.find(")", start)
            if end != -1:
                queue_name = line[start:end]
                current_queue = current_qmgr + ":" + queue_name
                sections[current_queue] = {}
        elif current_queue and "=" in line:
            idx = line.find("=")
            key = line[:idx].strip()
            val = line[idx+1:].strip()
            if val.startswith("(") and val.endswith(")"):
                val = val[1:-1]
            if key in ("LGETTIME", "LPUTTIME", "LPUTDATE"):
                val = val.replace(".", ":")
            sections[current_queue][key] = val
    now = ctx.run(["date", "+%Y-%m-%dT%H:%M:%S"], mutates=False)
    now_ts = now.stdout.strip()
    for qmgr in sections:
        if ":" not in qmgr:
            sections[qmgr]["NOW"] = now_ts

    if item not in sections:
        return {"changed": False, "msg": "queue not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = sections[item]
    qmgr_name = item.split(":", 1)[0]

    if qmgr_name in sections and sections[qmgr_name].get("STATUS") != "RUNNING":
        return {"changed": False, "msg": "queue manager %s not RUNNING" % qmgr_name,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if qmgr_name in sections and sections[qmgr_name].get("STATUS") == "RUNNING" and item not in sections:
        return {"changed": False, "msg": "queue %s vanished" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cur_depth = data.get("CURDEPTH")
    max_depth = data.get("MAXDEPTH")
    msg_age = data.get("MSGAGE")
    lget_date = data.get("LGETDATE")
    lget_time = data.get("LGETTIME")
    lput_date = data.get("LPUTDATE")
    lput_time = data.get("LPUTTIME")
    ipprocs = data.get("IPPROCS")
    opprocs = data.get("OPPROCS")
    qtimes = data.get("QTIME")

    def parse_dt(date_str, time_str, agent_ts):
        if not (date_str and time_str):
            return None
        dt_str = "%s %s" % (date_str, time_str.replace(".", ":"))
        parts = dt_str.split()
        if len(parts) < 2:
            return None
        d_parts = parts[0].split("-")
        if len(d_parts) != 3:
            return None
        year = int(d_parts[0]) if d_parts[0].lstrip("-").isdigit() else -1
        month = int(d_parts[1]) if d_parts[1].isdigit() else -1
        day = int(d_parts[2]) if d_parts[2].isdigit() else -1
        t_parts = parts[1].split(":")
        if len(t_parts) < 3:
            return None
        hour = int(t_parts[0]) if t_parts[0].isdigit() else -1
        minute = int(t_parts[1]) if t_parts[1].isdigit() else -1
        sec = int(t_parts[2]) if t_parts[2].isdigit() else -1
        if year == -1 or month == -1 or day == -1 or hour == -1 or minute == -1 or sec == -1:
            return None
        agent_dt_str = agent_ts.replace("T", " ")
        agent_dt_parts = agent_dt_str.split(":")
        if len(agent_dt_parts) < 3:
            return None
        agent_date_part = agent_dt_parts[0]
        agent_date_parts = agent_date_part.split("-")
        if len(agent_date_parts) != 2:
            return None
        agent_year = int(agent_date_parts[0])
        agent_month = int(agent_date_parts[1])
        agent_day = int(agent_date_parts[2])
        agent_hour = int(agent_dt_parts[1])
        agent_minute = int(agent_dt_parts[2])
        agent_sec = int(agent_dt_parts[3]) if len(agent_dt_parts) > 3 else 0
        input_sec = sec + minute * 60 + hour * 3600 + day * 86400 + month * 2678400 + year * 32140800
        agent_sec_total = agent_sec + agent_minute * 60 + agent_hour * 3600 + agent_day * 86400 + agent_month * 2678400 + agent_year * 32140800
        age = abs(agent_sec_total - input_sec)
        return age

    state = "OK"
    msg_parts = []
    metrics = {}

    cur_depth_int = int(cur_depth) if (cur_depth and cur_depth.lstrip("-").isdigit()) else None
    max_depth_int = int(max_depth) if (max_depth and max_depth.lstrip("-").isdigit()) else None
    val = cur_depth_int if cur_depth_int != None else 0

    raw_abs = params.get("curdepth")
    abs_warn, abs_crit = (None, None) if not (raw_abs and len(raw_abs) >= 2) else (raw_abs[0], raw_abs[1])
    abs_level_pair = (int(abs_warn), int(abs_crit)) if (abs_warn != None and abs_crit != None and abs_warn.lstrip("-").isdigit() and abs_crit.lstrip("-").isdigit()) else None

    if abs_level_pair != None:
        if val >= abs_level_pair[1]:
            state = "CRIT"
        elif val >= abs_level_pair[0]:
            state = "WARN"
        metrics["curdepth"] = val
        msg_parts.append("Queue depth: %d" % val)
    else:
        metrics["curdepth"] = val
        msg_parts.append("Queue depth: %d" % val)

    if cur_depth_int != None and max_depth_int != None and max_depth_int != 0:
        raw_perc = params.get("curdepth_perc")
        if raw_perc and len(raw_perc) >= 2:
            perc_warn, perc_crit = raw_perc[0], raw_perc[1]
            if perc_warn != None and perc_crit != None:
                used_perc = float(cur_depth_int) / float(max_depth_int) * 100.0
                if used_perc >= perc_crit:
                    state = "CRIT"
                elif used_perc >= perc_warn:
                    state = "WARN"
                metrics["curdepth_perc"] = used_perc
        else:
            used_perc = float(cur_depth_int) / float(max_depth_int) * 100.0
            metrics["curdepth_perc"] = used_perc

    if msg_age and msg_age.isdigit():
        age = int(msg_age)
        msgage_levels = params.get("msgage")
        if msgage_levels and len(msgage_levels) >= 2:
            msg_warn, msg_crit = msgage_levels[0], msgage_levels[1]
            if age >= msg_crit:
                state = "CRIT"
            elif age >= msg_warn:
                state = "WARN"
            metrics["msgage"] = age
            msg_parts.append("Oldest message: %d s" % age)
        else:
            metrics["msgage"] = age
            msg_parts.append("Oldest message: %d s" % age)
    else:
        msg_parts.append("Oldest message: n/a")

    agent_ts = sections[qmgr_name]["NOW"] if qmgr_name in sections else ""
    lget_age = parse_dt(lget_date, lget_time, agent_ts)
    lget_levels = params.get("lgetage")
    if lget_age != None:
        if lget_levels and len(lget_levels) >= 2:
            lg_warn, lg_crit = lget_levels[0], lget_levels[1]
            if lget_age >= lg_crit:
                state = "CRIT"
            elif lget_age >= lg_warn:
                state = "WARN"
            metrics["lgetage"] = lget_age
            msg_parts.append("Last get: %d s" % lget_age)
        else:
            metrics["lgetage"] = lget_age
            msg_parts.append("Last get: %d s" % lget_age)
    else:
        msg_parts.append("Last get: n/a")

    lput_age = parse_dt(lput_date, lput_time, agent_ts)
    lput_levels = params.get("lputage")
    if lput_age != None:
        if lput_levels and len(lput_levels) >= 2:
            lp_warn, lp_crit = lput_levels[0], lput_levels[1]
            if lput_age >= lp_crit:
                state = "CRIT"
            elif lput_age >= lp_warn:
                state = "WARN"
            metrics["lputage"] = lput_age
            msg_parts.append("Last put: %d s" % lput_age)
        else:
            metrics["lputage"] = lput_age
            msg_parts.append("Last put: %d s" % lput_age)
    else:
        msg_parts.append("Last put: n/a")

    if ipprocs and ipprocs.isdigit():
        cnt = int(ipprocs)
        ipp_levels = params.get("ipprocs")
        if ipp_levels and type(ipp_levels) == "dict":
            if "upper" in ipp_levels:
                upp = ipp_levels["upper"]
                if len(upp) == 2:
                    if cnt >= upp[1]:
                        state = "CRIT"
                    elif cnt >= upp[0]:
                        state = "WARN"
            if "lower" in ipp_levels:
                low = ipp_levels["lower"]
                if len(low) == 2:
                    if cnt <= low[1]:
                        state = "CRIT"
                    elif cnt <= low[0]:
                        state = "WARN"
        metrics["ipprocs"] = cnt
        msg_parts.append("Input handles: %d" % cnt)

    if opprocs and opprocs.isdigit():
        cnt = int(opprocs)
        opp_levels = params.get("opprocs")
        if opp_levels and type(opp_levels) == "dict":
            if "upper" in opp_levels:
                upp = opp_levels["upper"]
                if len(upp) == 2:
                    if cnt >= upp[1]:
                        state = "CRIT"
                    elif cnt >= upp[0]:
                        state = "WARN"
            if "lower" in opp_levels:
                low = opp_levels["lower"]
                if len(low) == 2:
                    if cnt <= low[1]:
                        state = "CRIT"
                    elif cnt <= low[0]:
                        state = "WARN"
        metrics["opprocs"] = cnt
        msg_parts.append("Output handles: %d" % cnt)

    if qtimes:
        idx = qtimes.find(",")
        if idx != -1:
            qtime_short = qtimes[:idx].strip()
            qtime_long = qtimes[idx+1:].strip()
            if qtime_short.isdigit():
                if qtime_short == "999999999":
                    qs_sec = 0.0
                else:
                    qs_sec = float(int(qtime_short)) / 1000000.0
                metrics["qtime_short"] = qs_sec
                msg_parts.append("Qtime short: %f s" % qs_sec)
            if qtime_long.isdigit():
                if qtime_long == "999999999":
                    ql_sec = 0.0
                else:
                    ql_sec = float(int(qtime_long)) / 1000000.0
                metrics["qtime_long"] = ql_sec
                msg_parts.append("Qtime long: %f s" % ql_sec)

    return {
        "changed": False,
        "msg": ", ".join(msg_parts) if msg_parts else "no metrics",
        "data": {"state": state, "metrics": metrics, "details": ""},
    }