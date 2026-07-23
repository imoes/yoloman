def main(ctx, params):
    # Check if podman is installed
    res_which = ctx.run(["which", "podman"], mutates=False)
    if res_which.rc != 0:
        return {
            "changed": False,
            "msg": "Podman is not installed",
            "data": {
                "state": "OK",
                "metrics": {},
                "details": ""
            }
        }
    
    # Try to get podman info
    res_info = ctx.run(["podman", "info", "--format", "json"], mutates=False)
    
    if res_info.rc == 0:
        if not res_info.stdout:
            # No stdout - check stderr for errors
            if res_info.stderr.strip():
                return {
                    "changed": False,
                    "msg": "Errors: 1, see details",
                    "data": {
                        "state": "CRIT",
                        "metrics": {},
                        "details": res_info.stderr.strip()
                    }
                }
            # No errors
            return {
                "changed": False,
                "msg": "No errors",
                "data": {
                    "state": "OK",
                    "metrics": {},
                    "details": ""
                }
            }
        
        # Attempt JSON decode with guard - if stdout starts with '{' assume valid JSON
        data = None
        if res_info.stdout.startswith("{"):
            data = json.decode(res_info.stdout)
        
        # Check if decode succeeded
        if data == None:
            # Fallback: treat stderr as error if present
            if res_info.stderr.strip():
                return {
                    "changed": False,
                    "msg": "Errors: 1, see details",
                    "data": {
                        "state": "CRIT",
                        "metrics": {},
                        "details": res_info.stderr.strip()
                    }
                }
            return {
                "changed": False,
                "msg": "No errors",
                "data": {
                    "state": "OK",
                    "metrics": {},
                    "details": ""
                }
            }
        
        # Build errors list
        errors = []
        
        # Check warnings field if present
        if "warnings" in data:
            warnings_list = data.get("warnings")
            if type(warnings_list) == "list":
                for i in range(len(warnings_list)):
                    w = warnings_list[i]
                    errors.append({"endpoint": "warnings", "message": str(w)})
        
        # Check errors field if present
        if "errors" in data:
            errors_list = data.get("errors")
            if type(errors_list) == "list":
                for i in range(len(errors_list)):
                    e = errors_list[i]
                    errors.append({"endpoint": "errors", "message": str(e)})
        
        # Return result based on errors
        if len(errors) == 0:
            return {
                "changed": False,
                "msg": "No errors",
                "data": {
                    "state": "OK",
                    "metrics": {},
                    "details": ""
                }
            }
        
        # Format details
        detail_lines = []
        for i in range(len(errors)):
            err = errors[i]
            detail_lines.append("%s: %s" % (err["endpoint"], err["message"]))
        
        return {
            "changed": False,
            "msg": "Errors: %d, see details" % len(errors),
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": "\n".join(detail_lines)
            }
        }
    else:
        # podman info failed
        stderr_msg = res_info.stderr.strip() if res_info.stderr.strip() else "podman info failed"
        return {
            "changed": False,
            "msg": "Errors: 1, see details",
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": stderr_msg
            }
        }