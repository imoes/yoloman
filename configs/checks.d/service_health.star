def main(ctx, params):
    # Generic role-health check: is a systemd unit active (and enabled)?
    # Auto-assigned by the Roles & Features wizard for a freshly installed role,
    # configured from the role's own service variable. Read-only (systemctl
    # is-active / is-enabled), so it needs no write gate.
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    unit = params.get("unit") or ""
    if not unit:
        return {"changed": False, "msg": "UNKNOWN", "data": {"state": "UNKNOWN", "metrics": {}, "details": "no unit configured"}}

    active = ctx.run(["systemctl", "is-active", unit], mutates=False, ok_codes=[0, 1, 2, 3, 4])
    state_word = (active.stdout or "").strip() or (active.stderr or "").strip()

    enabled = ctx.run(["systemctl", "is-enabled", unit], mutates=False, ok_codes=[0, 1, 2, 3, 4])
    enabled_word = (enabled.stdout or "").strip()

    if state_word == "active":
        state = "OK"
    elif state_word in ("activating", "reloading", "deactivating"):
        state = "WARN"
    else:
        state = "CRIT"

    # Optionally require the unit to be enabled (start on boot).
    if params.get("require_enabled", False) and enabled_word not in ("enabled", "enabled-runtime", "static", "indirect", "alias"):
        if state == "OK":
            state = "WARN"

    detail = "%s is %s (%s)" % (unit, state_word or "unknown", enabled_word or "?")
    return {"changed": False, "msg": state, "data": {
        "state": state,
        "metrics": {"active": 1 if state_word == "active" else 0},
        "details": detail,
    }}
