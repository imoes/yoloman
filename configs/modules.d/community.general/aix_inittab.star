def main(ctx, params):
    name = params["name"]
    runlevel = params["runlevel"]
    action = params["action"]
    command = params["command"]
    insertafter = params.get("insertafter")
    state = params.get("state", "present")

    # Read current entry with lsitab
    lsitab = ctx.run(["lsitab", name], mutates=False)
    current_exists = lsitab.rc == 0
    current_entry = {}

    if current_exists:
        values = lsitab.stdout.strip().split(":")
        keys = ("name", "runlevel", "action", "command")
        # strip whitespace
        values = [v.strip() for v in values]
        current_entry = dict(zip(keys, values))
        current_entry["exist"] = True

    # Build expected new entry string
    new_entry = "%s:%s:%s:%s" % (name, runlevel, action, command)

    # Check mode: determine if change is needed
    needs_change = False
    if state == "present":
        if not current_exists:
            needs_change = True
        else:
            if (current_entry.get("runlevel") != runlevel or
                current_entry.get("action") != action or
                current_entry.get("command") != command):
                needs_change = True
    elif state == "absent":
        if current_exists:
            needs_change = True

    if ctx.check_mode:
        return {
            "changed": needs_change,
            "msg": ("would " + ("remove" if state == "absent" else "add/modify") +
                    " inittab entry " + name)
        }

    # Actual changes
    if state == "present":
        if not current_exists:
            if insertafter:
                res = ctx.run(["mkitab", "-i", insertafter, new_entry], mutates=True)
            else:
                res = ctx.run(["mkitab", new_entry], mutates=True)
            if res.rc != 0:
                fail("could not add inittab entry %s: %s" % (name, res.stderr))
            return {
                "changed": True,
                "msg": "add inittab entry " + name
            }
        else:
            res = ctx.run(["chitab", new_entry], mutates=True)
            if res.rc != 0:
                fail("could not change inittab entry %s: %s" % (name, res.stderr))
            return {
                "changed": True,
                "msg": "changed inittab entry " + name
            }
    elif state == "absent":
        res = ctx.run(["rmitab", name], mutates=True)
        if res.rc != 0:
            fail("could not remove inittab entry %s: %s" % (name, res.stderr))
        return {
            "changed": True,
            "msg": "removed inittab entry " + name
        }

    fail("unsupported state: " + state)
