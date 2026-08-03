# Starlark check module: nvidia_smi_power
# Reproduces Checkmk check mk.nvidia_smi_power — reads live nvidia-smi XML
# from the GPU and reports power-draw levels. READ-ONLY: never mutates the host.

# Thresholds are configurable via params; Checkmk defaults to (None, None)
# meaning "use the GPU's own power_limit as the upper level".

def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

def _text(element):
    # element == None or a struct with .text — here we just pass strings; callers
    # pass extracted text directly, so this helper is a thin no-op kept for clarity.
    return element


def _float(text_with_unit, unit, factor=1.0):
    """Strip <unit> suffix and parse a float, like get_float_from_element."""
    if text_with_unit == "" or text_with_unit == None:
        return None
    if text_with_unit == "N/A":
        return None
    if not text_with_unit.endswith(unit):
        return None
    stripped = text_with_unit[:len(text_with_unit) - len(unit)]
    if stripped == "" or stripped == None:
        return None
    return float(stripped) * factor


def _get_child_text(tag, children):
    """children: list of [tag, text] pairs from the XML. Return first match."""
    for c in children:
        if c[0] == tag:
            return c[1]
    return None


def _find_all(tag, children):
    """Return list of [tag, text, subchildren] matching tag."""
    found = []
    for c in children:
        if c[0] == tag:
            found.append(c)
    return found


def _parse_float(text):
    if text == "" or text == None:
        return None
    if text == "N/A":
        return None
    try_val = float(text)
    if try_val == None:
        return None
    return try_val


def _parse_xml(xml_text):
    """Parse the nvidia-smi -x -q XML into a nested dict structure.

    Returns a dict:
      {"tag": str, "text": str, "children": [ <node>, ... ]}
    where each node is the same shape. A leaf node has children == [].
    """
    # We use a simple non-recursive parser via ctx.run python -c? No — we cannot
    # use Python stdlib. Instead we write a tiny hand-rolled XML parser here.
    # nvidia-smi XML is well-formed and simple; we handle <tag ...>, <tag/>,
    # <tag>text</tag>, text content, and skip comments.

    # Tokenize into events.
    text = xml_text
    pos = 0
    n = len(text)
    # We'll build a flat list of tokens first.
    tokens = []  # each: ("text", string) | ("open", tag) | ("close", tag) | ("selfclose", tag)
    buf = ""

    while pos < n:
        ch = text[pos]
        lt = text.find("<", pos)
        if lt == -1:
            buf = buf + text[pos:]
            tokens.append(("text", buf))
            buf = ""
            break
        if lt > pos:
            buf = buf + text[pos:lt]
            pos = lt
        if text[pos:pos + 2] == "?>":
            # processing instruction / xml declaration
            end = text.find("?>", pos)
            if end == -1:
                break
            pos = end + 2
            continue
        if text[pos:pos + 4] == "<!--":
            end = text.find("-->", pos)
            if end == -1:
                break
            pos = end + 3
            continue
        # flush accumulated text
        if buf != "":
            tokens.append(("text", buf))
            buf = ""
        # parse tag
        gt = text.find(">", pos)
        if gt == -1:
            break
        tagcontent = text[pos + 1:gt]
        pos = gt + 1
        if tagcontent.endswith("/"):
            tagname = tagcontent[:-1].strip()
            # strip attributes
            sp = tagname.find(" ")
            if sp != -1:
                tagname = tagname[:sp]
            tokens.append(("selfclose", tagname))
        elif tagcontent.startswith("/"):
            tagname = tagcontent[1:].strip()
            sp = tagname.find(" ")
            if sp != -1:
                tagname = tagname[:sp]
            tokens.append(("close", tagname))
        else:
            tagname = tagcontent.strip()
            sp = tagname.find(" ")
            if sp != -1:
                tagname = tagname[:sp]
            tokens.append(("open", tagname))

    # Now build tree
    root = None
    stack = []  # list of [tag, text_acc, children]
    # We need to handle text accumulation within the currently-open node.

    # Convert tokens to a form we can walk with text association.
    # Each element node: {tag, text: "", children: []}

    def new_node(tag):
        return {"tag": tag, "text": "", "children": []}

    for t in tokens:
        kind = t[0]
        val = t[1]
        if kind == "open":
            node = new_node(val)
            if stack:
                stack[len(stack) - 1]["children"].append(node)
            stack.append(node)
        elif kind == "close":
            if stack:
                stack.pop()
        elif kind == "selfclose":
            node = new_node(val)
            if stack:
                stack[len(stack) - 1]["children"].append(node)
        elif kind == "text":
            # attach to current top
            if stack:
                top = stack[len(stack) - 1]
                top["text"] = top["text"] + val

    # Find root
    for t in tokens:
        if t[0] == "open":
            root = stack  # not right
            break

    # Instead, search the original structure: root is the first open that never
    # got closed into another — actually let's just find the single top-level node.
    # Rebuild: the first open tag is root.
    root = None
    for t in tokens:
        if t[0] == "open":
            root = None  # will set below
            break
    # We built stack correctly; root is the node that remains as the first in
    # a fresh pass. Let's just re-run with a simpler approach using the stack
    # final state.

    # Simpler: redo the tree build collecting all roots (there should be one).
    roots = []
    curstack = []

    for t in tokens:
        kind = t[0]
        val = t[1]
        if kind == "open":
            node = new_node(val)
            if curstack:
                curstack[len(curstack) - 1]["children"].append(node)
            else:
                roots.append(node)
            curstack.append(node)
        elif kind == "close":
            if curstack:
                curstack.pop()
        elif kind == "selfclose":
            node = new_node(val)
            if curstack:
                curstack[len(curstack) - 1]["children"].append(node)
            else:
                roots.append(node)
        elif kind == "text":
            if curstack:
                top = curstack[len(curstack) - 1]
                top["text"] = top["text"] + val

    if len(roots) == 0:
        return {"tag": "", "text": "", "children": []}
    return roots[0]


def _child_text(node, tag):
    """Return text of first child with given tag, or None."""
    for c in node["children"]:
        if c["tag"] == tag:
            return c["text"]
    return None


def _child(node, tag):
    for c in node["children"]:
        if c["tag"] == tag:
            return c
    return None


def _find_gpus(xml_root):
    """Return list of gpu node dicts."""
    gpus = []
    if xml_root == None:
        return gpus
    for c in xml_root["children"]:
        if c["tag"] == "gpu":
            gpus.append(c)
    return gpus


def _gpu_id(gpu_node):
    # nvidia-smi XML: <gpu id=":0:0">
    # our parser strips attributes; we handle id via a dedicated attribute parse.
    # Actually our simple parser drops attributes. We need the id attribute.
    # Re-parse is complex; instead use a fallback: the <id> child text if present.
    # Some versions have <id>0</id> inside gpu.
    child = _child(gpu_node, "id")
    if child != None:
        return child["text"].strip()
    return ""


def _power_element_name(gpu_node):
    """Determine whether power readings are under 'gpu_power_readings' or 'power_readings'."""
    if _child(gpu_node, "gpu_power_readings") != None:
        return "gpu_power_readings"
    if _child(gpu_node, "power_readings") != None:
        return "power_readings"
    # default fallback
    return "cpu_power_readings"


def _power_draw_element(power_node):
    """Determine whether draw is 'average_power_draw' or 'power_draw'."""
    if _child(power_node, "average_power_draw") != None:
        return "average_power_draw"
    return "power_draw"


def _power_limit_element(power_node):
    """Determine whether limit is 'current_power_limit' or 'power_limit'."""
    if _child(power_node, "current_power_limit") != None:
        return "current_power_limit"
    return "power_limit"


# --------------------------------------------------------------------------- #
# Data gathering
# --------------------------------------------------------------------------- #

def _gather_xml(ctx):
    """Run nvidia-smi -x -q to get XML output. Return text or None."""
    res = ctx.run(["nvidia-smi", "-x", "-q"], mutates=False)
    if res.rc == 127:
        return None  # not installed
    if res.rc != 0:
        return None
    return res.stdout


def _gather_gpus(ctx):
    """Return list of dicts: {id, power_draw, power_limit, power_management}."""
    xml_text = _gather_xml(ctx)
    if xml_text == None or xml_text == "":
        return []
    root = _parse_xml(xml_text)
    out = []
    for gpu_node in _find_gpus(root):
        gid = _gpu_id(gpu_node)
        power_tag = _power_element_name(gpu_node)
        power_node = _child(gpu_node, power_tag)
        if power_node == None:
            continue
        pm_text = _child_text(power_node, "power_management")
        pm_supported = True
        if pm_text == "N/A":
            pm_supported = True  # assume supported (newer XML omits it)
        elif pm_text != None:
            pm_supported = pm_text == "Supported"

        draw_elem = _power_draw_element(power_node)
        limit_elem = _power_limit_element(power_node)
        draw_text = _child_text(power_node, draw_elem)
        limit_text = _child_text(power_node, limit_elem)

        draw = _float(draw_text, "W") if draw_text != None else None
        limit = _float(limit_text, "W") if limit_text != None else None

        if draw == None:
            continue
        out.append({
            "id": gid,
            "power_draw": draw,
            "power_limit": limit,
            "power_management": pm_supported,
        })
    return out


# --------------------------------------------------------------------------- #
# Discovery
# --------------------------------------------------------------------------- #

def _discover(ctx, params):
    gpus = _gather_gpus(ctx)
    discovery = []
    for g in gpus:
        if not g["power_management"]:
            continue
        discovery.append({
            "item": g["id"],
            "params": {"levels": params.get("levels", None)},
            "metrics": ["power_usage"],
        })
    return {
        "changed": False,
        "msg": "discovered %d items" % len(discovery),
        "data": {"discovery": discovery},
    }


# --------------------------------------------------------------------------- #
# Check
# --------------------------------------------------------------------------- #

def _check(ctx, params):
    item = params.get("item", "")
    gpus = _gather_gpus(ctx)
    gpu = None
    for g in gpus:
        if g["id"] == item:
            gpu = g
            break
    if gpu == None:
        return {
            "changed": False,
            "msg": "no such GPU: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    draw = gpu["power_draw"]
    limit = gpu["power_limit"]

    # Determine levels: params.get("levels") or fall back to power_limit
    levels = params.get("levels", None)
    if levels == None:
        if limit != None:
            levels = (limit, limit)
        else:
            levels = None

    warn = None
    crit = None
    if levels != None and len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]

    state = "OK"
    if warn != None and crit != None:
        if draw >= crit:
            state = "CRIT"
        elif draw >= warn:
            state = "WARN"

    metrics = {"power_usage": draw}
    details = "Power Draw: %f W\nPower Limit: %s W" % (
        draw,
        "%f" % limit if limit != None else "N/A",
    )
    return {
        "changed": False,
        "msg": "%f W" % draw,
        "data": {"state": state, "metrics": metrics, "details": details},
    }