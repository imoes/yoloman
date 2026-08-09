def main(ctx, params):
    vg = params["vg"]
    state = params.get("state", "present")
    pvs = params.get("pvs")
    pp_size = params.get("pp_size")
    vg_type = params.get("vg_type", "normal")
    force = params.get("force", False)

    # Helper: validate physical volume
    def _validate_pv(pvs_list):
        lspv_res = ctx.run(["lspv"], mutates=False)
        if lspv_res.rc != 0:
            fail("Failed executing 'lspv' command: " + lspv_res.stderr)

        lspv_dict = {}
        for line in lspv_res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 3:
                lspv_dict[parts[0]] = parts[2]

        for pv in pvs_list:
            if pv not in lspv_dict:
                fail("Physical volume '%s' doesn't exist." % pv)
            if lspv_dict[pv] == 'None':
                # Check for Oracle ASM
                lquerypv_res = ctx.run(["lquerypv", "-h", "/dev/" + pv, "20", "10"], mutates=False)
                if lquerypv_res.rc != 0:
                    fail("Failed executing 'lquerypv' command: " + lquerypv_res.stderr)
                if 'ORCLDISK' in lquerypv_res.stdout:
                    fail("Physical volume '%s' is already used by Oracle ASM." % pv)
            elif lspv_dict[pv] != vg:
                fail("Physical volume '%s' is in use by another volume group '%s'." % (pv, lspv_dict[pv]))

    # Helper: validate VG state
    def _validate_vg():
        lsvg_active_res = ctx.run(["lsvg", "-o"], mutates=False)
        lsvg_all_res = ctx.run(["lsvg"], mutates=False)
        if lsvg_active_res.rc != 0 or lsvg_all_res.rc != 0:
            fail("Failed executing 'lsvg' command")

        active_vgs = lsvg_active_res.stdout.splitlines()
        all_vgs = lsvg_all_res.stdout.splitlines()

        if vg in all_vgs and vg not in active_vgs:
            return False, "Volume group '%s' is in varyoff state." % vg
        elif vg in active_vgs:
            return True, "Volume group '%s' is in varyon state." % vg
        else:
            return None, "Volume group '%s' does not exist." % vg

    # Determine PP size argument
    pp_size_str = ""
    if pp_size != None:
        pp_size_str = "-s %d" % pp_size

    vg_state, msg = _validate_vg()

    if state == "present":
        if not pvs:
            fail("pvs is required to state 'present'.")

        if ctx.check_mode:
            if vg_state == True:
                return {"changed": False, "msg": "Volume group '%s' already exists and is varyon." % vg}
            elif vg_state == False:
                return {"changed": False, "msg": "Volume group '%s' exists but is varyoff; would varyon." % vg}
            # vg_state == None → VG does not exist → will create
            return {"changed": True, "msg": "would create volume group '%s'" % vg}

        # Validate PVs
        _validate_pv(pvs)

        # Volume group creation or extension
        if vg_state == None:
            # Create VG
            mkvg_opt = {"normal": "", "big": "-B", "scalable": "-S"}
            force_opt = "-f" if force else ""
            cmd = ["mkvg", mkvg_opt[vg_type], pp_size_str, force_opt, "-y", vg] + pvs
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                fail("Creating volume group '%s' failed: %s" % (vg, res.stderr))
            return {"changed": True, "msg": "Volume group '%s' created." % vg}

        elif vg_state == True:
            # VG exists and is varyon → extend
            extendvg_res = ctx.run(["extendvg", vg] + pvs, mutates=True)
            if extendvg_res.rc != 0:
                fail("Extending volume group '%s' failed: %s" % (vg, extendvg_res.stderr))
            return {"changed": True, "msg": "Volume group '%s' extended." % vg}

        elif vg_state == False:
            # VG exists but is varyoff → varyon then extend
            varyon_res = ctx.run(["varyonvg", vg], mutates=True)
            if varyon_res.rc != 0:
                fail("Varyon volume group '%s' failed: %s" % (vg, varyon_res.stderr))
            extendvg_res = ctx.run(["extendvg", vg] + pvs, mutates=True)
            if extendvg_res.rc != 0:
                fail("Extending volume group '%s' failed: %s" % (vg, extendvg_res.stderr))
            return {"changed": True, "msg": "Volume group '%s' created (extended after varyon)." % vg}

        return {"changed": False, "msg": "Volume group '%s' already in desired state." % vg}

    elif state == "absent":
        if ctx.check_mode:
            if vg_state == None:
                return {"changed": False, "msg": "Volume group '%s' does not exist; nothing to remove." % vg}
            else:
                return {"changed": True, "msg": "would remove volume group '%s'" % vg}

        if vg_state == None:
            return {"changed": False, "msg": "Volume group '%s' does not exist; nothing to do." % vg}

        # Determine PVs to remove
        if not pvs:
            # Get all PVs from the VG
            lsvg_p_res = ctx.run(["lsvg", "-p", vg], mutates=False)
            if lsvg_p_res.rc != 0:
                fail("Failed to list PVs for '%s': %s" % (vg, lsvg_p_res.stderr))
            pvs_to_remove = []
            for line in lsvg_p_res.stdout.splitlines()[2:]:  # skip header lines
                parts = line.split()
                if parts:
                    pvs_to_remove.append(parts[0])
        else:
            pvs_to_remove = pvs

        if len(pvs_to_remove) == 0:
            return {"changed": False, "msg": "No physical volumes to remove."}

        # Reduce VG
        reduce_res = ctx.run(["reducevg", "-df", vg] + pvs_to_remove, mutates=True)
        if reduce_res.rc != 0:
            fail("Unable to remove PV(s) from volume group '%s': %s" % (vg, reduce_res.stderr))

        if not pvs:
            msg = "Volume group '%s' removed." % vg
        else:
            msg = "Physical volume(s) '%s' removed from volume group '%s'." % (" ".join(pvs_to_remove), vg)
        return {"changed": True, "msg": msg}

    elif state == "varyon":
        if ctx.check_mode:
            if vg_state == None:
                fail("Volume group '%s' does not exist." % vg)
            elif vg_state == True:
                return {"changed": False, "msg": "Volume group '%s' already varyon." % vg}
            else:
                return {"changed": True, "msg": "would varyon volume group '%s'" % vg}

        if vg_state == None:
            fail("Volume group '%s' does not exist." % vg)

        if vg_state == True:
            return {"changed": False, "msg": "Volume group '%s' already varyon." % vg}

        varyon_res = ctx.run(["varyonvg", vg], mutates=True)
        if varyon_res.rc != 0:
            fail("Command 'varyonvg' failed for '%s': %s" % (vg, varyon_res.stderr))
        return {"changed": True, "msg": "Varyon volume group '%s' completed." % vg}

    elif state == "varyoff":
        if ctx.check_mode:
            if vg_state == None:
                fail("Volume group '%s' does not exist." % vg)
            elif vg_state == False:
                return {"changed": False, "msg": "Volume group '%s' already varyoff." % vg}
            else:
                return {"changed": True, "msg": "would varyoff volume group '%s'" % vg}

        if vg_state == None:
            fail("Volume group '%s' does not exist." % vg)

        if vg_state == False:
            return {"changed": False, "msg": "Volume group '%s' already varyoff." % vg}

        varyoff_res = ctx.run(["varyoffvg", vg], mutates=True)
        if varyoff_res.rc != 0:
            fail("Command 'varyoffvg' failed for '%s': %s" % (vg, varyoff_res.stderr))
        return {"changed": True, "msg": "Varyoff volume group '%s' completed." % vg}

    else:
        fail("Unexpected state: %s" % state)
