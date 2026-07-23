def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {"levels": [20, 30]}, "metrics": ["logins"]}]}
        }

    # Check mode
    res = ctx.run(["cat", "/run/utmp"], mutates=False)
    # Since the agent outputs a single integer line, we read from /run/utmp
    # but actually checkmk's agent plugin reads /run/utmp and counts logins differently.
    # However, the source shows the agent output format is <<<logins>>> followed by a line with an integer.
    # Since we can't rely on a Checkmk agent, we need to find the actual data source.
    
    # Checkmk's logins check actually reads the number of users logged in (utmp entries).
    # The standard Linux way is to count non-empty lines in /run/utmp or use 'who' or 'w'.
    # The agent plugin actually uses utmp entries (count of users logged in).
    # On most systems, we can use 'who' or 'w' or 'users', but the agent plugin
    # actually reads /run/utmp directly and counts entries.
    
    # Alternative: use 'who' command to get logged-in users count
    # But the agent plugin actually outputs a single integer.
    # The agent plugin's output format is: <<<logins>>>\n<integer>\n
    # The actual source data for the number of logins is typically the count of active sessions.
    
    # Since we cannot use 'who' reliably (depends on format), and the Checkmk agent plugin
    # actually uses a Python utmp library, but in Starlark we don't have that.
    # The standard approach is to use 'w' or 'who' and count lines.
    
    # Actually, the Checkmk agent plugin for logins reads /run/utmp directly using Python's utmp module.
    # Since we can't do that in Starlark, and the agent output format is just a number,
    # we'll use 'w -h' or 'who' and count lines. 'w' is more reliable.
    
    res = ctx.run(["w", "-h"], mutates=False)
    # 'w -h' gives one line per logged-in user, without header
    
    lines = res.stdout.strip().split("\n")
    count = 0
    for line in lines:
        if line.strip():
            count += 1
    
    # Alternative: use 'who' command
    if count == 0:
        res = ctx.run(["who"], mutates=False)
        lines = res.stdout.strip().split("\n")
        count = 0
        for line in lines:
            if line.strip():
                count += 1
    
    # If still 0, try 'users'
    if count == 0:
        res = ctx.run(["users"], mutates=False)
        if res.stdout.strip():
            users = res.stdout.strip().split()
            count = len(users)
    
    warn = params.get("levels", [20, 30])[0]
    crit = params.get("levels", [20, 30])[1]
    
    state = "OK"
    msg = "On system"
    if count >= crit:
        state = "CRIT"
        msg = "%s: %d (warn/crit at 20/30)" % (msg, count)
    elif count >= warn:
        state = "WARN"
        msg = "%s: %d (warn/crit at 20/30)" % (msg, count)
    else:
        msg = "%s: %d" % (msg, count)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"logins": count},
            "details": ""
        }
    }