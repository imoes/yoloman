def main(ctx, params):
    repo = params.get("repo")
    alias = params.get("name")
    state = params.get("state", "present")
    overwrite_multiple = params.get("overwrite_multiple", False)
    auto_import_keys = params.get("auto_import_keys", False)
    runrefresh = params.get("runrefresh", False)
    autorefresh = params.get("autorefresh", True)
    enabled = params.get("enabled", True)
    disable_gpg_check = params.get("disable_gpg_check", False)
    priority = params.get("priority")
    description = params.get("description")

    # Basic validation
    if repo == "*" or alias == "*":
        if runrefresh:
            res = ctx.run([_zypper_bin(ctx), '--gpg-auto-import-keys', 'refresh', '--force'] if auto_import_keys else [_zypper_bin(ctx), 'refresh', '--force'], mutates=False)
            if res.rc != 0:
                fail("Failed to refresh repositories: " + res.stderr)
            return {"changed": True, "msg": "repositories refreshed"}
        fail("repo=* can only be used with the runrefresh option.")

    if state == "present" and repo == None:
        fail("Module option state=present requires repo")
    if state == "absent" and repo == None and alias == None:
        fail("Alias or repo parameter required when state=absent")

    if repo != None and repo.endswith(".repo"):
        if alias != None:
            fail("Incompatible option: 'name'. Do not use name when adding .repo files")
    else:
        if alias == None and state == "present":
            fail("Name required when adding non-repo files.")

    # Parse .repo file if needed
    if repo != None and repo.endswith(".repo"):
        repofile_text = _fetch_repo_file(ctx, repo)
        repodata = _parse_repo_file(repofile_text)
        if repodata == None:
            fail("Invalid format, .repo file could not be parsed or contains no repositories")
        alias = repodata.get("alias")
        repo = repodata.get("url")
        if repodata.get("gpgkey") != None:
            auto_import_keys = True
        if repodata.get("name") != None:
            description = repodata.get("name")
        if repodata.get("enabled") != None:
            enabled = repodata.get("enabled") == "1"
        if repodata.get("autorefresh") != None:
            autorefresh = repodata.get("autorefresh") == "1"
        if repodata.get("gpgcheck") != None:
            disable_gpg_check = repodata.get("gpgcheck") == "0"

    # Build repodata dict for comparison
    repodata = {
        "url": repo,
        "alias": alias,
        "name": description,
        "priority": priority,
        "enabled": "1" if enabled else "0",
        "gpgcheck": "0" if disable_gpg_check else "1",
        "autorefresh": "1" if autorefresh else "0",
    }

    # Get existing repos
    existing = _parse_repos(ctx)

    # Find matching repos
    matched = []
    for oldr in existing:
        if (repo != None and oldr.get("url") == repo) or (alias != None and oldr.get("alias") == alias):
            if oldr not in matched:
                matched.append(oldr)

    exists = len(matched) > 0
    mod = False
    old_repos = None

    if exists:
        if len(matched) == 1:
            old_repos = matched
            mod = _repo_changes(ctx, matched[0], repodata)
        else:
            if overwrite_multiple:
                mod = True
                old_repos = matched
            else:
                fail('More than one repo matched "%s". Use overwrite_multiple to allow more than one repo to be overwritten' % (alias if alias else repo))

    # Action
    shortname = alias if alias else repo

    if state == "present":
        if exists and not mod:
            if runrefresh:
                _runrefresh(ctx, auto_import_keys, shortname)
            return {"changed": False, "msg": "repository already present", "repodata": repodata}
        
        res = _addmodify_repo(ctx, repodata, old_repos)
        if res.rc != 0:
            fail("Failed to add/modify repository: " + res.stderr)
        
        if runrefresh or auto_import_keys:
            _runrefresh(ctx, auto_import_keys, shortname)
        return {"changed": True, "msg": "repository added/modified", "repodata": repodata}

    elif state == "absent":
        if not exists:
            return {"changed": False, "msg": "repository already absent", "repodata": repodata}
        res = _remove_repo(ctx, shortname)
        if res.rc != 0:
            fail("Failed to remove repository: " + res.stderr)
        return {"changed": True, "msg": "repository removed", "repodata": repodata}


def _zypper_bin(ctx):
    # Try to find zypper
    res = ctx.run(["which", "zypper"], mutates=False)
    if res.rc == 0:
        return res.stdout.strip()
    # Fallback: assume standard path
    return "/usr/bin/zypper"


def _parse_repos(ctx):
    cmd = [_zypper_bin(ctx), '--quiet', '--non-interactive', '--xmlout', 'repos']
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0 and res.rc != 6:
        # rc 6 is "no repos" — treat as empty list
        fail("Failed to list repositories: " + res.stderr)
    
    if res.rc == 6:
        return []
    
    xml = res.stdout
    repos = []
    lines = xml.split("\n")
    in_repo = False
    repo = {}
    url = ""
    for line in lines:
        line = line.strip()
        if line.startswith("<repo"):
            in_repo = True
            repo = {}
            # Extract attributes
            for attr in ["alias", "name", "priority", "enabled", "autorefresh", "gpgcheck"]:
                idx = line.find(attr + '="')
                if idx != -1:
                    start = line.find('"', idx + len(attr) + 1) + 1
                    end = line.find('"', start)
                    if end != -1:
                        repo[attr] = line[start:end]
        elif in_repo and line.startswith("<url>"):
            start = line.find(">") + 1
            end = line.find("<", start)
            if end != -1:
                url = line[start:end]
        elif in_repo and line == "</repo>":
            repo["url"] = url
            repos.append(repo)
            in_repo = False
            url = ""
    return repos


def _repo_changes(ctx, realrepo, repodata):
    for k in repodata:
        if repodata[k] != None and k not in realrepo:
            return True
    
    for k, v in repodata.items():
        if v != None and k in realrepo:
            valold = str(repodata[k] or "")
            valnew = str(realrepo[k] or "")
            if k == "url":
                # Handle $releasever and $basearch
                if "$releasever" in valold or "$releasever" in valnew:
                    cmd = ["rpm", "-q", "--qf", "%{version}", "-f", "/etc/os-release"]
                    res = ctx.run(cmd, mutates=False)
                    if res.rc == 0 and res.stdout:
                        releasever = res.stdout.strip()
                        valold = valold.replace("$releasever", releasever)
                        valnew = valnew.replace("$releasever", releasever)
                if "$basearch" in valold or "$basearch" in valnew:
                    cmd = ["rpm", "-q", "--qf", "%{arch}", "-f", "/etc/os-release"]
                    res = ctx.run(cmd, mutates=False)
                    if res.rc == 0 and res.stdout:
                        basearch = res.stdout.strip()
                        valold = valold.replace("$basearch", basearch)
                        valnew = valnew.replace("$basearch", basearch)
                # Strip trailing slashes
                valold = valold.rstrip("/")
                valnew = valnew.rstrip("/")
            if valold != valnew:
                return True
    return False


def _fetch_repo_file(ctx, repo):
    if repo.startswith("http://") or repo.startswith("https://"):
        # Use curl to fetch the file
        res = ctx.run(["curl", "-fsSL", repo], mutates=False)
        if res.rc != 0:
            fail("Error downloading .repo file: " + res.stderr)
        return res.stdout
    else:
        # Local file
        if not ctx.file_exists(repo):
            fail("Cannot open .repo file: " + repo)
        return ctx.file_read(repo)


def _parse_repo_file(content):
    # Simple .repo parser (not full configparser equivalent, but sufficient for basic cases)
    sections = content.split("[")
    if len(sections) < 2:
        return None
    repo = {}
    for sec in sections[1:]:
        name_end = sec.find("]")
        if name_end == -1:
            continue
        name = sec[:name_end].strip()
        repo["alias"] = name
        body = sec[name_end + 1:]
        for line in body.split("\n"):
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            idx = line.find("=")
            key = line[:idx].strip()
            val = line[idx + 1:].strip()
            if key == "baseurl":
                repo["url"] = val
            elif key == "name":
                repo["name"] = val
            elif key == "enabled":
                repo["enabled"] = val
            elif key == "autorefresh":
                repo["autorefresh"] = val
            elif key == "gpgcheck":
                repo["gpgcheck"] = val
            elif key == "gpgkey":
                repo["gpgkey"] = val
    # Validate
    if "url" not in repo or "alias" not in repo:
        return None
    return repo


def _addmodify_repo(ctx, repodata, old_repos):
    cmd = [_zypper_bin(ctx), '--quiet', '--non-interactive', 'addrepo', '--check']
    if repodata.get("name"):
        cmd.extend(['--name', repodata["name"]])
    
    # Priority support (zypper >= 1.12.25)
    if repodata.get("priority") != None:
        # Check version
        res = ctx.run([_zypper_bin(ctx), '--version'], mutates=False)
        version = "1.0"
        if res.rc == 0 and res.stdout:
            out = res.stdout.strip()
            if out.startswith("zypper "):
                version = out.split(" ", 1)[1]
        # Simple version comparison
        if _version_ge(version, "1.12.25"):
            cmd.extend(['--priority', str(repodata["priority"])])
    
    if repodata.get("enabled") == "0":
        cmd.append('--disable')
    
    # GPG check (zypper >= 1.6.2)
    res = ctx.run([_zypper_bin(ctx), '--version'], mutates=False)
    version = "1.0"
    if res.rc == 0 and res.stdout:
        out = res.stdout.strip()
        if out.startswith("zypper "):
            version = out.split(" ", 1)[1]
    if _version_ge(version, "1.6.2"):
        if repodata.get("gpgcheck") == "1":
            cmd.append('--gpgcheck')
        else:
            cmd.append('--no-gpgcheck')
    
    if repodata.get("autorefresh") == "1":
        cmd.append('--refresh')
    
    cmd.append(repodata["url"])
    if not repodata["url"].endswith(".repo"):
        cmd.append(repodata["alias"])
    
    # Remove conflicting repos first
    if old_repos != None:
        for oldrepo in old_repos:
            _remove_repo(ctx, oldrepo["url"])
    
    return ctx.run(cmd, mutates=True)


def _remove_repo(ctx, repo):
    cmd = [_zypper_bin(ctx), '--quiet', '--non-interactive', 'removerepo', repo]
    return ctx.run(cmd, mutates=True)


def _runrefresh(ctx, auto_import_keys, shortname):
    if auto_import_keys:
        cmd = [_zypper_bin(ctx), '--gpg-auto-import-keys', 'refresh', '--force']
    else:
        cmd = [_zypper_bin(ctx), 'refresh', '--force']
    if shortname != None:
        cmd.extend(['-r', shortname])
    res = ctx.run(cmd, mutates=True)
    if res.rc != 0:
        fail("Failed to refresh repository: " + res.stderr)


def _version_ge(v1, v2):
    # Simple version comparison: split by dots and compare ints
    parts1 = v1.split(".")
    parts2 = v2.split(".")
    for i in range(max(len(parts1), len(parts2))):
        n1 = int(parts1[i]) if i < len(parts1) else 0
        n2 = int(parts2[i]) if i < len(parts2) else 0
        if n1 < n2:
            return False
        if n1 > n2:
            return True
    return True
