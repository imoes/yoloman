def main(ctx, params):
    msg = params["msg"]
    voice = params.get("voice")

    # Determine available speech executable
    executables = ["say", "espeak", "espeak-ng"]
    executable = None
    for exe in executables:
        res = ctx.run([exe, "--version"], mutates=False)
        if res.rc == 0:
            executable = exe
            break
        # Try fallback: just check binary exists via stat
        if ctx.file_exists("/usr/bin/" + exe) or ctx.file_exists("/usr/local/bin/" + exe):
            executable = exe
            break

    if executable == None:
        fail("Unable to find either say, espeak, or espeak-ng")

    # On non-Darwin, voice parameter is not supported (like original)
    if ctx.facts().get("os_family", "").lower() != "darwin":
        voice = None

    if ctx.check_mode:
        return {"changed": False, "msg": msg}

    cmd = [executable, msg]
    if voice != None:
        cmd.extend(["-v", voice])

    res = ctx.run(cmd, mutates=True)
    if res.rc != 0:
        fail("speech command failed: " + res.stderr)

    return {"changed": True, "msg": msg}
