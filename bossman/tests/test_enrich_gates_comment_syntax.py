from bossman.tools.enrich_gates import gate_comment_syntax

LUA = "-- dnsdist configuration file\n-- second line\nsetSecurityPollSuffix(\"{{ s }}\")\n"


def test_hash_comments_added_to_a_lua_file_are_refused():
    enriched = LUA + "# Disables security status polling\nnewServer(\"{{ x }}\")\n"
    problems = gate_comment_syntax(LUA, enriched)
    assert problems and "'--'" in problems[0]


def test_files_that_already_use_hash_and_native_markers_pass():
    conf = "# a\n# b\nkey = {{ v }}\n"
    assert gate_comment_syntax(conf, conf + "# added\n") == []
    assert gate_comment_syntax(LUA, LUA + "-- added\n") == []
    assert gate_comment_syntax("", "# x\n") == []
