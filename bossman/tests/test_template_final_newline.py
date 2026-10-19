from bossman.tools.template_invariants import ensure_final_newline


def _tdir(tmp_path, body, schema="{}"):
    (tmp_path / "template.j2").write_text(body)
    (tmp_path / "schema.json").write_text(schema)
    return tmp_path


def test_a_template_ending_without_lf_gets_one(tmp_path):
    d = _tdir(tmp_path, "# comment\nkey = {{ v | default(1) }}")
    assert ensure_final_newline(d) and (d / "template.j2").read_text().endswith("}}\n")


def test_a_closing_tag_after_a_full_line_is_left_alone(tmp_path):
    d = _tdir(tmp_path, "{% if true %}key = 1\n{% endif %}")
    assert not ensure_final_newline(d)


def test_a_template_that_already_ends_with_lf_is_unchanged(tmp_path):
    assert not ensure_final_newline(_tdir(tmp_path, "a = 1\n"))


def test_an_empty_default_does_not_activate_a_setting_the_shipped_file_comments():
    """snapserver: `threads = {{ threads | default('') }}` wrote `threads = ` and the daemon refused to start."""
    from bossman.tools.activate_commented_settings import guard_empty_activations
    body = "threads = {{ threads | default('') }}\nDNS={{ dns | default('') }}\nport = {{ port | default(1704) }}\n"
    shipped = "#threads = -1\nDNS=\n#port = 1704\n"
    out, n = guard_empty_activations(body, shipped)
    assert n == 2                                           # threads and port: both only commented in the shipped file
    assert "{% else %}#port = 1704{% endif %}" in out
    assert out.startswith("{% if threads is defined and threads is not none and threads != '' %}threads = {{ threads }}"
                          "{% else %}#threads = -1{% endif %}")
    assert "DNS={{ dns | default('') }}" in out          # the shipped file writes it empty itself
