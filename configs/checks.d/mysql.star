def main(ctx, params):
    # Read MySQL status variables from mysqladmin
    res = ctx.run(["mysqladmin", "status"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Failed to get MySQL status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse simple key: value output from mysqladmin status
    # Example: Uptime: 12345  Threads: 2  Questions: 123456  Slow queries: 0 ...
    lines = res.stdout.strip().split("\n")
    if not lines:
        return {
            "changed": False,
            "msg": "No output from mysqladmin status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status_dict = {}
    # First line may contain uptime info in format like:
    # Uptime: 12345  Threads: 2  Questions: 123456  Slow queries: 0 ...
    # or may be multi-line
    for line in lines:
        parts = line.split(":")
        if len(parts) >= 2:
            key = parts[0].strip()
            value = ":".join(parts[1:]).strip()
            # Try to parse as int
            if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
                status_dict[key] = int(value)
            else:
                status_dict[key] = value

    # For discovery mode: find MySQL version
    if params.get("_discover"):
        # Use SHOW VARIABLES for version if available, otherwise fallback to status
        version = ""
        if "Uptime" in status_dict:
            # Run mysqladmin version to get more info
            ver_res = ctx.run(["mysqladmin", "version"], mutates=False)
            if ver_res.rc == 0:
                ver_lines = ver_res.stdout.splitlines()
                for line in ver_lines:
                    if line.startswith("Server version"):
                        version = line.split(":", 1)[1].strip()
                        break

        # If still no version, try from status output
        if not version and "Threads" in status_dict:
            # We have some status, assume we can discover
            version = status_dict.get("Server version", "")

        # If still no version, we can't discover properly
        if not version:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }

        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": []}
            ]},
        }

    # Check mode (non-discovery)
    # Get version from mysqladmin version for the service
    res_version = ctx.run(["mysqladmin", "version"], mutates=False)
    version = ""
    if res_version.rc == 0:
        lines = res_version.stdout.splitlines()
        for line in lines:
            if line.startswith("Server version"):
                version = line.split(":", 1)[1].strip()
                break

    if not version:
        return {
            "changed": False,
            "msg": "Could not determine MySQL version",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "Version: %s" % version,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": "",
        },
    }