def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    blacklist_file = params.get("blacklist_file", "/etc/modprobe.d/blacklist-ansible.conf")

    # Probe current state
    file_exists = ctx.file_exists(blacklist_file)
    if file_exists:
        content = ctx.file_read(blacklist_file)
        lines = content.split("\n") if content else []
    else:
        lines = []

    # Check if module is currently blacklisted
    is_blacklisted = False
    prefix = "blacklist "
    for line in lines:
        stripped = line.strip()
        # Skip comments and empty lines
        if stripped == "" or stripped.startswith("#"):
            continue
        # Check if line starts with "blacklist " and matches name
        if stripped.startswith(prefix):
            module_part = stripped[len(prefix):]
            if module_part.strip() == name:
                is_blacklisted = True
                break

    # Handle desired state
    if state == "present":
        if is_blacklisted:
            return {"changed": False, "msg": name + " is already blacklisted"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would blacklist " + name}
        # Append blacklist entry
        new_lines = []
        for line in lines:
            new_lines.append(line)
        new_lines.append("blacklist " + name)
        ctx.file_write(blacklist_file, "\n".join(new_lines) + "\n", mode="0644")
        return {"changed": True, "msg": name + " blacklisted"}
    elif state == "absent":
        if not is_blacklisted:
            return {"changed": False, "msg": name + " is not blacklisted"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove blacklist for " + name}
        # Remove the blacklist entry
        filtered_lines = []
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("blacklist "):
                module_part = stripped[len("blacklist "):].strip()
                if module_part != name:
                    filtered_lines.append(line)
            else:
                filtered_lines.append(line)
        ctx.file_write(blacklist_file, "\n".join(filtered_lines) + "\n", mode="0644")
        return {"changed": True, "msg": "removed blacklist for " + name}
    else:
        fail("unsupported state: " + state)
