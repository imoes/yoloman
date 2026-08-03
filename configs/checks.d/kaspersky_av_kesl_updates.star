# Checkmk check: kaspersky_av_kesl_updates — AV Update Status (Kaspersky Endpoint Security for Linux)
# Translated to a read-only Starlark check module for the yolo-man agent.
#
# The Checkmk agent section `kaspersky_av_kesl_updates` is produced by the host's
# Kaspersky Endpoint Security for Linux (KESL) command-line tool. Here we read the
# SAME underlying source the agent plugin reads: the `kesl` CLI tool on the host.
# No Checkmk binaries or agent sections are used.

def _parse_kesl_lines(out):
    """Parse `kesl status` block-style output into {key: value} using ':' separator.

    Reproduces the Checkmk parse function which joins multi-word values. We split
    on the first ': ' so values (dates, numbers) survive intact.
    """
    section = {}
    parts = out.split("\n")
    for line in parts:
        # Each real line looks like "Key: value"
        idx = line.find(":")
        if idx == -1:
            continue
        key = line[:idx].strip()
        value = line[idx + 1:].strip()
        if key == "":
            continue
        # Mimic Checkmk: keep last value if duplicate keys appear
        section[key] = value
    return section


def _probe_kesl_status(ctx):
    """Run the KESL status command and return the parsed section dict, or {} on absence."""
    res = ctx.run(
        [
            "kesl",
            "--task",
            "status",
            "--query",
            "Anti-virus databases loaded,Last release date of databases,Application databases loaded,Anti-virus database records",
        ],
        mutates=False,
    )
    # rc == 127 or rc != 0 means KESL is not installed / command failed -> absence
    if res.rc != 0:
        return {}
    return _parse_kesl_lines(res.stdout)


def main(ctx, params):
    section = _probe_kesl_status(ctx)

    if params.get("_discover"):
        if section:
            return {
                "changed": False,
                "msg": "discovered AV Update Status",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {},
                            "metrics": [
                                "databases_loaded",
                                "database_records",
                            ],
                        }
                    ]
                },
            }
        return {
            "changed": False,
            "msg": "Kaspersky Endpoint Security not installed, no items discovered",
            "data": {"discovery": []},
        }

    item = params.get("item", "")
    if not section:
        return {
            "changed": False,
            "msg": "Kaspersky Endpoint Security for Linux is not installed (no AV update status available)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    metrics = {}
    summaries = []

    # Databases loaded -> OK if "Yes", CRIT otherwise
    loaded_raw = section.get("Anti-virus databases loaded", section.get("Application databases loaded"))
    if loaded_raw != None:
        loaded = loaded_raw == "Yes"
        state_loaded = "OK" if loaded else "CRIT"
        metrics["databases_loaded"] = 1.0 if loaded else 0.0
        summaries.append("Databases loaded: %s (%s)" % ("Yes" if loaded else "No", state_loaded))

    # Database release date -> render as a summary (no threshold applied by Checkmk)
    release_date = section.get("Last release date of databases")
    if release_date != None:
        summaries.append("Database date: %s" % release_date)

    # Database records -> numeric perfdata
    records_raw = section.get("Anti-virus database records")
    db_records = 0
    if records_raw != None:
        digits = records_raw.replace(",", "").replace(" ", "")
        if digits.isdigit():
            db_records = int(digits)
        metrics["database_records"] = float(db_records)
        summaries.append("Database records: %s" % records_raw)

    # Aggregate state: CRIT if any CRIT, else OK
    state = "CRIT" if (loaded_raw != None and loaded_raw != "Yes") else "OK"
    msg = "; ".join(summaries) if summaries else "AV update status: no data"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }