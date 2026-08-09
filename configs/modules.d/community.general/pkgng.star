def main(ctx, params):
    pkgs = params["name"]
    state = params.get("state", "present")
    cached = params.get("cached", False)
    ignore_osver = params.get("ignore_osver", False)
    annotation_list = params.get("annotation")
    pkgsite = params.get("pkgsite")
    rootdir = params.get("rootdir")
    chroot = params.get("chroot")
    jail = params.get("jail")
    autoremove = params.get("autoremove", False)

    # Validate mutually exclusive dir args
    dir_args = [rootdir, chroot, jail]
    if len([x for x in dir_args if x != None]) > 1:
        fail("options 'rootdir', 'chroot', and 'jail' are mutually exclusive")

    # Get pkg path and version
    res = ctx.run(["which", "pkg"], ok_codes=[0,1])
    if res.rc != 0:
        fail("pkg binary not found")
    pkg_path = res.stdout.strip()

    # Get pkg version as list of ints
    res = ctx.run([pkg_path, "-v"])
    version_str = res.stdout.strip()
    # Parse version: e.g. "1.17.3" -> [1,17,3]
    parts = version_str.split(".")
    version = []
    for p in parts:
        # Try parse as int; on failure use 0
        v = 0
        if p.isdigit():
            v = int(p)
        version.append(v)
    while len(version) < 3:
        version.append(0)

    def pkgng_older_than(compare_version):
        i = 0
        while i < min(len(compare_version), len(version)):
            if compare_version[i] != version[i]:
                return version[i] < compare_version[i]
            i += 1
        return False

    # Check rootdir support (1.5.0+)
    if rootdir != None:
        if pkgng_older_than([1,5,0]):
            fail("To use option 'rootdir' pkg version must be 1.5 or greater")

    # Check ignore_osver support (1.11.0+)
    if ignore_osver:
        if pkgng_older_than([1,11,0]):
            fail("To use option 'ignore_osver' pkg version must be 1.11 or greater")

    # Build dir argument
    dir_arg = None
    if rootdir != None:
        dir_arg = "--rootdir=%s" % rootdir
    elif chroot != None:
        dir_arg = "--chroot=%s" % chroot
    elif jail != None:
        dir_arg = "--jail=%s" % jail

    # Check if pkg is 1.1.4+ (PACKAGESITE deprecated)
    repo_flag_not_supported = pkgng_older_than([1,1,4])

    def run_pkgng(action, *args, **kwargs):
        cmd = [pkg_path]
        if dir_arg != None:
            cmd.append(dir_arg)
        cmd.append(action)

        env = {"BATCH": "yes"}
        if ignore_osver:
            env["IGNORE_OSVERSION"] = "yes"

        # pkgsite handling
        if pkgsite != None and action in ("update", "install", "upgrade"):
            if repo_flag_not_supported:
                env["PACKAGESITE"] = pkgsite
            else:
                cmd.append("--repository=%s" % pkgsite)

        # environ_update not supported in Starlark; ignore
        res = ctx.run(cmd + list(args))
        return res

    def query_package(name):
        res = run_pkgng("info", "-g", "-e", name)
        return res.rc == 0

    def query_update(name):
        res = run_pkgng("upgrade", "-g", "-n", name)
        return res.rc == 1

    def install_packages(packages, cached, state):
        action_queue = {"install": [], "upgrade": []}
        stdout = ""
        stderr = ""

        # Update repo if not cached
        if not cached:
            res = run_pkgng("update")
            stdout += res.stdout
            stderr += res.stderr
            if res.rc != 0:
                fail("Could not update catalogue [%d]: %s %s" % (res.rc, res.stdout, res.stderr))

        # Categorize packages
        for pkg in packages:
            installed = query_package(pkg)
            if state == "present" and installed:
                continue
            if state == "latest" and installed and not query_update(pkg):
                continue
            if installed:
                action_queue["upgrade"].append(pkg)
            else:
                action_queue["install"].append(pkg)

        # Execute actions
        changed = False
        msg_parts = []

        for action in ("install", "upgrade"):
            pkgs_to_act = action_queue[action]
            if len(pkgs_to_act) == 0:
                continue

            changed = True

            if ctx.check_mode:
                msg_parts.append("%s %d package%s" % (
                    action, len(pkgs_to_act), "s" if len(pkgs_to_act) != 1 else ""
                ))
                continue

            res = run_pkgng(action, "-g", "-U", "-y", *pkgs_to_act)
            stdout += res.stdout
            stderr += res.stderr

            if res.rc != 0:
                fail("failed to %s packages: %s" % (action, res.stderr))

            # Verify each package
            for pkg in pkgs_to_act:
                verified = False
                if action == "install":
                    verified = query_package(pkg)
                elif action == "upgrade":
                    verified = not query_update(pkg)

                if not verified:
                    fail("failed to %s %s" % (action, pkg))

            past_tense = {"install": "installed", "upgrade": "upgraded"}
            msg_parts.append("%s %d package%s" % (
                past_tense[action], len(pkgs_to_act), "s" if len(pkgs_to_act) != 1 else ""
            ))

        if changed:
            return True, "; ".join(msg_parts), stdout, stderr
        else:
            return False, "package(s) already %s" % state, stdout, stderr

    def remove_packages(packages):
        changed = False
        stdout = ""
        stderr = ""

        for pkg in packages:
            if not query_package(pkg):
                continue
            changed = True

            if ctx.check_mode:
                continue

            res = run_pkgng("delete", "-y", pkg)
            stdout += res.stdout
            stderr += res.stderr

            if res.rc != 0:
                fail("failed to remove %s: %s" % (pkg, res.stderr))

        if changed:
            return True, "removed %d package%s" % (
                len(packages), "s" if len(packages) != 1 else ""
            ), stdout, stderr
        else:
            return False, "package(s) already absent", stdout, stderr

    def upgrade_all():
        changed = False
        stdout = ""
        stderr = ""

        res = run_pkgng("upgrade", "-n" if ctx.check_mode else "-y")
        stdout += res.stdout
        stderr += res.stderr

        # Parse count from output
        count = 0
        lines = res.stdout.split("\n")
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("Number of packages to be"):
                # Look for number in line
                for part in stripped.split():
                    if part.isdigit():
                        count = count + int(part)
                        break

        if count > 0:
            changed = True
            msg = "updated %d package%s" % (count, "s" if count != 1 else "")
        else:
            msg = "no packages need upgrades"

        return changed, msg, stdout, stderr

    def annotation_query(package, tag):
        res = run_pkgng("info", "-g", "-A", package)
        output = res.stdout
        # Search for tag: value pattern
        lines = output.split("\n")
        for line in lines:
            stripped = line.strip()
            if stripped.startswith(tag + ":"):
                idx = stripped.find(":")
                if idx >= 0:
                    return stripped[idx+1:].strip()
        return None

    def annotation_add(package, tag, value):
        current = annotation_query(package, tag)
        if current == None:
            if ctx.check_mode:
                return True
            res = run_pkgng("annotate", "-y", "-A", package, tag)
            if res.rc != 0:
                fail("could not annotate %s: %s" % (package, res.stderr))
            return True
        elif current != value:
            fail("failed to annotate %s: %s is already set to %s, but should be %s" % (package, tag, current, value))
        return False

    def annotation_delete(package, tag):
        if annotation_query(package, tag) == None:
            return False
        if ctx.check_mode:
            return True
        res = run_pkgng("annotate", "-y", "-D", package, tag)
        if res.rc != 0:
            fail("could not delete annotation to %s: %s" % (package, res.stderr))
        return True

    def annotation_modify(package, tag, value):
        current = annotation_query(package, tag)
        if current == None:
            fail("could not change annotation to %s: tag %s does not exist" % (package, tag))
        elif current == value:
            return False
        # value differs
        if ctx.check_mode:
            return True
        res = run_pkgng("annotate", "-y", "-M", package, tag)
        if res.rc != 0:
            # Check if modification actually succeeded despite rc=1
            if ("Modified annotation tagged: %s" % tag) not in res.stdout:
                fail("failed to annotate %s, could not change annotation %s to %s: %s" % (package, tag, value, res.stderr))
        return True

    def annotate_packages(packages, annotations):
        changed = False
        stdout = ""
        stderr = ""

        # Normalize annotations list
        flat_annotations = []
        for a in annotations:
            # Split on commas if not a list
            flat_annotations.extend(a.split(","))

        operations = {"+": annotation_add, "-": annotation_delete, ":": annotation_modify}

        for pkg in packages:
            for annot in flat_annotations:
                annot = annot.strip()
                if annot == "":
                    continue
                # Parse annotation string: [+-:]tag[=value]
                operation_char = annot[0] if annot[0] in "+-:" else None
                if operation_char == None:
                    fail("invalid annotation string: %s" % annot)

                rest = annot[1:]
                if "=" in rest:
                    tag, value = rest.split("=", 1)
                else:
                    tag = rest
                    value = None

                if operations[operation_char](pkg, tag, value):
                    changed = True

        if changed:
            return True, "added/modified/removed annotations"
        else:
            return False, "no annotations changed"

    def autoremove_packages():
        changed = False
        stdout = ""
        stderr = ""

        res = run_pkgng("autoremove", "-n")
        stdout += res.stdout
        stderr += res.stderr

        # Count packages to be removed
        count = 0
        lines = res.stdout.split("\n")
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("Deinstallation has been requested for the following"):
                for part in stripped.split():
                    if part.isdigit():
                        count = int(part)
                        break

        if count == 0:
            return False, "no package(s) to autoremove", stdout, stderr

        changed = True
        if ctx.check_mode:
            return changed, "would autoremove %d package%s" % (count, "s" if count != 1 else ""), stdout, stderr

        res = run_pkgng("autoremove", "-y")
        stdout += res.stdout
        stderr += res.stderr

        return changed, "autoremoved %d package%s" % (count, "s" if count != 1 else ""), stdout, stderr

    # Main logic

    changed = False
    msgs = []
    stdout_all = ""
    stderr_all = ""

    # Handle name=*
    star_packages = [p for p in pkgs if p == "*"]
    named_packages = [p for p in pkgs if p != "*"]

    # If * present with state=latest
    if len(star_packages) > 0 and state == "latest":
        _changed, _msg, _stdout, _stderr = upgrade_all()
        changed = changed or _changed
        stdout_all += _stdout
        stderr_all += _stderr
        msgs.append(_msg)
        # state=present/absent with * are noops per docs
        if state in ("present", "absent"):
            msgs.append("package(s) already %s" % state)
            return {"changed": changed, "msg": ", ".join(msgs), "stdout": stdout_all, "stderr": stderr_all}

    # Named package operations
    if len(named_packages) > 0:
        if state in ("present", "latest"):
            _changed, _msg, _stdout, _stderr = install_packages(named_packages, cached, state)
        elif state == "absent":
            _changed, _msg, _stdout, _stderr = remove_packages(named_packages)
        else:
            fail("unsupported state: " + state)

        changed = changed or _changed
        stdout_all += _stdout
        stderr_all += _stderr
        msgs.append(_msg)

    # Autoremove
    if autoremove:
        _changed, _msg, _stdout, _stderr = autoremove_packages()
        changed = changed or _changed
        stdout_all += _stdout
        stderr_all += _stderr
        msgs.append(_msg)

    # Annotations
    if annotation_list != None:
        # Note: original module applies annotations to ALL packages in pkgs list (including '*')
        _changed, _msg = annotate_packages(pkgs, annotation_list)
        changed = changed or _changed
        msgs.append(_msg)

    return {"changed": changed, "msg": ", ".join(msgs), "stdout": stdout_all, "stderr": stderr_all}
