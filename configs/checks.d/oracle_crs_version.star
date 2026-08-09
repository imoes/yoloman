def _has_oracle_crs_params(ctx):
    """Return list of (grid_home, version_output) by probing the OS for Oracle Grid Infrastructure."""
    results = []
    grid_home = None
    # Probe for Oracle Grid Infrastructure presence
    stat = ctx.stat("/u01/app/19.0.0/grid")
    if stat.exists and stat.is_dir:
        grid_home = "/u01/app/19.0.0/grid"
    if grid_home == None:
        env = ctx.run(["env"], mutates=False)
        for line in env.stdout.splitlines():
            if line.startswith("GRID_HOME=") or line.startswith("ORACLE_HOME="):
                grid_home = line.split("=", 1)[1]
                if grid_home != "" and ctx.stat(grid_home).is_dir:
                    break
                grid_home = None
    if grid_home == None:
        return results
    catr = ctx.run(["cat", grid_home + "/crs/install/version.xml"], mutates=False)
    if catr.rc == 0 and catr.stdout != "":
        results.append((grid_home, catr.stdout))
    return results


def main(ctx, params):
    if params.get("_discover"):
        found = _has_oracle_crs_params(ctx)
        if len(found) == 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        out = []
        for grid_home, _version in found:
            out.append({"item": grid_home, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")

    if item == "":
        targets = _has_oracle_crs_params(ctx)
    else:
        targets = []
        stat = ctx.stat(item)
        if stat.exists and stat.is_dir:
            catr = ctx.run(["cat", item + "/crs/install/version.xml"], mutates=False)
            if catr.rc == 0 and catr.stdout != "":
                targets.append((item, catr.stdout))

    if len(targets) == 0:
        return {"changed": False,
                "msg": "No version details found. Maybe the cssd is not running",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    version_output = targets[0][1]
    lines = version_output.splitlines()
    first_line = lines[0] if len(lines) > 0 else version_output.strip()
    return {"changed": False, "msg": first_line,
            "data": {"state": "OK", "metrics": {}, "details": ""}}