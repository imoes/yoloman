def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    
    # Check if icinga2 binary exists
    res = ctx.run(["which", "icinga2"], mutates=False)
    if res.rc != 0:
        fail("icinga2 binary not found in PATH")
    
    # List features to determine current state
    res = ctx.run(["icinga2", "feature", "list"], mutates=False)
    if res.rc != 0:
        fail("Unable to list icinga2 features")
    
    # Parse output to determine if feature is enabled or disabled
    enabled = False
    disabled = False
    for line in res.stdout.splitlines():
        if line.startswith("Enabled features:"):
            if " " + name + " " in line or line.endswith(name):
                enabled = True
        elif line.startswith("Disabled features:"):
            if " " + name + " " in line or line.endswith(name):
                disabled = True
    
    # Determine if change is needed
    if state == "present" and enabled:
        return {"changed": False, "msg": "Feature " + name + " already enabled"}
    if state == "absent" and disabled:
        return {"changed": False, "msg": "Feature " + name + " already disabled"}
    
    # In check_mode and change needed
    if ctx.check_mode:
        return {"changed": True, "msg": "would " + ("enable" if state == "present" else "disable") + " feature " + name}
    
    # Perform the actual change
    cmd = ["icinga2", "feature", "enable" if state == "present" else "disable", name]
    res = ctx.run(cmd, mutates=True)
    
    if res.rc != 0 and state == "present":
        fail("Failed to enable feature " + name + ": " + res.stderr)
    
    # For disable, rc != 0 might mean already disabled (which is ok)
    if state == "absent" and res.rc != 0:
        if "Cannot disable feature" in res.stderr and "does not exist" in res.stderr:
            return {"changed": False, "msg": "Feature " + name + " was not enabled"}
        fail("Failed to disable feature " + name + ": " + res.stderr)
    
    return {"changed": True, "msg": "Feature " + name + " " + ("enabled" if state == "present" else "disabled")}
