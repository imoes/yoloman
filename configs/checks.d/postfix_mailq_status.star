# ===== check plugin: cmk/plugins/postfix/agent_based/postfix_mailq_status.py =====
# Translated to a read-only Starlark check module for the yolo-man agent.

# Postfix mail system status monitor.
#
# Reads the Postfix queue status from the master.pid file(s) on the host.
# Postfix writes its PID to /var/spool/postfix/pid/master.pid when running.
# This translation reproduces the Checkmk agent-style parse logic against the
# real on-host PID file so no Checkmk agent is required.

_PREFIX_PID_DIR = "/var/spool/postfix/pid"
_DEFAULT_PID_FILE = _PREFIX_PID_DIR + "/master.pid"

_STATE_OK = "OK"
_STATE_CRIT = "CRIT"
_STATE_UNKNOWN = "UNKNOWN"

_PID_FILE_NOT_READABLE = "PID file exists but is not readable"


def _read_pid_file(ctx, path):
    # Returns (pid, error) where pid is an int or None and error is a str or None.
    # Mirrors parse_postfix_mailq_status: if the PID file exists and is readable,
    # the first line's first token is the PID. Missing file => (None, None).
    # Unreadable/empty/malformed => (None, _PID_FILE_NOT_READABLE).
    exists = ctx.file_exists(path)
    if not exists:
        return None, None
    content = ctx.file_read(path)
    lines = content.splitlines()
    if not lines:
        return None, _PID_FILE_NOT_READABLE
    first = lines[0].strip()
    tokens = first.split()
    pid_str = tokens[0] if tokens else ""
    if pid_str.isdigit():
        return int(pid_str), None
    return None, _PID_FILE_NOT_READABLE


def _probe_default(ctx):
    # The 'default' (formerly 'postfix') instance is the main Postfix master.
    pid, err = _read_pid_file(ctx, _DEFAULT_PID_FILE)
    if pid != None:
        return {"pid": pid, "error": None}
    return {"pid": None, "error": err}


def main(ctx, params):
    if params.get("_discover"):
        entry = _probe_default(ctx)

        # No PID file at all -> SystemNotRunning -> do not discover.
        if entry["pid"] == None and entry["error"] == None:
            return {
                "changed": False,
                "msg": "discovered 0 postfix instances",
                "data": {"discovery": []},
            }

        discovery = []
        # The Checkmk discovery skips only SystemNotRunning (no pid file),
        # which is already handled above. Any other state yields a service.
        discovery.append({
            "item": "default",
            "params": {"warn": 0, "crit": 0},
            "metrics": ["pid"],
        })

        return {
            "changed": False,
            "msg": "discovered %d postfix instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if item == "" or item == "postfix":
        item = "default"

    entry = _probe_default(ctx)

    if entry["pid"] == None and entry["error"] == None:
        return {
            "changed": False,
            "msg": "no postfix instance found",
            "data": {
                "state": _STATE_UNKNOWN,
                "metrics": {},
                "details": "no PID file for %s" % item,
            },
        }

    if entry["pid"] != None:
        pid = entry["pid"]
        return {
            "changed": False,
            "msg": "Status: the Postfix mail system is running, PID: %d" % pid,
            "data": {
                "state": _STATE_OK,
                "metrics": {"pid": pid},
                "details": "",
            },
        }

    # error case -> CRIT
    return {
        "changed": False,
        "msg": "Status: %s" % entry["error"],
        "data": {
            "state": _STATE_CRIT,
            "metrics": {},
            "details": entry["error"],
        },
    }