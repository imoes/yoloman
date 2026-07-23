def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["objects"]}]}
        }

    # Attempt to list potential quarantine directory
    res = ctx.run(["ls", "-1", "/var/symantec/quarantine"], mutates=False, ok_codes=[0, 1, 2])

    objects_count = 0
    if res.rc == 0:
        lines = res.stdout.splitlines()
        objects_count = len([l for l in lines if len(l.strip()) > 0])

    state = "CRIT" if objects_count > 0 else "OK"
    summary = "%d objects in quarantine" % objects_count if objects_count > 0 else "No objects in quarantine"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"objects": objects_count},
            "details": "",
        },
    }