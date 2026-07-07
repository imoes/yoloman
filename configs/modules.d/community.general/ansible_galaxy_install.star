def main(ctx, params):
    gal_type = params["type"]
    name = params.get("name")
    req_file = params.get("requirements_file")
    dest = params.get("dest")
    force = params.get("force", False)
    no_deps = params.get("no_deps", False)

    # Validation: mutually exclusive name and requirements_file
    if name != None and req_file != None:
        fail("name and requirements_file are mutually exclusive")
    if gal_type == "both" and req_file == None:
        fail("requirements_file is required when type is both")

    # Determine locale; try C.UTF-8 then en_US.UTF-8
    envs = ["C.UTF-8", "en_US.UTF-8"]
    locale_ok = False
    for loc in envs:
        locale_res = ctx.run(["locale", "-a"], mutates=False, ok_codes=[0])
        lines = locale_res.stdout.splitlines()
        found = False
        for line in lines:
            lower_line = line.lower()
            if lower_line.find(loc.lower()) != -1:
                found = True
                break
        if found:
            locale_ok = True
            break
    if not locale_ok:
        fail("Neither C.UTF-8 nor en_US.UTF-8 locale is available")

    # Get ansible-galaxy version
    res = ctx.run(["ansible-galaxy", "version"], mutates=False, ok_codes=[0])
    if res.rc != 0:
        fail("Failed to get ansible-galaxy version: " + res.stderr)
    ver_line = res.stdout.splitlines()[0] if res.stdout.strip() != "" else ""
    # Parse version like "ansible-galaxy 2.14.5"
    ver_part = ""
    for chunk in ver_line.split():
        if chunk.replace(".", "").isdigit() and chunk.count(".") == 2:
            ver_part = chunk
            break
    if ver_part == "":
        fail("Unable to parse ansible-galaxy version from output: " + ver_line)
    parts = ver_part.split(".")
    if len(parts) < 3:
        fail("Version has fewer than 3 components: " + ver_part)
    ver = [int(parts[0]), int(parts[1]), int(parts[2])]
    if ver < [2, 11]:
        fail("Support for Ansible 2.9 and ansible-base 2.10 has been removed")

    # Prepare base command
    cmd = ["ansible-galaxy", "install"]

    # Add type-specific subcommand (skip for 'both')
    if gal_type != "both":
        cmd.append(gal_type)

    # --force
    if force:
        cmd.append("--force")

    # --no-deps
    if no_deps:
        cmd.append("--no-deps")

    # -p dest
    if dest != None:
        cmd.extend(["-p", dest])

    # -r requirements_file
    if req_file != None:
        cmd.extend(["-r", req_file])

    # Add name if present
    if name != None:
        cmd.append(name)

    # Check mode: simulate without running; return changed=True if install would run
    if ctx.check_mode:
        # In check_mode, we assume install would be needed unless we detect it's already installed
        # For simplicity, always return changed=True in check_mode since we cannot run galaxy install
        # However, if the exact same version is installed, we should report changed=False.
        # To do this, we list existing roles/collections.
        installed = []
        if gal_type != "both":
            list_cmd = ["ansible-galaxy", gal_type, "list"]
            if dest != None:
                list_cmd.extend(["-p", dest])
            res = ctx.run(list_cmd, mutates=False, ok_codes=[0])
            if res.rc == 0:
                lines = res.stdout.splitlines()
                target = name if gal_type == "collection" else name
                for line in lines:
                    # Skip comments
                    if line.startswith("#"):
                        continue
                    # Example: "- role_name, version"
                    if gal_type == "role" and line.startswith("- ") and "," in line:
                        split_parts = line[2:].split(",", 1)
                        if len(split_parts) == 2 and split_parts[0].strip() == target:
                            installed.append(split_parts[0].strip() + "," + split_parts[1].strip())
                    # Example for collection: "collection_name version"
                    if gal_type == "collection" and not line.startswith("-"):
                        split_parts = line.split()
                        if len(split_parts) >= 2 and split_parts[0] == target:
                            installed.append(split_parts[0] + "," + split_parts[1])
        if len(installed) > 0:
            return {"changed": False, "msg": "already installed", "data": {}}
        return {"changed": True, "msg": "would install " + (name if name else req_file), "data": {}}

    # Run actual install
    res = ctx.run(cmd, mutates=True, ok_codes=[0])
    if res.rc != 0:
        fail("ansible-galaxy install failed: " + res.stderr if res.stderr.strip() != "" else res.stdout)

    # Parse output to extract installed items
    new_roles = {}
    new_collections = {}

    for line in res.stdout.splitlines():
        # Role: "- ansistrano.deploy, version"
        if line.startswith("- ") and "," in line:
            split_parts = line[2:].split(",", 1)
            if len(split_parts) == 2:
                name_role = split_parts[0].strip()
                ver_role = split_parts[1].strip()
                new_roles[name_role] = ver_role
        # Collection: "community.general 3.1.0" or "community.general:3.1.0" or "community.general (3.1.0)"
        else:
            parts = line.split()
            if len(parts) >= 2:
                candidate = parts[0]
                # Skip if looks like a path or other noise
                if "." in candidate and candidate.replace(".", "").isalnum():
                    ver_str = ""
                    if ":" in parts[1]:
                        ver_str = parts[1].split(":")[1]
                    elif parts[1].startswith("(") and parts[1].endswith(")"):
                        ver_str = parts[1][1:-1]
                    elif parts[1][0].isdigit():
                        ver_str = parts[1]
                    if ver_str != "":
                        new_collections[candidate] = ver_str

    # Construct return data
    data = {}
    if gal_type in ["role", "both"]:
        data["new_roles"] = new_roles
    if gal_type in ["collection", "both"]:
        data["new_collections"] = new_collections

    return {
        "changed": True,
        "msg": "installed " + (name if name else req_file),
        "data": data
    }
