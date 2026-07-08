def main(ctx, params):
    names = params["name"]
    state = params.get("state", "present")

    if type(names) != "list":
        fail("name must be a list of package names")

    yum_bin = ctx.run(["which", "yum"], mutates=False)
    if yum_bin.rc != 0:
        fail("yum command not found. Please install yum.")
    yum_bin_path = yum_bin.stdout.strip()

    # Get current versionlock list
    res = ctx.run([yum_bin_path, "versionlock", "list"], mutates=False)
    if res.rc == 1 and "such command:" in res.stderr:
        fail("Error: Please install rpm package yum-plugin-versionlock.")
    if res.rc != 0:
        fail("Error reading versionlock list: " + res.stderr)

    current_locks = res.stdout.splitlines()

    # Determine packages to add or remove
    to_modify = []

    def normalize_nevra(line):
        # Parse both YUM and DNF style versionlock entries
        # YUM style: !epoch:name-version-release.arch
        # DNF style: !name-epoch:version-release.arch
        # Return normalized (name, epoch, version, release, arch) or None if unparseable
        parts = line.split()
        if not parts:
            return None
        entry = parts[0].strip()
        exclude = entry.startswith("!")
        if exclude:
            entry = entry[1:]
        # Try DNF format first: name-epoch:version-release.arch
        # DNF: name-epoch:version-release.arch
        dnf_parts = entry.rsplit(".", 1)
        if len(dnf_parts) != 2:
            return None
        arch = dnf_parts[1]
        base = dnf_parts[0]
        dash_idx = base.find("-")
        if dash_idx == -1:
            return None
        name_part = base[:dash_idx]
        rest = base[dash_idx+1:]
        colon_idx = rest.find(":")
        if colon_idx == -1:
            return None
        epoch = rest[:colon_idx]
        rest = rest[colon_idx+1:]
        dash_idx2 = rest.find("-")
        if dash_idx2 == -1:
            return None
        version = rest[:dash_idx2]
        release = rest[dash_idx2+1:]
        return {"name": name_part, "epoch": epoch, "version": version, "release": release, "arch": arch, "exclude": exclude}

    def match_entry(entry_line, pkg_name):
        # entry_line is a single versionlock line (e.g., "!2:httpd-2.4.57-2.el9.x86_64" or similar)
        normalized = normalize_nevra(entry_line)
        if normalized == None:
            # Fallback: simple string match
            return pkg_name in entry_line
        # Match against name only (wildcards supported via string methods)
        name = normalized["name"]
        # Use fnmatch-like behavior with simple checks
        if name == pkg_name:
            return True
        if pkg_name.endswith(".*"):
            prefix = pkg_name[:-2]
            if name.startswith(prefix):
                return True
        if pkg_name.find("*") != -1:
            # Very basic wildcard support: replace * with .*
            # Since Starlark has no regex, we do simple prefix/suffix matching
            parts = pkg_name.split("*", 1)
            if len(parts) == 2 and name.startswith(parts[0]) and name.endswith(parts[1]):
                return True
        return False

    if state == "present":
        for pkg in names:
            found = False
            for lock_line in current_locks:
                if match_entry(lock_line, pkg):
                    found = True
                    break
            if not found:
                to_modify.append(pkg)
    elif state == "absent":
        for pkg in names:
            found = False
            for lock_line in current_locks:
                if match_entry(lock_line, pkg):
                    found = True
                    break
            if found:
                to_modify.append(pkg)
    else:
        fail("Unsupported state: " + state)

    if len(to_modify) == 0:
        return {"changed": False, "msg": "All specified packages are already in desired state", "packages": names, "state": state}

    # In check_mode, do not execute
    if ctx.check_mode:
        return {"changed": True, "msg": "would " + ("add" if state == "present" else "remove") + " " + str(len(to_modify)) + " package(s) to/from versionlock", "packages": names, "state": state}

    # Execute command
    command = "add" if state == "present" else "delete"
    res = ctx.run([yum_bin_path, "-q", "versionlock", command] + to_modify, mutates=True)
    if "No package found for" in res.stdout:
        fail(res.stdout)
    if res.rc != 0:
        fail("Error modifying versionlock: " + res.stderr)

    return {"changed": True, "msg": "Successfully " + ("added" if state == "present" else "removed") + " " + str(len(to_modify)) + " package(s) to/from versionlock", "packages": names, "state": state}
