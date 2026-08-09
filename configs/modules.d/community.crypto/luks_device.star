def main(ctx, params):
    # Extract common parameters
    device = params.get("device")
    state = params.get("state", "present")
    name = params.get("name")
    keyfile = params.get("keyfile")
    passphrase = params.get("passphrase")
    new_keyfile = params.get("new_keyfile")
    new_passphrase = params.get("new_passphrase")
    keyslot = params.get("keyslot")
    new_keyslot = params.get("new_keyslot")
    force_remove_last_key = params.get("force_remove_last_key", False)
    label = params.get("label")
    uuid = params.get("uuid")
    cipher = params.get("cipher")
    hash_ = params.get("hash")
    pbkdf = params.get("pbkdf")
    keysize = params.get("keysize")
    type_ = params.get("type")
    sector_size = params.get("sector_size")
    perf_same_cpu_crypt = params.get("perf_same_cpu_crypt", False)
    perf_submit_from_crypt_cpus = params.get("perf_submit_from_crypt_cpus", False)
    perf_no_read_workqueue = params.get("perf_no_read_workqueue", False)
    perf_no_write_workqueue = params.get("perf_no_write_workqueue", False)
    persistent = params.get("persistent", False)
    allow_discards = params.get("allow_discards", False)

    # Determine device name if not provided via label/uuid/name
    if device == None:
        if label != None:
            res = ctx.run(["blkid", "--label", label])
            if res.rc == 0 and res.stdout.strip():
                device = res.stdout.strip()
        elif uuid != None:
            res = ctx.run(["blkid", "--uuid", uuid])
            if res.rc == 0 and res.stdout.strip():
                device = res.stdout.strip()
        elif name != None:
            # Try to get device from cryptsetup status
            res = ctx.run(["cryptsetup", "status", name])
            if res.rc == 0:
                # Parse device line from output
                for line in res.stdout.splitlines():
                    if line.strip().startswith("device:"):
                        device = line.strip().split(None, 1)[1]
                        break

    # Helper to determine LUKS type
    luks_type = None
    if device != None and ctx.file_exists(device):
        # Check if LUKS by running isLuks
        res = ctx.run(["cryptsetup", "isLuks", device])
        if res.rc == 0:
            luks_type = "luks2" if _detect_luks2(ctx, device) else "luks1"

    # Validate keyslot if specified
    if keyslot != None:
        _validate_keyslot(ctx, keyslot, luks_type, type_, True)

    if new_keyslot != None:
        _validate_keyslot(ctx, new_keyslot, luks_type, type_, False)

    # State: present
    if state == "present":
        if device == None:
            fail("device is required for state=present")
        if keyfile == None and passphrase == None:
            fail("keyfile or passphrase is required for state=present")

        if luks_type == None:
            # Create LUKS device
            _create_luks(ctx, device, keyfile, passphrase, keyslot, keysize, cipher, hash_, sector_size, pbkdf, label, type_)
            return {"changed": True, "msg": "LUKS container created"}

        # Already exists, idempotent
        return {"changed": False, "msg": "LUKS container already present"}

    # State: absent
    if state == "absent":
        if device == None and name == None:
            fail("device or name is required for state=absent")
        if device == None:
            res = ctx.run(["cryptsetup", "status", name])
            if res.rc == 0:
                for line in res.stdout.splitlines():
                    if line.strip().startswith("device:"):
                        device = line.strip().split(None, 1)[1]
                        break
            else:
                return {"changed": False, "msg": "Device/container not found"}

        if luks_type == None:
            return {"changed": False, "msg": "Not a LUKS container"}

        # Close and wipe
        if name == None:
            res = ctx.run(["cryptsetup", "status", device])
            if res.rc == 0:
                for line in res.stdout.splitlines():
                    if line.strip().startswith("device:"):
                        device_path = line.strip().split(None, 1)[1]
                    elif line.strip().startswith("name:"):
                        name = line.strip().split(None, 1)[1]
        if name != None:
            res = ctx.run(["cryptsetup", "close", name])
            if res.rc != 0 and not res.skipped:
                fail("Failed to close LUKS container: " + res.stderr)
        res = ctx.run(["wipefs", "--all", device])
        if res.rc != 0 and not res.skipped:
            fail("Failed to wipe LUKS headers: " + res.stderr)
        # Wipe second header for LUKS2
        if luks_type == "luks2":
            _wipe_luks2_headers(ctx, device)
        return {"changed": True, "msg": "LUKS container removed"}

    # State: opened
    if state == "opened":
        if device == None:
            fail("device is required for state=opened")
        if keyfile == None and passphrase == None:
            fail("keyfile or passphrase is required for state=opened")

        # Get container name
        if name == None:
            res = ctx.run(["lsblk", "-n", device, "-o", "UUID"])
            if res.rc != 0:
                fail("Failed to get UUID for device: " + res.stderr)
            dev_uuid = res.stdout.strip()
            name = "luks-" + dev_uuid

        # Check if already open
        res = ctx.run(["cryptsetup", "status", name])
        if res.rc == 0:
            return {"changed": False, "msg": "LUKS container already opened", "name": name}

        # Open the container
        _open_luks(ctx, device, keyfile, passphrase, perf_same_cpu_crypt, perf_submit_from_crypt_cpus,
                   perf_no_read_workqueue, perf_no_write_workqueue, persistent, allow_discards, name)
        return {"changed": True, "msg": "LUKS container opened", "name": name}

    # State: closed
    if state == "closed":
        if name == None and device == None:
            fail("device or name is required for state=closed")
        if name == None:
            res = ctx.run(["cryptsetup", "status", device])
            if res.rc == 0:
                for line in res.stdout.splitlines():
                    if line.strip().startswith("name:"):
                        name = line.strip().split(None, 1)[1]
                        break
            else:
                return {"changed": False, "msg": "LUKS container not open"}
        else:
            # Check if open by name
            res = ctx.run(["cryptsetup", "status", name])
            if res.rc != 0:
                return {"changed": False, "msg": "LUKS container not open"}

        # Close the container
        res = ctx.run(["cryptsetup", "close", name])
        if res.rc != 0 and not res.skipped:
            fail("Failed to close LUKS container: " + res.stderr)
        return {"changed": True, "msg": "LUKS container closed"}

    fail("Unsupported state: " + state)


def _detect_luks2(ctx, device):
    # Read second header at various offsets
    offsets = [0x4000, 0x8000, 0x10000, 0x20000, 0x40000, 0x80000, 0x100000, 0x200000, 0x400000]
    for offset in offsets:
        res = ctx.run(["dd", "if=" + device, "bs=6", "skip=" + str(offset // 6), "count=1"])
        if res.rc == 0 and res.stdout.startswith(b'SKUL\xba\xbe'.decode('latin-1')):
            return True
    return False


def _wipe_luks2_headers(ctx, device):
    # Use dd to zero second header positions
    offsets = [0x4000, 0x8000, 0x10000, 0x20000, 0x40000, 0x80000, 0x100000, 0x200000, 0x400000]
    for offset in offsets:
        res = ctx.run(["dd", "if=/dev/zero", "of=" + device, "bs=6", "seek=" + str(offset // 6), "count=1", "conv=notrunc"])
        if res.rc != 0:
            # Skip if not applicable
            pass


def _validate_keyslot(ctx, keyslot, luks_type, type_, create):
    if keyslot == None:
        return
    if create:
        if type_ == None and luks_type == None:
            if not (0 <= keyslot and keyslot <= 7):
                fail("When not specifying a type, only keyslots 0-7 are allowed.")
        elif type_ == "luks1" and not (0 <= keyslot and keyslot <= 7):
            fail("keyslot must be between 0 and 7 when using LUKS1.")
        elif type_ == "luks2" and not (0 <= keyslot and keyslot <= 31):
            fail("keyslot must be between 0 and 31 when using LUKS2.")
        elif type_ == None and luks_type == "luks2" and (keyslot > 7):
            fail("You must specify type=luks2 when creating a new LUKS device to use keyslots 8-31.")
    if luks_type == "luks1" and not (0 <= keyslot and keyslot <= 7):
        fail("keyslot must be between 0 and 7 when using LUKS1.")
    if luks_type == "luks2" and not (0 <= keyslot and keyslot <= 31):
        fail("keyslot must be between 0 and 31 when using LUKS2.")


def _build_pbkdf_options(pbkdf):
    opts = []
    if pbkdf != None:
        if pbkdf.get("iteration_time") != None:
            opts.extend(["--iter-time", str(int(pbkdf["iteration_time"] * 1000))])
        if pbkdf.get("iteration_count") != None:
            opts.extend(["--pbkdf-force-iterations", str(pbkdf["iteration_count"])])
        if pbkdf.get("algorithm") != None:
            opts.extend(["--pbkdf", pbkdf["algorithm"]])
        if pbkdf.get("memory") != None:
            opts.extend(["--pbkdf-memory", str(pbkdf["memory"])])
        if pbkdf.get("parallel") != None:
            opts.extend(["--pbkdf-parallel", str(pbkdf["parallel"])])
    return opts


def _create_luks(ctx, device, keyfile, passphrase, keyslot, keysize, cipher, hash_, sector_size, pbkdf, label, type_):
    options = []
    if keysize != None:
        options.extend(["--key-size", str(keysize)])
    if label != None:
        options.extend(["--label", label])
        type_ = "luks2"
    if type_ != None:
        options.extend(["--type", type_])
    if cipher != None:
        options.extend(["--cipher", cipher])
    if hash_ != None:
        options.extend(["--hash", hash_])
    options.extend(_build_pbkdf_options(pbkdf))
    if sector_size != None:
        options.extend(["--sector-size", str(sector_size)])
    if keyslot != None:
        options.extend(["--key-slot", str(keyslot)])

    args = ["cryptsetup", "luksFormat"] + options + ["-q", device]
    if keyfile:
        args.append(keyfile)

    if passphrase:
        res = ctx.run(args, data=passphrase, mutates=True)
    else:
        res = ctx.run(args, mutates=True)
    if res.rc != 0:
        fail("Failed to create LUKS container: " + res.stderr)


def _open_luks(ctx, device, keyfile, passphrase, perf_same_cpu_crypt, perf_submit_from_crypt_cpus,
               perf_no_read_workqueue, perf_no_write_workqueue, persistent, allow_discards, name):
    args = ["cryptsetup"]
    if keyfile:
        args.extend(["--key-file", keyfile])
    if perf_same_cpu_crypt:
        args.extend(["--perf-same_cpu_crypt"])
    if perf_submit_from_crypt_cpus:
        args.extend(["--perf-submit_from_crypt_cpus"])
    if perf_no_read_workqueue:
        args.extend(["--perf-no_read_workqueue"])
    if perf_no_write_workqueue:
        args.extend(["--perf-no_write_workqueue"])
    if persistent:
        args.extend(["--persistent"])
    if allow_discards:
        args.extend(["--allow-discards"])
    args.extend(["open", "--type", "luks", device, name])

    if passphrase:
        res = ctx.run(args, data=passphrase, mutates=True)
    else:
        res = ctx.run(args, mutates=True)
    if res.rc != 0:
        fail("Failed to open LUKS container: " + res.stderr)
