def main(ctx, params):
    input_chain = params["input_chain"]
    root_paths = params["root_certificates"]
    intermediate_paths = params.get("intermediate_certificates", [])

    # Check for openssl CLI availability
    res = ctx.run(["openssl", "version"], mutates=False)
    if res.rc != 0 or "OpenSSL" not in res.stdout:
        fail("OpenSSL CLI not available; certificate_complete_chain requires openssl")

    # Create temp directory
    tmpdir = "/tmp/cert_chain_" + str(hash(input_chain))[-6:]
    ctx.run(["mkdir", "-p", tmpdir], mutates=False)

    # Write input chain to temp file
    input_path = tmpdir + "/input.pem"
    ctx.file_write(input_path, input_chain, mode="0600")

    # Collect all root certificate paths
    all_root_paths = []
    for path in root_paths:
        if ctx.file_exists(path):
            all_root_paths.append(path)
        elif ctx.stat(path) != None and ctx.stat(path).get("is_dir", False):
            res = ctx.run(["find", path, "-type", "f"], mutates=False)
            if res.rc == 0:
                for f in res.stdout.strip().splitlines():
                    if f:
                        all_root_paths.append(f)
        else:
            fail("root_certificates path not found: " + path)

    # Collect all intermediate certificate paths
    all_intermediate_paths = []
    for path in intermediate_paths:
        if ctx.file_exists(path):
            all_intermediate_paths.append(path)
        elif ctx.stat(path) != None and ctx.stat(path).get("is_dir", False):
            res = ctx.run(["find", path, "-type", "f"], mutates=False)
            if res.rc == 0:
                for f in res.stdout.strip().splitlines():
                    if f:
                        all_intermediate_paths.append(f)
        else:
            fail("intermediate_certificates path not found: " + path)

    # Concatenate all root certs
    roots_concat_path = tmpdir + "/roots.pem"
    roots_content = ""
    for p in all_root_paths:
        roots_content += ctx.file_read(p) + "\n"
    ctx.file_write(roots_concat_path, roots_content, mode="0600")

    # Concatenate all intermediate certs
    intermediates_concat_path = tmpdir + "/intermediates.pem"
    intermediates_content = ""
    for p in all_intermediate_paths:
        intermediates_content += ctx.file_read(p) + "\n"
    ctx.file_write(intermediates_concat_path, intermediates_content, mode="0600")

    # Verify chain with openssl
    res = ctx.run([
        "openssl", "verify", "-CAfile", roots_concat_path,
        "-untrusted", intermediates_concat_path, input_path
    ], mutates=False)

    if res.rc != 0:
        fail("Cannot verify or complete certificate chain: " + res.stderr)

    # Parse input chain into individual certificates
    lines = input_chain.splitlines()
    certs = []
    current = []
    for line in lines:
        current.append(line)
        if line.strip() == "-----END CERTIFICATE-----":
            certs.append("\n".join(current))
            current = []

    if len(certs) == 0:
        fail("Input chain contains no valid certificates")

    # Extract subject/issuer for each input cert
    chain_certs = []
    for i in range(len(certs)):
        tmp_cert = tmpdir + "/cert_" + str(i) + ".pem"
        ctx.file_write(tmp_cert, certs[i], mode="0600")
        res = ctx.run(["openssl", "x509", "-in", tmp_cert, "-subject", "-issuer", "-noout"],
                      mutates=False)
        if res.rc != 0:
            fail("Failed to parse certificate " + str(i) + ": " + res.stderr)
        subject_line = ""
        issuer_line = ""
        for l in res.stdout.splitlines():
            if l.startswith("subject="):
                subject_line = l[8:].strip()
            if l.startswith("issuer="):
                issuer_line = l[7:].strip()
        chain_certs.append({"subject": subject_line, "issuer": issuer_line, "pem": certs[i]})

    # Build extended cert set from root and intermediate files
    all_certs = []
    for p in all_root_paths + all_intermediate_paths:
        content = ctx.file_read(p)
        clines = content.splitlines()
        cur = []
        for l in clines:
            cur.append(l)
            if l.strip() == "-----END CERTIFICATE-----":
                all_certs.append("\n".join(cur))
                cur = []

    # Parse each external cert's subject/issuer
    ext_certs = []
    for i in range(len(all_certs)):
        tmp_cert = tmpdir + "/ext_" + str(i) + ".pem"
        ctx.file_write(tmp_cert, all_certs[i], mode="0600")
        res = ctx.run(["openssl", "x509", "-in", tmp_cert, "-subject", "-issuer", "-noout"],
                      mutates=False)
        if res.rc != 0:
            continue  # skip unparseable
        subject_line = ""
        issuer_line = ""
        for l in res.stdout.splitlines():
            if l.startswith("subject="):
                subject_line = l[8:].strip()
            if l.startswith("issuer="):
                issuer_line = l[7:].strip()
        ext_certs.append({"subject": subject_line, "issuer": issuer_line, "pem": all_certs[i]})

    # Complete chain
    seen_subjects = set()
    for c in chain_certs:
        seen_subjects.add(c["subject"])

    completed_certs = []
    current_subject = chain_certs[-1]["issuer"]

    for _ in range(20):  # safe bound
        found = None
        for cert in ext_certs:
            if cert["subject"] == current_subject and cert["subject"] not in seen_subjects:
                found = cert
                break

        if found == None:
            fail("Cannot complete certificate chain — missing issuer: " + current_subject)

        completed_certs.append(found)
        seen_subjects.add(found["subject"])

        if found["subject"] == found["issuer"]:
            break

        current_subject = found["issuer"]

    if len(completed_certs) == 0:
        fail("Chain did not terminate at a root certificate")

    # Prepare results
    complete_chain = [c["pem"] for c in chain_certs] + [c["pem"] for c in completed_certs]
    root_pem = completed_certs[-1]["pem"]
    chain_pem = [c["pem"] for c in completed_certs]

    if ctx.check_mode:
        return {
            "changed": True,
            "msg": "would complete certificate chain",
            "data": {
                "root": root_pem,
                "chain": chain_pem,
                "complete_chain": complete_chain
            }
        }

    return {
        "changed": True,
        "msg": "completed certificate chain successfully",
        "data": {
            "root": root_pem,
            "chain": chain_pem,
            "complete_chain": complete_chain
        }
    }
