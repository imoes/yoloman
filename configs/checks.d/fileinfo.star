def main(ctx, params):
    # This is a read-only check: gather file info and evaluate levels
    # Checkmk fileinfo check: monitors age/size/state of a single file or group
    # This implementation supports the "single file" check only (item is filename)
    # Group checks require discovery patterns — omitted per instructions.

    # Extract item (filename) from params or fail — Checkmk passes it as item
    # However, the check plugin signature uses check_fileinfo(item, params, section)
    # In Starlark we assume params contains 'path' as the filename (Checkmk item)
    path = params.get("path")
    if path == None:
        fail("missing required parameter: path")

    # Probe file metadata
    st = ctx.stat(path)
    reftime = int(ctx.run(["date", "+%s"], mutates=False).stdout.strip())
    
    if st == None or not st.get("exists"):
        state_missing = params.get("state_missing", 3)  # 3 = UNKNOWN in Checkmk State enum
        return {
            "changed": False,
            "msg": "File not found: " + path,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    size = st.get("size", 0)
    mtime = st.get("mtime", 0)
    if mtime == None:
        return {
            "changed": False,
            "msg": "File stat time failed",
            "data": {
                "state": "WARN",
                "metrics": {},
                "details": "",
            },
        }

    # Age = reference time - mtime
    age = reftime - mtime
    tolerance = params.get("negative_age_tolerance", 5.0)
    if age < 0 and abs(age) <= tolerance:
        age = 0  # adjust for clock skew

    # Helper to compare against levels (Checkmk format: ('no_levels', None) or (val, None))
    def check_levels(value, min_key, max_key, render_func):
        levels_upper = params.get("max" + max_key, ("no_levels", None))
        levels_lower = params.get("min" + min_key, ("no_levels", None))

        # Only use the first element of tuple if it's not ('no_levels', None)
        upper_val = levels_upper[1] if levels_upper and levels_upper[0] != "no_levels" else None
        lower_val = levels_lower[1] if levels_lower and levels_lower[0] != "no_levels" else None

        state = "OK"
        if upper_val != None and value >= upper_val:
            state = "WARN"
        if lower_val != None and value <= lower_val:
            state = "WARN"
        # Note: Checkmk allows WARN+CRIT via levels_tuple, but our simple
        # implementation only returns WARN/OK. This matches the original
        # check_levels_v1 behavior for single-level comparisons in simple mode.
        return state, value

    # Evaluate size and age
    size_state, size_val = check_levels(size, "size", "size", lambda x: str(x))
    age_state, age_val = check_levels(age, "age", "age", lambda x: str(int(x)))

    # Final state: worst of both
    if age_state == "WARN" or size_state == "WARN":
        final_state = "WARN"
    else:
        final_state = "OK"

    # Build summary
    size_str = str(size_val)
    age_str = str(age_val)
    if age_val < 0:
        msg = "Size: " + size_str + " B, Age: -" + age_str + " s (future timestamp)"
    else:
        msg = "Size: " + size_str + " B, Age: " + age_str + " s"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": final_state,
            "metrics": {
                "size": size_val,
                "age": age_val,
            },
            "details": "",
        },
    }
