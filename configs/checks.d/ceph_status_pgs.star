def main(ctx, params):
    # Discovery is disabled for this check plugin
    if params.get("_discover"):
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
    
    # Run the ceph status probe (JSON output)
    res = ctx.run(["ceph", "status", "-f", "json-pretty"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to fetch ceph status: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    section = json.decode(res.stdout)
    
    # Extract pgmap data
    data = section.get("pgmap", {})
    num_pgs = data.get("num_pgs", 0)
    
    # Map Checkmk state names to Starlark State values
    map_pg_states = {
        "active": ("OK", "active"),
        "backfill": ("OK", "backfill"),
        "backfill_wait": ("WARN", "backfill wait"),
        "backfilling": ("WARN", "backfilling"),
        "backfill_toofull": ("OK", "backfill too full"),
        "clean": ("OK", "clean"),
        "creating": ("OK", "creating"),
        "degraded": ("WARN", "degraded"),
        "down": ("CRIT", "down"),
        "deep": ("OK", "deep"),
        "incomplete": ("CRIT", "incomplete"),
        "inconsistent": ("CRIT", "inconsistent"),
        "peered": ("CRIT", "peered"),
        "peering": ("OK", "peering"),
        "recovering": ("OK", "recovering"),
        "recovery_wait": ("OK", "recovery wait"),
        "remapped": ("OK", "remapped"),
        "repair": ("OK", "repair"),
        "replay": ("WARN", "replay"),
        "scrubbing": ("OK", "scrubbing"),
        "snaptrim": ("OK", "snaptrim"),
        "snaptrim_wait": ("OK", "snaptrim wait"),
        "stale": ("CRIT", "stale"),
        "undersized": ("OK", "undersized"),
        "wait_backfill": ("OK", "wait backfill"),
    }
    
    # Base summary
    summary_parts = ["PGs: %s" % str(num_pgs)]
    worst_state = "OK"
    
    # Process pgs_by_state
    pgs_by_state_list = data.get("pgs_by_state", [])
    for item in pgs_by_state_list:
        state_name = item.get("state_name", "")
        count = item.get("count", 0)
        if count == 0:
            continue
        
        # Split state_name by '+'
        status_list = state_name.split("+")
        states = []
        statetexts = []
        
        for status in status_list:
            status = status.strip()
            state, state_readable = map_pg_states.get(
                status, ("UNKNOWN", "UNKNOWN[%s]" % status)
            )
            states.append(state)
            statetexts.append(state_readable)
        
        # Determine worst state for this group
        group_state = "OK"
        for s in states:
            if s == "CRIT":
                group_state = "CRIT"
            elif s == "WARN" and group_state != "CRIT":
                group_state = "WARN"
            elif s == "UNKNOWN" and group_state == "OK":
                group_state = "UNKNOWN"
        
        # Update overall worst state
        if group_state == "CRIT":
            worst_state = "CRIT"
        elif group_state == "WARN" and worst_state != "CRIT":
            worst_state = "WARN"
        elif group_state == "UNKNOWN" and worst_state == "OK":
            worst_state = "UNKNOWN"
        
        summary_parts.append("Status '%s': %s" % ("+".join(statetexts), str(count)))
    
    msg = ", ".join(summary_parts)
    
    return {"changed": False, "msg": msg,
            "data": {"state": worst_state, "metrics": {}, "details": ""}}
