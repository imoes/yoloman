def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base = ".1.3.6.1.4.1.12532"
        mem_oid = base + ".11"
        swap_oid = base + ".24"
        mem_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, mem_oid], mutates=False)
        swap_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, swap_oid], mutates=False)
        section = {}
        if mem_res.rc == 0:
            raw = mem_res.stdout.strip()
            if raw:
                section["mem_used_percent"] = int(raw)
        if swap_res.rc == 0:
            raw = swap_res.stdout.strip()
            if raw:
                section["swap_used_percent"] = int(raw)
        if not section:
            return {"changed": False, "msg": "no Pulse Secure device found", "data": {"discovery": []}}
        metrics = []
        if "mem_used_percent" in section:
            metrics.append("mem_used_percent")
        if "swap_used_percent" in section:
            metrics.append("swap_used_percent")
        return {"changed": False, "msg": "discovered Pulse Secure IVE memory utilization", "data": {"discovery": [{"item": "", "params": params.get("params", {"mem_used_percent": (90, 95), "swap_used_percent": (5, 101)}), "metrics": metrics}]}}
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.12532"
    mem_oid = base + ".11"
    swap_oid = base + ".24"
    mem_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, mem_oid], mutates=False)
    swap_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, swap_oid], mutates=False)
    section = {}
    if mem_res.rc == 0:
        raw = mem_res.stdout.strip()
        if raw:
            section["mem_used_percent"] = int(raw)
    if swap_res.rc == 0:
        raw = swap_res.stdout.strip()
        if raw:
            section["swap_used_percent"] = int(raw)
    if not section:
        return {"changed": False, "msg": "no Pulse Secure device found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    metrics_out = {}
    details = []
    summary_parts = []
    state = "OK"
    if "mem_used_percent" in section:
        val = section["mem_used_percent"]
        levels = params.get("mem_used_percent", (90, 95))
        warn = levels[0] if levels else 90
        crit = levels[1] if levels else 95
        m_state = "CRIT" if val >= crit else ("WARN" if val >= warn else "OK")
        if m_state == "CRIT" or (m_state == "WARN" and state != "CRIT"):
            state = m_state
        metrics_out["mem_used_percent"] = val
        details.append("RAM used: %d%%" % val)
        summary_parts.append("RAM used: %d%%" % val)
    if "swap_used_percent" in section:
        val = section["swap_used_percent"]
        levels = params.get("swap_used_percent", (5, 101))
        warn = levels[0] if levels else 5
        crit = levels[1] if levels else 101
        m_state = "CRIT" if val >= crit else ("WARN" if val >= warn else "OK")
        if m_state == "CRIT" or (m_state == "WARN" and state != "CRIT"):
            state = m_state
        metrics_out["swap_used_percent"] = val
        details.append("Swap used: %d%%" % val)
        summary_parts.append("Swap used: %d%%" % val)
    return {"changed": False, "msg": ", ".join(summary_parts), "data": {"state": state, "metrics": metrics_out, "details": "\n".join(details)}}