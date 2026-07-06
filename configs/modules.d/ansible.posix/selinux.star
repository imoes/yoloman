def main(ctx, params):
    configfile = params.get("configfile", "/etc/selinux/config")
    policy = params.get("policy")
    state = params["state"]
    update_kernel_param = params.get("update_kernel_param", False)

    # Check for required policy when state is not disabled
    if state != "disabled" and policy == None:
        fail("Policy is required if state is not 'disabled'")

    # Validate config file exists
    if not ctx.file_exists(configfile):
        fail("Unable to find file " + configfile + ". Please install SELinux-policy package.")

    # Get current state and policy from config file
    def get_config_value(key):
        content = ctx.file_read(configfile)
        for line in content.splitlines():
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
        return None

    config_state = get_config_value("SELINUX")
    config_policy = get_config_value("SELINUXTYPE")

    # Get runtime state using sestatus if available
    res = ctx.run(["sestatus"], mutates=False, ok_codes=[0, 1])
    runtime_state = None
    runtime_policy = None
    if res.rc == 0:
        output = res.stdout
        for line in output.splitlines():
            if line.startswith("Current mode:"):
                val = line.split(":", 1)[1].strip().lower()
                if val == "enforcing":
                    runtime_state = "enforcing"
                elif val == "permissive":
                    runtime_state = "permissive"
                elif val == "disabled":
                    runtime_state = "disabled"
            if line.startswith("Loaded policy name:"):
                runtime_policy = line.split(":", 1)[1].strip()

    # If runtime state still unknown (sestatus failed), assume disabled
    if runtime_state == None:
        runtime_state = "disabled"
    if runtime_policy == None:
        runtime_policy = config_policy if config_policy else ""

    # Handle kernel param update when update_kernel_param is true
    kernel_enabled = None
    if update_kernel_param:
        # Check grubby availability
        res = ctx.run(["grubby", "--version"], mutates=False, ok_codes=[0, 1])
        if res.rc != 0:
            fail("'grubby' command not found on host. In order to update the kernel command line enabled/disabled setting, the grubby package needs to be present on the system.")

        # Get current kernel SELinux state
        res = ctx.run(["grubby", "--info=ALL"], mutates=False, ok_codes=[0, 1])
        if res.rc == 0:
            all_enabled = True
            all_disabled = True
            for line in res.stdout.splitlines():
                if line.startswith("args="):
                    args = line.split("=", 1)[1].strip('" ').split()
                    if "selinux=0" in args:
                        all_enabled = False
                    else:
                        all_disabled = False
            if all_enabled:
                kernel_enabled = True
            elif all_disabled:
                kernel_enabled = False
            else:
                kernel_enabled = None  # Inconsistent

    # Determine reboot_required and build messages
    reboot_required = False
    msgs = []
    changed = False

    # Policy check
    if policy != runtime_policy:
        if policy != config_policy:
            if not ctx.check_mode:
                # Update config file SELINUXTYPE
                content = ctx.file_read(configfile)
                lines = content.splitlines()
                found = False
                new_lines = []
                for line in lines:
                    if line.startswith("SELINUXTYPE="):
                        found = True
                        new_lines.append("SELINUXTYPE=" + policy)
                    else:
                        new_lines.append(line)
                if not found:
                    new_lines.append("SELINUXTYPE=" + policy)
                ctx.file_write(configfile, "\n".join(new_lines) + "\n")
            msgs.append("SELinux policy configuration in '" + configfile + "' changed from '" + (config_policy or "") + "' to '" + policy + "'")
            changed = True
        else:
            if ctx.check_mode:
                changed = True
            else:
                msgs.append("Running SELinux policy changed from '" + runtime_policy + "' to '" + policy + "'")
                changed = True

    # State check
    if state != runtime_state:
        if state == "disabled":
            if runtime_state != "disabled":
                if ctx.check_mode:
                    reboot_required = True
                    changed = True
                else:
                    # Runtime state change for disabled is handled by reboot
                    if runtime_state not in ["permissive", "disabled"]:
                        # Temporarily set to permissive before disabled
                        ctx.run(["setenforce", "0"], mutates=True, ok_codes=[0])
                    reboot_required = True
                    msgs.append("SELinux state will change to 'disabled' (requires reboot)")
                    changed = True
        else:
            # state is enforcing/permissive
            if ctx.check_mode:
                reboot_required = True
                changed = True
            else:
                if state == "enforcing":
                    res = ctx.run(["setenforce", "1"], mutates=True, ok_codes=[0])
                else:  # permissive
                    res = ctx.run(["setenforce", "0"], mutates=True, ok_codes=[0])
                if res.rc != 0:
                    fail("Failed to set SELinux state to " + state)
                msgs.append("SELinux state changed from '" + runtime_state + "' to '" + state + "'")
                changed = True

    # Config file state update
    if state != config_state:
        if not ctx.check_mode:
            content = ctx.file_read(configfile)
            lines = content.splitlines()
            found = False
            new_lines = []
            for line in lines:
                if line.startswith("SELINUX="):
                    found = True
                    new_lines.append("SELINUX=" + state)
                else:
                    new_lines.append(line)
            if not found:
                new_lines.append("SELINUX=" + state)
            ctx.file_write(configfile, "\n".join(new_lines) + "\n")
        msgs.append("Config SELinux state changed from '" + config_state + "' to '" + state + "'")
        changed = True

    # Kernel parameter update
    requested_kernel_enabled = state in ("enforcing", "permissive")
    if update_kernel_param and kernel_enabled != requested_kernel_enabled:
        if ctx.check_mode:
            changed = True
        else:
            # Update kernel param
            args = ["grubby", "--update-kernel=ALL"]
            if requested_kernel_enabled:
                args += ["--remove-args", "selinux=0"]
            else:
                args += ["--args", "selinux=0"]
            res = ctx.run(args, mutates=True, ok_codes=[0])
            if res.rc != 0:
                if requested_kernel_enabled:
                    fail("Unable to remove selinux=0 from kernel config")
                else:
                    fail("Unable to add selinux=0 to kernel config")

        if requested_kernel_enabled:
            states = ("disabled", "enabled")
        else:
            states = ("enabled", "disabled")
        if kernel_enabled == None:
            states = ("<inconsistent>", states[1])
        msgs.append("Kernel SELinux state changed from '" + states[0] + "' to '" + states[1] + "'")
        changed = True

    # If policy not provided and state is disabled, use config_policy
    if policy == None and state == "disabled":
        policy = config_policy or ""

    return {
        "changed": changed,
        "msg": ", ".join(msgs),
        "data": {
            "configfile": configfile,
            "policy": policy,
            "state": state,
            "reboot_required": reboot_required
        }
    }
