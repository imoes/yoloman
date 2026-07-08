def main(ctx, params):
    # Required
    api_key = params["api_key"]
    name = params["name"]
    state = params.get("state", "present")

    # Optional with defaults
    displaygroup = params.get("displaygroup", "")
    payment_term = params.get("payment_term", 1)
    swap = params.get("swap", 512)
    wait = params.get("wait", True)
    wait_timeout = params.get("wait_timeout", 300)
    watchdog = 1 if params.get("watchdog", True) else 0

    # Optional parameters
    additional_disks = params.get("additional_disks")
    plan = params.get("plan")
    distribution = params.get("distribution")
    datacenter = params.get("datacenter")
    kernel_id = params.get("kernel_id")
    linode_id = params.get("linode_id")
    password = params.get("password")
    private_ip = params.get("private_ip", False)
    ssh_pub_key = params.get("ssh_pub_key")
    backupweeklyday = params.get("backupweeklyday")
    backupwindow = params.get("backupwindow")

    # Build alert/direct config kwargs
    kwargs = {}
    for k in [
        "alert_bwin_enabled", "alert_bwin_threshold",
        "alert_bwout_enabled", "alert_bwout_threshold",
        "alert_bwquota_enabled", "alert_bwquota_threshold",
        "alert_cpu_enabled", "alert_cpu_threshold",
        "alert_diskio_enabled", "alert_diskio_threshold",
        "backupweeklyday", "backupwindow"
    ]:
        v = params.get(k)
        if v != None:
            kwargs[k] = v

    # Helper: generate password (simple deterministic version for simulation)
    def randompass():
        chars = "abcdefghijABCDEFGHIJ0123456789!@#$%^&*"
        # Deterministic seed simulation using len(name) and datacenter
        seed = len(name) + (datacenter if datacenter else 0)
        idx = 0
        result = []
        for i in range(24):
            idx = (idx + seed * (i + 1)) % len(chars)
            result.append(chars[idx])
        return "".join(result)

    # Simulated server state detection (in real usage, this would call Linode API)
    # Here we assume linode_id provided => server exists; otherwise new.
    server_exists = linode_id != None

    # Validate required params for creation
    if state in ("active", "present", "started"):
        if not server_exists:
            if not plan or not distribution or not datacenter:
                fail("plan, distribution, and datacenter are required when creating a new Linode")
            if ctx.check_mode:
                return {
                    "changed": True,
                    "msg": "would create Linode %s (plan=%s, datacenter=%s, distribution=%s)" % (name, plan, datacenter, distribution)
                }
            # In real usage, this would POST to /linode/instances via HTTP
            return {
                "changed": True,
                "msg": "created Linode %s (simulation only; actual Linode API call requires HTTP)" % name
            }

    # Simulate state transitions
    if state in ("active", "present", "started"):
        if not server_exists:
            return {
                "changed": False,
                "msg": "server not found; creation requires plan, distribution, datacenter"
            }
        if ctx.check_mode:
            return {
                "changed": True,
                "msg": "would ensure Linode %s is running" % name
            }
        return {
            "changed": False,
            "msg": "Linode %s already running (simulation only)" % name
        }

    elif state == "stopped":
        if not server_exists:
            fail("Server with linode_id=%s not found" % linode_id)
        if ctx.check_mode:
            return {
                "changed": True,
                "msg": "would stop Linode %s" % name
            }
        return {
            "changed": True,
            "msg": "stopped Linode %s (simulation only)" % name
        }

    elif state == "restarted":
        if not server_exists:
            fail("Server with linode_id=%s not found" % linode_id)
        if ctx.check_mode:
            return {
                "changed": True,
                "msg": "would restart Linode %s" % name
            }
        return {
            "changed": True,
            "msg": "restarted Linode %s (simulation only)" % name
        }

    elif state in ("absent", "deleted"):
        if not server_exists:
            return {
                "changed": False,
                "msg": "Linode %s not found" % (name if name else "linode_id=%s" % linode_id)
            }
        if ctx.check_mode:
            return {
                "changed": True,
                "msg": "would delete Linode %s" % name
            }
        return {
            "changed": True,
            "msg": "deleted Linode %s (simulation only)" % name
        }

    fail("Unsupported state: %s" % state)
