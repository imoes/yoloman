def main(ctx, params):
    revert = params.get("revert")
    
    # Determine flags based on revert option
    if revert == "all":
        run_flag = ["-R"]
        check_flag = ["-l"]
    elif revert == "one":
        run_flag = ["-r"]
        check_flag = ["-l"]
    else:
        run_flag = []
        check_flag = ["-c"]
    
    # Run check command to see if patches are pending
    cmd = ["syspatch"] + check_flag
    res = ctx.run(cmd)
    
    if res.rc != 0:
        fail("Command syspatch failed rc=%d, out=%s, err=%s" % (res.rc, res.stdout, res.stderr))
    
    change_pending = len(res.stdout) > 0
    
    if ctx.check_mode:
        return {
            "changed": change_pending,
            "reboot_needed": False,
            "rc": res.rc,
            "stderr": res.stderr,
            "stdout": res.stdout,
            "warnings": []
        }
    
    if change_pending:
        res = ctx.run(["syspatch"] + run_flag)
        
        stdout_lower = res.stdout.lower()
        stderr = res.stderr
        warnings = []
        
        # Handle syspatch ln bug workaround
        if res.rc != 0 and stderr != "ln: /usr/X11R6/bin/X: No such file or directory\n":
            fail("Command syspatch failed rc=%d, out=%s, err=%s" % (res.rc, res.stdout, res.stderr))
        elif stdout_lower.find("create unique kernel") >= 0:
            reboot_needed = True
        elif stdout_lower.find("syspatch updated itself") >= 0:
            warnings.append("Syspatch was updated. Please run syspatch again.")
        elif len(res.stdout) == 0:
            warnings.append("syspatch had suggested changes, but stdout was empty.")
        else:
            reboot_needed = False
        
        return {
            "changed": True,
            "reboot_needed": reboot_needed,
            "rc": res.rc,
            "stderr": stderr,
            "stdout": res.stdout,
            "warnings": warnings
        }
    
    return {
        "changed": False,
        "reboot_needed": False,
        "rc": res.rc,
        "stderr": res.stderr,
        "stdout": res.stdout,
        "warnings": []
    }
