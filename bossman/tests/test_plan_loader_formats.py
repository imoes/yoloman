"""JSON as a first-class plan format + multi-format load_plans_dir (docs/zielbestimmung.md roadmap 2).

YAML is the human format; JSON is the canonical internal form on disk. (A NestedText format was a third
option here and is gone.)
"""

import json

import pytest

from bossman.services.plan_loader import PLAN_FILE_SUFFIXES, PlanError, load_plan_file, load_plans_dir, parse_plan_json

PLAN = {
    "name": "jdemo",
    "steps": [{"name": "s1", "file": {"path": "/etc/x", "state": "directory"}}],
}


def test_parse_plan_json_ok():
    plan = parse_plan_json(json.dumps(PLAN), __import__("pathlib").Path("jdemo.json"))
    assert plan.name == "jdemo"
    assert plan.chunks[0].steps[0].module == "file"


def test_parse_plan_json_rejects_bad():
    from pathlib import Path

    with pytest.raises(PlanError, match="invalid JSON"):
        parse_plan_json("{not json", Path("x.json"))
    with pytest.raises(PlanError, match="must be a JSON object"):
        parse_plan_json("[1,2,3]", Path("x.json"))


_YAML = "name: {n}\nsteps:\n  - name: s\n    file:\n      path: /x\n      state: directory\n"


def test_load_plan_file_dispatches_by_extension(tmp_path):
    j = tmp_path / "a.json"
    j.write_text(json.dumps(PLAN))
    assert load_plan_file(j).name == "jdemo"
    y = tmp_path / "c.yaml"
    y.write_text(_YAML.format(n="ydemo"))
    assert load_plan_file(y).name == "ydemo"


def test_load_plans_dir_picks_up_all_formats(tmp_path):
    assert set(PLAN_FILE_SUFFIXES) == {".yaml", ".yml", ".json"}
    (tmp_path / "a.json").write_text(json.dumps(PLAN))
    (tmp_path / "b.yaml").write_text(_YAML.format(n="yy"))
    (tmp_path / "c.yml").write_text(_YAML.format(n="cc"))
    (tmp_path / "ignored.txt").write_text("not a plan")
    names = sorted(p.name for p in load_plans_dir(tmp_path))
    assert names == ["cc", "jdemo", "yy"]
