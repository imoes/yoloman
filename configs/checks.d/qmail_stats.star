# Top-level constants for thresholds
DEFAULT_DEFERRED_WARN = 10
DEFAULT_DEFERRED_CRIT = 20

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"deferred": [DEFAULT_DEFERRED_WARN, DEFAULT_DEFERRED_CRIT]},
                        "metrics": ["queue"]
                    }
                ]
            }
        }

    # Check mode: get queue length from agent data
    # The Checkmk agent section reads from /var/spool/mqueue-count or similar.
    # We replicate the agent logic by reading the same file path.
    queue_file = "/var/spool/mqueue-count"
    if not ctx.file_exists(queue_file):
        return {
            "changed": False,
            "msg": "queue file not found: " + queue_file,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    content = ctx.file_read(queue_file).strip()
    if not content:
        return {
            "changed": False,
            "msg": "queue file empty",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Parse queue length (first token only, as per source)
    length_str = content.split()[0]
    if not length_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid queue length: " + length_str,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    queue_length = int(length_str)

    # Extract thresholds from params
    deferred = params.get("deferred", [DEFAULT_DEFERRED_WARN, DEFAULT_DEFERRED_CRIT])
    warn = deferred[0]
    crit = deferred[1]

    # Determine state based on thresholds (upper levels)
    state = "OK"
    if queue_length >= crit:
        state = "CRIT"
    elif queue_length >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Deferred mails: %d" % queue_length,
        "data": {
            "state": state,
            "metrics": {"queue": queue_length},
            "details": ""
        }
    }