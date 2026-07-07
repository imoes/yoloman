def _get_ctl_binary(ctx):
    for cmd in ["apache2ctl", "apachectl"]:
        res = ctx.run([cmd, "-V"], mutates=False)
        if res.rc == 0:
            return cmd
    fail("Neither of apache2ctl nor apachectl found. At least one apache control binary is necessary.")


def _run_threaded(ctx):
    ctl = _get_ctl_binary(ctx)
    res = ctx.run([ctl, "-V"], mutates=False)
    stdout = res.stdout.lower()
    return "threaded: *yes" in stdout or "threaded: yes" in stdout


def _module_is_enabled(ctx, identifier):
    ctl = _get_ctl_binary(ctx)
    res = ctx.run([ctl, "-M"], mutates=False)
    if res.rc != 0:
        return False
    searchstring = " " + identifier
    return searchstring in res.stdout


def create_apache_identifier(name):
    text_workarounds = [
        ("shib", "mod_shib"),
        ("shib2", "mod_shib"),
        ("evasive", "evasive20_module"),
    ]
    re_workarounds = [
        ("php", "^(php\\d)\\."),
    ]

    for a2enmod_spelling, module_name in text_workarounds:
        if a2enmod_spelling in name:
            return module_name

    for search, re_pattern in re_workarounds:
        if search in name:
            # emulate regex match
            if name.startswith(search):
                # simple heuristic for phpX. -> phpX_module
                for i in range(1, len(name)):
                    if not name[i].isdigit():
                        if i > 1 and name[i] == '.':
                            return name[:i] + "_module"
                # fallback: just append _module if no match
                pass

    return name + "_module"


def main(ctx, params):
    name = params["name"]
    force = params.get("force", False)
    state = params.get("state", "present")
    identifier = params.get("identifier")
    ignore_configcheck = params.get("ignore_configcheck", False)
    warn_mpm_absent = params.get("warn_mpm_absent", True)

    # check cgi + threaded MPM
    if name == "cgi" and _run_threaded(ctx):
        fail("Your MPM seems to be threaded. No automatic actions on module cgi possible.")

    if identifier == None:
        identifier = create_apache_identifier(name)

    want_enabled = state == "present"
    state_str = "enabled" if want_enabled else "disabled"
    a2mod_cmd = ["a2enmod"] if want_enabled else ["a2dismod"]

    # check current state
    current_enabled = _module_is_enabled(ctx, identifier)

    if current_enabled == want_enabled:
        return {
            "changed": False,
            "msg": "Module " + name + " already " + state_str
        }

    if ctx.check_mode:
        return {
            "changed": True,
            "msg": "would " + ("enable" if want_enabled else "disable") + " module " + name
        }

    # run a2enmod/a2dismod
    a2mod_path = None
    for bin_cmd in a2mod_cmd:
        res = ctx.run([bin_cmd, "--version"], mutates=False)
        if res.rc == 0:
            a2mod_path = bin_cmd
            break

    if a2mod_path == None:
        fail(a2mod_cmd[0] + " not found. Perhaps this system does not use " + a2mod_cmd[0] + " to manage apache")

    a2mod_argv = [a2mod_path, name]

    if not want_enabled and force:
        a2mod_argv.append("-f")

    res = ctx.run(a2mod_argv, mutates=True)

    if res.skipped:
        return {
            "changed": True,
            "msg": "would " + ("enable" if want_enabled else "disable") + " module " + name
        }

    if res.rc != 0:
        fail_msg = "Failed to " + ("enable" if want_enabled else "disable") + " module " + name
        if res.stderr:
            fail_msg += ": " + res.stderr
        fail(fail_msg)

    # verify new state
    new_enabled = _module_is_enabled(ctx, identifier)
    if new_enabled == want_enabled:
        return {
            "changed": True,
            "msg": "Module " + name + " " + state_str
        }
    else:
        fail(
            "Failed to set module " + name + " to " + state_str +
            ". Maybe the module identifier (" + identifier + ") was guessed incorrectly. Consider setting the \"identifier\" option."
        )
