def _worst_state(states):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    # also handle None/missing
    def lvl(s):
        return order.get(s, 3)
    worst = "OK"
    for s in states:
        if lvl(s) > lvl(worst):
            worst = s
    return worst

_MAP_PG_STATES = {
    "active":            ("OK", "active"),
    "backfill":          ("OK", "backfill"),
    "backfill_wait":     ("WARN", "backfill wait"),
    "backfilling":       ("WARN", "backfilling"),
    "backfill_toofull":  ("OK", "backfill too full"),
    "clean":             ("OK", "clean"),
    "creating":          ("OK", "creating"),
    "degraded":          ("WARN", "degraded"),
    "down":              ("CRIT", "down"),
    "deep":              ("OK", "deep"),
    "incomplete":        ("CRIT", "incomplete"),
    "inconsistent":      ("CRIT", "inconsistent"),
    "peered":            ("CRIT", "peered"),
    "peering":           ("OK", "peering"),
    "recovering":        ("OK", "recovering"),
    "recovery_wait":     ("OK", "recovery wait"),
    "remapped":          ("OK", "remapped"),
    "repair":            ("OK", "repair"),
    "replay":            ("WARN", "replay"),
    "scrubbing":         ("OK", "scrubbing"),
    "snaptrim":          ("OK", "snaptrim"),
    "snaptrim_wait":     ("OK", "snaptrim wait"),
    "stale":             ("CRIT", "stale"),
    "undersized":        ("OK", "undersized"),
    "wait_backfill":     ("OK", "wait backfill"),
}

def main(ctx, params):
    bin_res = ctx.run(["ceph", "--version"], mutates=False)
    ceph_present = bin_res.rc == 0

    if params.get("_discover"):
        if not ceph_present:
            return {"changed": False, "msg": "ceph not installed", "data": {"discovery": []}}
        # single-service check; one entry with item ""
        return {
            "changed": False,
            "msg": "discovered Ceph PGs",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": ["pg_count"]},
                ],
            },
        }

    item = params.get("item", "")

    if not ceph_present:
        return {
            "changed": False,
            "msg": "no ceph instance found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = ctx.run(["ceph", "status", "--format", "json"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "ceph status failed: %s" % res.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = json.decode(res.stdout)

    pgmap = section.get("pgmap")
    if pgmap == None:
        return {
            "changed": False,
            "msg": "no pgmap in ceph status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    num_pgs = pgmap.get("num_pgs", 0)
    lines = ["PGs: %s" % num_pgs]
    states_seen = []
    total_state = "OK"

    for entry in pgmap.get("pgs_by_state", []):
        name = entry.get("state_name", "")
        count = entry.get("count", 0)
        statetexts = []
        states = []
        for tok in name.split("+"):
            mapped = _MAP_PG_STATES.get(tok, ("UNKNOWN", "UNKNOWN[%s]" % tok))
            states.append(mapped[0])
            statetexts.append(mapped[1])
        if states:
            s = _worst_state(states)
            states_seen.append(s)
            total_state = _worst_state([total_state, s])
        lines.append("Status '%s': %s" % ("+".join(statetexts), count))

    return {
        "changed": False,
        "msg": ", ".join(lines),
        "data": {
            "state": total_state,
            "metrics": {"pg_count": num_pgs},
            "details": "\n".join(lines),
        },
    }