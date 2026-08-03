def main(ctx, params):
    # READ-ONLY Starlark module for the yolo-man agent.
    # Mirrors Checkmk's solaris_prtdiag_status check.
    # It runs `prtdiag -v` to obtain the Solaris hardware overall state.
    # Discovery is only offered on hosts where the real source exists.

    # The Solaris `prtdiag` command is the real data source here. We probe
    # for it first — absence means this check does not apply.
    # `prtdiag -v` prints verbose hardware diagnostics; the first numeric
    # line in prtdiag's summary reflects the system-wide failure state.
    # Checkmk's agent plugin captures the prtdiag exit / a status line.
    # We reproduce by reading prtdiag directly.

    is_discovery = params.get("_discover")
    if is_discovery:
        # PROBE FOR THE REAL THING: solaris prtdiag binary on the host.
        probe = ctx.run(["/usr/sbin/prtdiag", "-v"], mutates=False)
        if probe.rc == 127:
            # Not installed / not Solaris (or not in PATH) -> not applicable.
            return {"changed": False, "msg": "no prtdiag found", "data": {"discovery": []}}
        # If prtdiag exists but errored, the check still does not apply.
        if probe.rc != 0 and probe.stdout == "":
            return {"changed": False, "msg": "prtdiag not usable", "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered Hardware Overall State",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                    }
                ]
            },
        }

    # CHECK MODE for the single (item "") service.
    item = params.get("item", "")

    res = ctx.run(["/usr/sbin/prtdiag", "-v"], mutates=False)
    # Absence -> UNKNOWN, never OK / never a zero metric.
    if res.rc == 127:
        return {
            "changed": False,
            "msg": "prtdiag command not found on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if res.rc != 0:
        # prtdiag failed; we have no real data.
        return {
            "changed": False,
            "msg": "prtdiag failed: %s" % res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    out = res.stdout
    if not out:
        return {
            "changed": False,
            "msg": "prtdiag produced no output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Reproduce the agent section parsing: `<<<solaris_prtdiag_status>>>`
    # held a single token (0 = OK, 1 = failures). The prtdiag status line
    # appears as a line containing the overall system status. We look for
    # the summary "Status" line that prtdiag emits at the top of its output.
    status_value = None
    for line in out.splitlines():
        stripped = line.strip()
        # prtdiag -v prints a header; the relevant value is the numeric
        # field on a short summary line. We mimic the agent which stored
        # exactly the integer status token.
        if stripped == "0":
            status_value = 0
            break
        if stripped == "1":
            status_value = 1
            break
        # Also tolerate a "Status: 0" style line if present.
        if stripped.startswith("Status:"):
            rest = stripped[len("Status:"):].strip()
            if rest == "0":
                status_value = 0
                break
            if rest == "1":
                status_value = 1
                break

    # If prtdiag ran fine but we could not locate the status token, report
    # UNKNOWN — every state must be backed by actual data read.
    if status_value == None:
        return {
            "changed": False,
            "msg": "could not determine hardware status from prtdiag output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if status_value == 0:
        return {
            "changed": False,
            "msg": "No failures or errors are reported",
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }
    return {
        "changed": False,
        "msg": 'Failures or errors are reported by the system. Please check the output of "prtdiag -v" for details.',
        "data": {"state": "CRIT", "metrics": {}, "details": ""},
    }