def convert_time(seconds):
    """Convert seconds into the biggest unit (UCS expects string value + unit)."""
    units = [
        (24 * 60 * 60, 'days'),
        (60 * 60, 'hours'),
        (60, 'minutes'),
        (1, 'seconds'),
    ]
    if seconds == 0:
        return "0 seconds"
    for divisor, unit in units:
        if seconds >= divisor:
            value = seconds // divisor
            return str(value) + " " + unit


def main(ctx, params):
    zone = params["zone"]
    zone_type = params["type"]
    state = params.get("state", "present")
    nameserver = params.get("nameserver", [])
    interfaces = params.get("interfaces", [])
    refresh = params.get("refresh", 3600)
    retry = params.get("retry", 1800)
    expire = params.get("expire", 604800)
    ttl = params.get("ttl", 600)
    contact = params.get("contact", "")
    mx = params.get("mx", [])

    # Validate required parameters for present state
    if state == "present":
        if len(nameserver) == 0:
            fail("nameserver is required when state is present")
        if len(interfaces) == 0:
            fail("interfaces is required when state is present")
        if zone_type not in ["forward_zone", "reverse_zone"]:
            fail("type must be 'forward_zone' or 'reverse_zone'")

    # Ensure contact defaults correctly
    if contact == "":
        contact = "root@" + zone + "."

    # Probe for existing zone using UDM search (via ctx.run)
    # We simulate LDAP search: UDM lists zones of the given type/zone name
    search_args = [
        "udm", "dns/" + zone_type,
        "--filter", "zoneName=" + zone
    ]
    res = ctx.run(search_args, mutates=False)
    if res.rc != 0 and "No such object" not in res.stderr:
        fail("Failed to list DNS zones: " + res.stderr)
    lines = res.stdout.splitlines()
    # Parse DN from UDM output lines: "DN: <dn>" lines
    dn = None
    for line in lines:
        if line.strip().startswith("DN: "):
            dn = line.strip().split(" ", 1)[1]
            break

    exists = dn != None

    # Build desired object dict to compare later (as diff simulation)
    desired = {
        "zone": zone,
        "nameserver": nameserver,
        "a": interfaces,
        "refresh": convert_time(refresh),
        "retry": convert_time(retry),
        "expire": convert_time(expire),
        "ttl": convert_time(ttl),
        "contact": contact,
        "mx": mx,
    }

    changed = False
    msg = ""
    diff = None

    if state == "present":
        if exists:
            # Fetch current values (simple object show)
            show_args = ["udm", "dns/" + zone_type, "--_dn", dn]
            show_res = ctx.run(show_args, mutates=False)
            if show_res.rc != 0:
                fail("Failed to read existing zone: " + show_res.stderr)
            # Parse current key-value pairs from UDM output
            current = {}
            for line in show_res.stdout.splitlines():
                parts = line.strip().split(": ", 1)
                if len(parts) == 2:
                    key, val = parts[0].lower(), parts[1]
                    # UDM lists 'a' for IP interfaces, 'nameserver' etc.
                    current[key] = val

            # Compare only keys we care about (simple string/str-list equality)
            # Convert to comparable lists: UDM returns space-separated strings for lists
            def parse_list(val):
                return val.strip().split() if val.strip() else []

            # Build desired dict for comparison in UDM-style
            desired_cmp = {}
            for k, v in desired.items():
                if isinstance(v, list):
                    desired_cmp[k] = " ".join(v) if v else ""
                else:
                    desired_cmp[k] = str(v)

            # Compare each key
            needs_update = False
            for k in desired_cmp.keys():
                if k not in current:
                    needs_update = True
                    break
                cv = current.get(k, "")
                dv = desired_cmp.get(k, "")
                if k in ["nameserver", "a", "mx"]:
                    # List comparison (order-sensitive per Ansible list semantics)
                    if parse_list(cv) != parse_list(dv):
                        needs_update = True
                        break
                elif cv != dv:
                    needs_update = True
                    break

            if needs_update:
                changed = True
                if ctx.check_mode:
                    msg = "would update zone " + zone
                    return {"changed": True, "msg": msg}

                # Perform modify
                modify_args = ["udm", "dns/" + zone_type, "--dn", dn]
                for k, v in desired.items():
                    if isinstance(v, list):
                        for item in v:
                            modify_args.extend(["--set", k, item])
                    else:
                        modify_args.extend(["--set", k, str(v)])
                mod_res = ctx.run(modify_args, mutates=True)
                if mod_res.rc != 0:
                    fail("Failed to modify zone: " + mod_res.stderr)
                msg = "updated zone " + zone
            else:
                msg = "zone " + zone + " already correct"
        else:
            # Create new zone
            changed = True
            if ctx.check_mode:
                msg = "would create zone " + zone
                return {"changed": True, "msg": msg}

            create_args = ["udm", "dns/" + zone_type, "--set"]
            for k, v in desired.items():
                if isinstance(v, list):
                    for item in v:
                        create_args.extend(["--set", k, item])
                else:
                    create_args.extend(["--set", k, str(v)])
            create_res = ctx.run(create_args, mutates=True)
            if create_res.rc != 0:
                fail("Failed to create zone: " + create_res.stderr)
            msg = "created zone " + zone

    elif state == "absent":
        if exists:
            changed = True
            if ctx.check_mode:
                msg = "would delete zone " + zone
                return {"changed": True, "msg": msg}

            remove_args = ["udm", "dns/" + zone_type, "--dn", dn, "--remove"]
            rem_res = ctx.run(remove_args, mutates=True)
            if rem_res.rc != 0:
                fail("Failed to remove zone: " + rem_res.stderr)
            msg = "deleted zone " + zone
        else:
            msg = "zone " + zone + " does not exist"

    return {"changed": changed, "msg": msg, "data": {"zone": zone}}
