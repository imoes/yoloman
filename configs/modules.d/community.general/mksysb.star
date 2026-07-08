def main(ctx, params):
    name = params["name"]
    storage_path = params["storage_path"]
    
    # Check storage path exists
    if not ctx.file_exists(storage_path):
        fail("Storage path %s is not valid." % storage_path)
    
    # Check if target file already exists (idempotency)
    target_file = storage_path + "/" + name
    if ctx.file_exists(target_file):
        return {"changed": False, "msg": "Backup %s already exists" % target_file}
    
    # Build mksysb command
    cmd = ["mksysb", "-X"]
    
    # Map params to command flags (default values from argspec)
    if params.get("create_map_files", False):
        cmd.append("-m")
    if params.get("use_snapshot", False):
        cmd.append("-T")
    if params.get("exclude_files", False):
        cmd.append("-e")
    if params.get("exclude_wpar_files", False):
        cmd.append("-G")
    if params.get("new_image_data", True):
        cmd.append("-i")
    # software_packing uses -p when False (so use -p if NOT present)
    if not params.get("software_packing", False):
        cmd.append("-p")
    if params.get("extended_attrs", True):
        cmd.append("-a")
    # backup_crypt_files uses -Z when False (so use -Z if NOT present)
    if not params.get("backup_crypt_files", True):
        cmd.append("-Z")
    if params.get("backup_dmapi_fs", True):
        cmd.append("-A")
    
    # Add output path
    cmd.append(target_file)
    
    # Run mksysb (mutates=True)
    res = ctx.run(cmd, mutates=True)
    
    if res.skipped:
        # In check_mode: return would-change
        return {"changed": True, "msg": "would create mksysb backup %s" % target_file}
    
    if res.rc != 0:
        fail("mksysb failed: %s" % res.stderr if res.stderr else res.stdout)
    
    return {"changed": True, "msg": "Created mksysb backup %s" % target_file}
