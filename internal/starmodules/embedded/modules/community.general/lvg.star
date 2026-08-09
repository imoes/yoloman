def main(ctx, params):
    vg = params["vg"]
    state = params.get("state", "present")
    force = params.get("force", False)
    pvresize = params.get("pvresize", False)
    pesize = params.get("pesize", "4")
    pv_options = params.get("pv_options", "")
    vg_options = params.get("vg_options", "")
    reset_vg_uuid = params.get("reset_vg_uuid", False)
    reset_pv_uuid = params.get("reset_pv_uuid", False)
    pvs_list = params.get("pvs")

    def run_cmd(argv, mutates=False, ok_codes=None):
        if ok_codes == None:
            ok_codes = [0]
        res = ctx.run(argv, mutates=mutates)
        if res.rc not in ok_codes:
            fail("Command failed: %s. rc=%s, stdout=%s, stderr=%s" % (argv, res.rc, res.stdout, res.stderr))
        return res

    def get_vg(name):
        # vgs exits 5 ("Volume group not found") when the VG does not exist yet — that is the normal
        # "absent" answer (a fresh restore always hits it), NOT a hard failure. Tolerate it and report
        # the VG as missing so the caller creates it.
        res = run_cmd(["vgs", "--noheadings", "-o", "vg_name,pv_count,lv_count", "--separator", ";", name],
                      ok_codes=[0, 5])
        if res.rc != 0:
            return None
        lines = res.stdout.strip().split("\n")
        for line in lines:
            parts = line.strip().split(";")
            if len(parts) >= 3 and parts[0].strip() == name:
                return {"name": parts[0].strip(), "pv_count": int(parts[1].strip()), "lv_count": int(parts[2].strip())}
        return None

    def get_pvs_for_vg(vgname):
        res = run_cmd(["pvs", "--noheadings", "-o", "pv_name,vg_name", "--separator", ";"])
        pvs = []
        for line in res.stdout.strip().split("\n"):
            parts = line.strip().split(";")
            if len(parts) >= 2:
                pv_name = parts[0].strip()
                vg_name = parts[1].strip() if parts[1].strip() else ""
                if vg_name == vgname:
                    pvs.append({"name": pv_name, "vg_name": vg_name})
        return pvs

    def is_autoactivation_supported():
        res = run_cmd(["vgchange", "--help"])
        return "--setautoactivation" in res.stdout

    def activate_vg(vgname, active=True):
        changed = False
        vgchange_cmd = ["vgchange"]
        vgs_fields = ["lv_attr"]

        autoactivation_supported = is_autoactivation_supported()
        if autoactivation_supported:
            vgs_fields.append("autoactivation")

        # Get LV states
        res = run_cmd(["vgs", "--noheadings", "-o", ",".join(vgs_fields), "--separator", ";", vgname])
        lv_active_count = 0
        lv_inactive_count = 0
        autoactivation_enabled = False
        for line in res.stdout.strip().split("\n"):
            parts = line.strip().split(";")
            if len(parts) >= 1:
                if parts[0][4] == 'a':
                    lv_active_count += 1
                else:
                    lv_inactive_count += 1
            if autoactivation_supported and len(parts) >= 2:
                autoactivation_enabled = autoactivation_enabled or parts[1].strip() == "enabled"

        activate_flag = None
        if active and lv_inactive_count > 0:
            activate_flag = 'y'
        elif not active and lv_active_count > 0:
            activate_flag = 'n'

        if autoactivation_supported:
            auto_opt = '--setautoactivation'
            if active and not autoactivation_enabled:
                if ctx.check_mode:
                    changed = True
                else:
                    run_cmd([vgchange_cmd[0], auto_opt, 'y', vgname])
                    changed = True
            elif not active and autoactivation_enabled:
                if ctx.check_mode:
                    changed = True
                else:
                    run_cmd([vgchange_cmd[0], auto_opt, 'n', vgname])
                    changed = True

        if activate_flag != None:
            if ctx.check_mode:
                changed = True
            else:
                run_cmd([vgchange_cmd[0], '--activate', activate_flag, vgname])
                changed = True

        return changed

    # --- Main logic ---

    this_vg = get_vg(vg)
    present_state = state in ["present", "active", "inactive"]

    if reset_pv_uuid and not pvs_list:
        fail("pvs is required when reset_pv_uuid is true")

    # Validate devices
    dev_list = []
    if pvs_list:
        # Handle comma-separated string or list
        if isinstance(pvs_list, str):
            dev_list = [d.strip() for d in pvs_list.split(",") if d.strip()]
        else:
            dev_list = [str(d).strip() for d in pvs_list if str(d).strip()]
    elif present_state and this_vg == None:
        fail("No physical volumes given.")

    # --- Create VG ---
    if this_vg == None:
        if present_state:
            # Prepare options
            vgopts = vg_options.split() if vg_options else []
            if state in ["active", "inactive"]:
                vgopts.extend(["--setautoactivation", "y" if state == "active" else "n"])
            pvopts = pv_options.split() if pv_options else []

            # Create PVs
            for dev in dev_list:
                if not ctx.file_exists(dev):
                    fail("Device %s not found." % dev)
                run_cmd(["pvcreate"] + pvopts + ["-f", dev], mutates=True)

            # Create VG
            run_cmd(["vgcreate"] + vgopts + ["-s", pesize, vg] + dev_list, mutates=True)
            return {"changed": True, "msg": "Created volume group %s" % vg}

    # --- Remove VG ---
    if state == "absent":
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove volume group %s" % vg}
        if this_vg["lv_count"] == 0 or force:
            run_cmd(["vgremove", "--force", vg], mutates=True)
            return {"changed": True, "msg": "Removed volume group %s" % vg}
        fail("Refuse to remove non-empty volume group %s without force=true" % vg)

    # --- Activate/Deactivate VG ---
    if state == "active":
        if ctx.check_mode:
            # Predict change: check if any LVs are inactive
            res = run_cmd(["vgs", "--noheadings", "-o", "lv_attr", "--separator", ";", vg])
            for line in res.stdout.strip().split("\n"):
                if line.strip() and line.strip()[4] == 'i':
                    return {"changed": True, "msg": "would activate volume group %s" % vg}
            return {"changed": False, "msg": "volume group %s already active" % vg}
        changed = activate_vg(vg, active=True)
        return {"changed": changed, "msg": "activated volume group %s" % vg if changed else "volume group %s already active" % vg}

    if state == "inactive":
        if ctx.check_mode:
            res = run_cmd(["vgs", "--noheadings", "-o", "lv_attr", "--separator", ";", vg])
            for line in res.stdout.strip().split("\n"):
                if line.strip() and line.strip()[4] == 'a':
                    return {"changed": True, "msg": "would deactivate volume group %s" % vg}
            return {"changed": False, "msg": "volume group %s already inactive" % vg}
        changed = activate_vg(vg, active=False)
        return {"changed": changed, "msg": "deactivated volume group %s" % vg if changed else "volume group %s already inactive" % vg}

    # --- Resize VG (add/remove PVs) ---
    if present_state and pvs_list:
        current_pvs = get_pvs_for_vg(vg)
        current_devs = [p["name"] for p in current_pvs]
        devs_to_add = [d for d in dev_list if d not in current_devs]
        devs_to_remove = [d for d in current_devs if d not in dev_list]

        # Handle reset_pv_uuid and pvresize on current PVs
        for dev in current_devs:
            if pvresize:
                # Get pv sizes
                res = run_cmd(["pvdisplay", "--units", "b", "--columns", "--noheadings", "--nosuffix", "--separator", ";", "-o", "dev_size,pv_size,pe_start,vg_extent_size", dev])
                values = res.stdout.strip().split(";")
                if len(values) >= 4:
                    dev_size = int(values[0])
                    pv_size = int(values[1])
                    pe_start = int(values[2])
                    vg_extent_size = int(values[3])
                    if (dev_size - (pe_start + pv_size)) > vg_extent_size:
                        if ctx.check_mode:
                            return {"changed": True, "msg": "would resize PV %s" % dev}
                        run_cmd(["pvresize", dev], mutates=True)
                        # Check if resized
                        res = run_cmd(["pvdisplay", "--units", "b", "--columns", "--noheadings", "--nosuffix", "--separator", ";", "-o", "pv_size", dev])
                        new_pv_size = int(res.stdout.strip().split(";")[0])
                        if new_pv_size == pv_size:
                            fail("Failed to resize PV %s" % dev)
                        else:
                            # Already changed in this loop, return
                            return {"changed": True, "msg": "Resized PV %s" % dev}

            if reset_pv_uuid:
                # Get current UUID
                res = run_cmd(["pvs", "--noheadings", "-o", "uuid", dev])
                orig_uuid = res.stdout.strip()
                if ctx.check_mode:
                    return {"changed": True, "msg": "would reset PV UUID for %s" % dev}
                run_cmd(["pvchange", "-u", dev], mutates=True)
                res = run_cmd(["pvs", "--noheadings", "-o", "uuid", dev])
                new_uuid = res.stdout.strip()
                if orig_uuid == new_uuid:
                    fail("Failed to reset UUID for PV %s" % dev)
                return {"changed": True, "msg": "Reset UUID for PV %s" % dev}

        # Handle adding PVs
        if devs_to_add:
            if ctx.check_mode:
                return {"changed": True, "msg": "would add PVs %s to VG %s" % (devs_to_add, vg)}
            for dev in devs_to_add:
                if not ctx.file_exists(dev):
                    fail("Device %s not found." % dev)
                run_cmd(["pvcreate"] + (pv_options.split() if pv_options else []) + ["-f", dev], mutates=True)
            run_cmd(["vgextend", vg] + devs_to_add, mutates=True)
            return {"changed": True, "msg": "Added PVs %s to VG %s" % (devs_to_add, vg)}

        # Handle removing PVs
        if devs_to_remove:
            if ctx.check_mode:
                return {"changed": True, "msg": "would remove PVs %s from VG %s" % (devs_to_remove, vg)}
            run_cmd(["vgreduce", "--force", vg] + devs_to_remove, mutates=True)
            return {"changed": True, "msg": "Removed PVs %s from VG %s" % (devs_to_remove, vg)}

    # --- Reset VG UUID ---
    if reset_vg_uuid:
        if ctx.check_mode:
            return {"changed": True, "msg": "would reset VG UUID for %s" % vg}
        run_cmd(["vgchange", "-u", vg], mutates=True)
        return {"changed": True, "msg": "Reset VG UUID for %s" % vg}

    return {"changed": False, "msg": "Volume group %s is already in desired state" % vg}
