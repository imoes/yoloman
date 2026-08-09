def main(ctx, params):
    release = params.get("release")

    # Check for root privileges
    uid_res = ctx.run(["id", "-u"])
    if uid_res.rc != 0 or uid_res.stdout.strip() != "0":
        fail("Interacting with subscription-manager requires root permissions ('become: true')")

    # Validate release format if provided
    if release != None:
        valid = False
        # Check for digits-only: 1-2 digits
        if len(release) >= 1 and len(release) <= 2 and release.isdigit():
            valid = True
        # Check for X.Y format: up to 2 digits each part
        elif release.find(".") != -1:
            parts = release.split(".")
            if len(parts) == 2 and len(parts[0]) <= 2 and len(parts[1]) <= 2 and parts[0].isdigit() and parts[1].isdigit():
                valid = True
        # Check for Server/Client/Workstation suffix
        elif release.endswith("Server") or release.endswith("Client") or release.endswith("Workstation"):
            prefix = release[:-6] if release.endswith("Server") else release[:-6] if release.endswith("Client") else release[:-11]
            if prefix.isdigit() and len(prefix) <= 2 and int(prefix) <= 99:
                valid = True
        
        if not valid:
            fail("\"" + release + "\" does not appear to be a valid release.")

    # Get current release
    show_res = ctx.run(["subscription-manager", "release", "--show"])
    current_release = None
    if show_res.rc == 0:
        lines = show_res.stdout.split("\n")
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("Release:"):
                value = stripped.split(":", 1)[1].strip()
                # Extract version using simple pattern matching
                parts = value.split()
                if len(parts) > 0:
                    match_val = parts[0]
                    # Validate pattern matches expected format
                    valid_val = False
                    # Digits only
                    if len(match_val) <= 2 and match_val.isdigit():
                        valid_val = True
                    # X.Y format
                    elif match_val.find(".") != -1:
                        parts2 = match_val.split(".")
                        if len(parts2) == 2 and len(parts2[0]) <= 2 and len(parts2[1]) <= 2 and parts2[0].isdigit() and parts2[1].isdigit():
                            valid_val = True
                    # Server/Client/Workstation suffix
                    elif match_val.endswith("Server") or match_val.endswith("Client") or match_val.endswith("Workstation"):
                        suffix_len = 6 if match_val.endswith("Server") or match_val.endswith("Client") else 11
                        prefix = match_val[:-suffix_len]
                        if prefix.isdigit() and len(prefix) <= 2 and int(prefix) <= 99:
                            valid_val = True
                    
                    if valid_val:
                        current_release = match_val
                        break

    # Determine if change is needed
    changed = (release != current_release)

    # In check_mode, just report what would happen
    if ctx.check_mode and changed:
        return {"changed": True, "current_release": current_release}

    # Apply change if needed
    if changed and not ctx.check_mode:
        if release == None:
            unset_res = ctx.run(["subscription-manager", "release", "--unset"])
            if unset_res.rc != 0:
                fail("Failed to unset release: " + unset_res.stderr)
        else:
            set_res = ctx.run(["subscription-manager", "release", "--set", release])
            if set_res.rc != 0:
                fail("Failed to set release: " + set_res.stderr)
        current_release = release

    return {"changed": changed, "current_release": current_release}
