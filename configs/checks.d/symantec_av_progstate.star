# symantec_av_progstate.star
# AV Program Status (read-only Checkmk check translation)

def main(ctx, params):
    def probe_av_status():
        """Probe for Symantec AV program status on the host.

        Returns (found, status_string) where found indicates if the
        program/device is present and status_string the raw status line.
        Treats rc == 127 (command not found) as 'not installed'.
        """
        probe = ctx.run(["symcfg", "list", "-t"], mutates=False)
        if probe.rc == 127:
            return (False, "")
        if probe.rc != 0 and probe.rc != 1:
            pass

        res = ctx.run(["/usr/sbin/symcfg", "list", "-t"], mutates=False)
        if res.rc == 127:
            res = ctx.run(["/usr/sbin/service", "symantec", "status"], mutates=False)
        if res.rc == 127:
            return (False, "")

        if res.rc == 0 and res.stdout.strip() != "":
            return (True, res.stdout.strip())
        return (False, "")

    if params.get("_discover"):
        found, _status = probe_av_status()
        if not found:
            return {
                "changed": False,
                "msg": "Symantec AV not present on this host",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                    }
                ],
            },
        }

    # CHECK MODE
    item = params.get("item", "")

    found, status = probe_av_status()
    if not found:
        return {
            "changed": False,
            "msg": "no Symantec AV instance found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    norm = status.lower()
    if norm != "enabled":
        return {
            "changed": False,
            "msg": "Program Status is %s" % status,
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": "",
            },
        }
    return {
        "changed": False,
        "msg": "Program enabled",
        "data": {
            "state": "OK",
            "metrics": {},
            "details": "",
        },
    }