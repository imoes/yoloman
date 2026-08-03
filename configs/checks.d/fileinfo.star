def fnmatch_translate(pattern):
    res = ""
    i = 0
    n = len(pattern)
    while i < n:
        c = pattern[i]
        if c == "*":
            res = res + ".*"
        elif c == "?":
            res = res + "."
        elif c in [".", "+", "(", ")", "|", "^", "$", "[", "]"]:
            res = res + "\\" + c
        else:
            res = res + c
        i = i + 1
    return res

def fnmatch_name(name, pattern):
    if pattern == "*" or pattern == "":
        return True
    pat = fnmatch_translate(pattern)
    # anchored full match
    return _regex_fullmatch(name, pat)

def _regex_fullmatch(s, pat):
    # simple: build .* + pat + .*
    return _regex_match(s, pat)

def _regex_match(s, pat):
    # naive: only supports .* , . , literal chars
    # We use a simple DP-free approach: implement basic regex
    return _match_here(s, 0, pat, 0)

def _match_here(s, si, pat, pi):
    while pi < len(pat):
        c = pat[pi]
        if c == ".":
            if si >= len(s):
                return False
            si = si + 1
            pi = pi + 1
        elif c == "\\":
            pi = pi + 1
            if pi >= len(pat):
                return False
            if si >= len(s) or s[si] != pat[pi]:
                return False
            si = si + 1
            pi = pi + 1
        elif pi + 1 < len(pat) and pat[pi+1] == "*":
            # .* 
            # match zero or more of c
            # but for .* we skip
            if c == ".":
                # .*
                pi = pi + 2
                # try to match rest at each position
                while si <= len(s):
                    if _match_here(s, si, pat, pi):
                        return True
                    si = si + 1
                return False
            else:
                # char*
                pi = pi + 2
                while si <= len(s):
                    if _match_here(s, si, pat, pi):
                        return True
                    if si >= len(s) or s[si] != c:
                        break
                    si = si + 1
                return False
        else:
            if si >= len(s) or s[si] != c:
                return False
            si = si + 1
            pi = pi + 1
    return si == len(s)

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["df", "-PkT"], mutates=False)
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
    return {"changed": False, "msg": "", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}