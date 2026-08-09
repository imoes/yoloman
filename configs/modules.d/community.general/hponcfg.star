def main(ctx, params):
    executable = params.get("executable", "hponcfg")
    src = params.get("path")
    minfw = params.get("minfw")
    verbose = params.get("verbose", False)

    if src == None:
        fail("path is required")

    # Build command
    argv = [executable, "-f", src]
    if verbose:
        argv.append("-v")
    if minfw != None:
        argv.extend(["-m", minfw])

    # Run hponcfg - mutates=True because it writes to iLO config
    res = ctx.run(argv, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would configure HP iLO"}
    if res.rc != 0:
        fail("hponcfg failed: " + res.stderr)

    return {"changed": True, "msg": "HP iLO configured successfully"}
