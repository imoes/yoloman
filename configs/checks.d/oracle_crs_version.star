# Oracle CRS version check (read-only Starlark)
# Translates: cmk.plugins.oracle.agent_based.oracle_crs_version

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Read agent data for oracle_crs_version section
    # The Checkmk agent produces <<<oracle_crs_version>>>, we simulate that by
    # running the same command the Checkmk agent plugin uses: crsctl query crs releasepatch
    # (standard way to get Oracle Grid Infrastructure version)
    res = ctx.run(["crsctl", "query", "crs", "releasepatch"], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "No version details found. Maybe the CSSD is not running",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    lines = res.stdout.splitlines()
    if not lines:
        return {
            "changed": False,
            "msg": "No version details found. Maybe the CSSD is not running",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    version_line = lines[0].strip() if lines[0].strip() else "Unknown"
    
    return {
        "changed": False,
        "msg": version_line,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": ""
        }
    }