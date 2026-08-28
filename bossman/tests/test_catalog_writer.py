"""One writer, one format — so a diff on a shared catalog means a change.

`configs/config_codecs.json` and `configs/config_directives.json` are written from ~17 places and they
disagreed on TWO axes: `indent` (2 in the packaged pipeline, 1 in every recording script) and `ensure_ascii`
(True vs False). Both rewrite the whole file, so the groups took turns reformatting 200 000 lines — measured
on the committed files, 1966 `\\uXXXX` escapes that the next script to touch one key would have unescaped.
A one-key change and a reformat then produce the same diff, and a wrong change cannot be spotted.

These tests pin the format itself, not just that writing works: a future writer that "just" uses
json.dumps is what this exists to prevent.
"""

import json

from bossman.tools._jsonio import INDENT, dumps_catalog, write_catalog


def test_the_format_is_two_space_sorted_and_real_utf8():
    text = dumps_catalog({"z": 1, "a": {"note": "Präfix — ‘quoted’"}})
    assert text.startswith('{\n  "a"'), "not sorted, or not indent=2"
    assert text.endswith("}\n"), "no trailing newline — every writer appended one"
    # ensure_ascii=False: these values are man-page prose, and ’ is not readable. A catalog nobody can
    # read is a catalog nobody checks.
    assert "Präfix" in text and "‘quoted’" in text
    assert "\\u" not in text
    assert INDENT == 2


def test_writing_twice_changes_nothing(tmp_path):
    """Idempotence is the whole point: the second writer must not produce a diff."""
    p = tmp_path / "config_codecs.json"
    data = {"/etc/b.conf": {"codec": "ini", "note": "ä"}, "/etc/a.conf": {"codec": "keyvalue"}}
    write_catalog(p, data)
    first = p.read_bytes()
    write_catalog(p, json.loads(p.read_text()))
    assert p.read_bytes() == first


def test_the_file_is_never_visible_half_written(tmp_path, monkeypatch):
    """These files are bind-mounted into a running server and read live, and the readers treat an unparsable
    catalog as an EMPTY one — so a torn read does not raise, it silently withdraws every codec. The write
    goes to a temp file in the SAME directory (os.replace is only atomic within a filesystem) and the
    original must survive a failure mid-write."""
    p = tmp_path / "config_directives.json"
    write_catalog(p, {"/etc/a.conf": {"key": {}}})
    good = p.read_text()

    class Boom:
        def __repr__(self):  # json.dumps raises on an unserialisable value
            return "boom"

    try:
        write_catalog(p, {"/etc/a.conf": Boom()})
    except TypeError:
        pass
    else:
        raise AssertionError("expected the serialisation to fail")
    assert p.read_text() == good, "a failed write damaged the existing catalog"
    leftovers = [f.name for f in tmp_path.iterdir() if f.name != p.name]
    assert not leftovers, f"temp files left behind: {leftovers}"


def test_the_existing_mode_survives_the_write(tmp_path):
    """mkstemp creates 0600 and os.replace() replaces the MODE along with the contents. Writing these
    bind-mounted catalogs from the container (as root) therefore made them root-only 0600 — the host user
    could not even md5sum them, and the batch would have carried on regardless. A shared file one writer can
    silently make private is worse than a torn read, because nothing reports it."""
    import os
    import stat

    p = tmp_path / "config_codecs.json"
    write_catalog(p, {"a": 1})
    os.chmod(p, 0o664)
    write_catalog(p, {"a": 2})
    assert stat.S_IMODE(p.stat().st_mode) == 0o664


def test_a_new_file_is_readable(tmp_path):
    """No prior file to copy from: the fallback must still be group/other-readable, or the first write of a
    new catalog creates one only its author can read."""
    import stat

    p = tmp_path / "brand_new.json"
    write_catalog(p, {"a": 1})
    assert stat.S_IMODE(p.stat().st_mode) & 0o044, "a fresh catalog is not readable by anyone else"


def test_sort_false_keeps_insertion_order(tmp_path):
    """The .state files are written with sort=False — their order carries the pass's progress, and sorting
    them would make every resume look like a rewrite."""
    p = tmp_path / "state.json"
    write_catalog(p, {"z": 1, "a": 2}, sort=False)
    assert list(json.loads(p.read_text())) == ["z", "a"]
