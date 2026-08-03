def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["nvidia-smi", "--query-gpu=index,encoder.utilization,decoder.utilization", "--format=csv,noheader,nounits"], mutates=False)
        if probe.rc != 0:
            return {"changed": False, "msg": "nvidia-smi not available (rc=%d)" % probe.rc,
                    "data": {"discovery": []}}
        discovery = []
        lines = probe.stdout.splitlines()
        for line in lines:
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 3:
                continue
            gpu_index = parts[0]
            enc_raw = parts[1]
            dec_raw = parts[2]
            enc_val = int(enc_raw) if enc_raw != "N/A" and enc_raw != "" else -1
            dec_val = int(dec_raw) if dec_raw != "N/A" and dec_raw != "" else -1
            if enc_val >= 0 or dec_val >= 0:
                discovery.append({"item": gpu_index,
                                  "params": {"encoder_levels": None, "decoder_levels": None},
                                  "metrics": ["encoder_utilization", "decoder_utilization"]})
        return {"changed": False, "msg": "discovered %d GPUs" % len(discovery),
                "data": {"discovery": discovery}}
    item = params.get("item", "")
    probe = ctx.run(["nvidia-smi", "--query-gpu=index,encoder.utilization,decoder.utilization", "--format=csv,noheader,nounits"], mutates=False)
    if probe.rc != 0:
        return {"changed": False, "msg": "nvidia-smi not available (rc=%d)" % probe.rc,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = probe.stdout.splitlines()
    enc_val = None
    dec_val = None
    found = False
    for line in lines:
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 3:
            continue
        if parts[0] == item:
            found = True
            if parts[1] != "N/A" and parts[1] != "":
                enc_val = int(parts[1])
            if parts[2] != "N/A" and parts[2] != "":
                dec_val = int(parts[2])
            break
    if not found:
        return {"changed": False, "msg": "no such GPU: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    encoder_levels = params.get("encoder_levels")
    decoder_levels = params.get("decoder_levels")
    metrics = {}
    state = "OK"
    details_parts = []
    if enc_val != None:
        metrics["encoder_utilization"] = enc_val
        details_parts.append("Encoder: %d%%" % enc_val)
        if encoder_levels != None and len(encoder_levels) >= 2:
            warn = encoder_levels[0]
            crit = encoder_levels[1]
            if enc_val >= crit:
                state = "CRIT"
            elif enc_val >= warn:
                if state != "CRIT":
                    state = "WARN"
    if dec_val != None:
        metrics["decoder_utilization"] = dec_val
        details_parts.append("Decoder: %d%%" % dec_val)
        if decoder_levels != None and len(decoder_levels) >= 2:
            warn = decoder_levels[0]
            crit = decoder_levels[1]
            if dec_val >= crit:
                state = "CRIT"
            elif dec_val >= warn:
                if state != "CRIT":
                    state = "WARN"
    if enc_val == None and dec_val == None:
        return {"changed": False, "msg": "no encoder/decoder utilization data for GPU " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    msg = ", ".join(details_parts) if details_parts else "no utilization data"
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": msg}}