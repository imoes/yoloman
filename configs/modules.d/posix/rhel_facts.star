def main(ctx, params):
    # Check if the system is rpm-ostree based by looking for /run/ostree-booted
    if ctx.file_exists("/run/ostree-booted"):
        ansible_facts = {"pkg_mgr": "ansible.posix.rhel_rpm_ostree"}
        return {"changed": False, "msg": "RHEL facts collected", "data": {"ansible_facts": ansible_facts}}
    else:
        return {"changed": False, "msg": "Not an rpm-ostree system, no RHEL facts set", "data": {"ansible_facts": {}}}
