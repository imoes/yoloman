"""The exporters of a diagnosis (plan B9) over the golden documents. The Ansible output must pass ansible-lint
(run for real when it is installed); nothing an exporter cannot express may vanish — it is named."""

import copy
import json
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

from bossman.services import diagnosis_export as X

EXAMPLES = Path(__file__).resolve().parents[2] / "configs/schemas/diagnosis.examples"


def golden(name: str) -> dict:
    return json.loads((EXAMPLES / f"{name}.json").read_text())


def with_acl_remedy() -> dict:
    d = golden("windows-logon-right")
    d["findings"][0]["remedy"] = {
        "action": "grant", "target": {"kind": "file_acl", "id": r"C:\probe\ProbeService.exe", "attribute": r".\probeuser"},
        "before": {"sddl": "D:(D;;0x1200a9;;;S-1-5-21-1-2-3-1004)(A;;FA;;;SY)"},
        "after": {"grant": "execute+read", "to": r".\probeuser"},
        "rollback": {"action": "set", "value": {"sddl": "D:(D;;0x1200a9;;;S-1-5-21-1-2-3-1004)(A;;FA;;;SY)"}},
        "verify": {"rule_absent": "svc.access_denied", "expect": {"status": "running"}}}
    return d


def linux_with_remedies() -> dict:
    d = golden("linux-203-exec")
    f = d["findings"][0]
    f2 = copy.deepcopy(f)
    f["rule_id"], f["remedy"] = "svc.disabled", {
        "action": "set", "target": {"kind": "systemd_unit", "id": "probe-exec.service", "attribute": "masked"},
        "before": True, "after": False, "rollback": {"action": "set", "value": True},
        "verify": {"rule_absent": "svc.disabled", "expect": {"load_state": "loaded"}}}
    f2["rule_id"], f2["remedy"] = "svc.account_missing", {
        "action": "create", "target": {"kind": "service_account", "id": "probesvc", "attribute": None},
        "before": {"exists": False}, "after": {"exists": True}, "rollback": {"action": "delete", "value": "probesvc"},
        "verify": {"rule_absent": "svc.account_missing", "expect": {"status": "running"}}}
    d["findings"].append(f2)
    return d


def test_checkmk_states_follow_the_certainty():
    assert X.checkmk(golden("windows-logon-right"))["content"].splitlines()[1].startswith('2 "Diagnosis yoloman-probe-logon" findings=1 ')
    assert X.checkmk(golden("unknown-gap"))["content"].splitlines()[1].startswith("3 ")
    bad = X.checkmk(golden("linux-203-exec"), ["findings/0: cites evidence that is not in the diagnosis: x"])
    assert bad["content"].splitlines()[1].startswith("3 ") and "does not hold" in bad["content"]
    assert len(X.checkmk(golden("unknown-gap"))["content"].splitlines()) == 2      # one line, no stray newline


def test_gelf_has_one_message_per_finding_and_evidence_joined_by_the_diagnosis_id():
    d = golden("windows-dependency")
    msgs = X.gelf(d)["content"]
    assert len(msgs) == len(d["findings"]) + len(d["evidence"])
    assert {m["_correlation_id"] for m in msgs} == {d["diagnosis_id"]}
    assert all(m["version"] == "1.1" and m["short_message"] and isinstance(m["timestamp"], float) for m in msgs)
    finding = next(m for m in msgs if m["_kind"] == "finding")
    assert finding["level"] == 3 and "a correlation, not a cause" in finding["full_message"]


def test_dsc_uses_the_native_service_resource_and_names_what_has_none():
    out = X.dsc(golden("windows-dependency"))
    doc = yaml.safe_load(out["apply"])
    assert doc["resources"][0]["type"] == "Microsoft.Windows/Service"
    assert doc["resources"][0]["properties"] == {"name": "yoloman-probe-base", "startType": "Manual"}
    assert yaml.safe_load(out["rollback"])["resources"][0]["properties"]["startType"] == "Disabled"
    right = X.dsc(golden("windows-logon-right"))
    assert right["apply"] is None and "no native resource for user_right" in right["not_expressible"][0]


def test_powershell_removes_the_deny_entry_before_allowing_and_rolls_back_to_the_measured_sddl():
    out = X.powershell(with_acl_remedy())
    assert out["apply"].index("RemoveAccessRuleSpecific") < out["apply"].index("AddAccessRule")
    assert "SetSecurityDescriptorSddlForm('D:(D;;0x1200a9;;;S-1-5-21-1-2-3-1004)(A;;FA;;;SY)')" in out["rollback"]
    assert X.powershell(golden("linux-203-exec"))["apply"] is None


def test_a_remedy_kind_without_an_exporter_is_named_not_dropped():
    d = golden("windows-dependency")
    d["findings"][0]["remedy"]["target"]["kind"] = "account_state"   # a kind no exporter maps yet
    for fmt in ("ansible", "powershell", "dsc"):
        out = X.export(d, fmt)
        assert out["apply"] is None and any("account_state" in m for m in out["not_expressible"]), fmt


def test_a_diagnosis_without_remedies_says_so():
    assert "nothing to export" in X.export(golden("unknown-gap"), "ansible")["note"]


@pytest.mark.parametrize("doc", [golden("windows-logon-right"), golden("windows-dependency"), with_acl_remedy(),
                                 linux_with_remedies()], ids=["user-right", "start-type", "acl", "linux"])
def test_the_ansible_export_passes_ansible_lint(doc, tmp_path):
    out = X.ansible(doc)
    assert out["apply"] and out["rollback"] and out["not_expressible"] == []
    if shutil.which("ansible-lint") is None:
        pytest.skip("ansible-lint is not installed here")
    for part in ("apply", "rollback"):
        f = tmp_path / f"{part}.yml"
        f.write_text(out[part])
        r = subprocess.run(["ansible-lint", "--offline", "--nocolor", str(f)], capture_output=True, text=True,
                           cwd=tmp_path, timeout=300)
        assert r.returncode == 0, r.stdout + r.stderr


def update_doc_with_snapshot_remedy() -> dict:
    """A Linux update diagnosis whose upd.behind carries a snapshot-rollback remedy (plan U4)."""
    return {
        "schema": "yoloman.diagnosis/v1", "diagnosis_id": "u1", "host": "deb01", "platform": "linux",
        "target": {"kind": "updates", "name": "deb01", "display_name": None},
        "collected_at": "2026-10-19T10:00:00Z", "status": "behind",
        "summary": "deb01 is behind on updates: 3 upgradable.",
        "evidence": [{"id": "upd:state:deb01", "source": "apt", "observed": None, "fact": "apt reports 3 upgradable.", "raw": {}}],
        "findings": [{
            "rule_id": "upd.behind", "claim": "deb01 is behind on updates: 3 upgradable.", "certainty": "Proven",
            "evidence_ids": ["upd:state:deb01"], "precedent": None, "gap": None,
            "remedy": {
                "action": "install", "target": {"kind": "package", "id": "pending updates", "attribute": None},
                "before": {"snapshot_command": "lvcreate --snapshot --name root-preupdate vg0/root", "volume": "vg0/root", "kind": "lvm"},
                "after": {"installed": "the pending updates", "install_command": "apt-get -y dist-upgrade"},
                "rollback": {"action": "restore", "value": {"snapshot": "root-preupdate", "command": "lvconvert --merge vg0/root-preupdate && reboot"}},
                "verify": {"rule_absent": "upd.behind", "expect": {"status": "up-to-date"}},
            }}],
        "timeline": [], "gaps": [],
    }


def test_update_remedy_ansible_snapshot_install_and_restore():
    out = X.ansible(update_doc_with_snapshot_remedy())
    assert out["not_expressible"] == []
    apply = yaml.safe_load(out["apply"])[0]["tasks"]
    assert len(apply) == 2
    # the snapshot (no shell metachars → command) then the install
    assert "ansible.builtin.command" in apply[0] and "lvcreate --snapshot" in apply[0]["ansible.builtin.command"]["cmd"]
    assert "apt-get -y dist-upgrade" in apply[1]["ansible.builtin.command"]["cmd"]
    assert all(t.get("changed_when") is True for t in apply)
    back = yaml.safe_load(out["rollback"])[0]["tasks"]
    assert len(back) == 1
    # the restore uses && → shell
    assert "ansible.builtin.shell" in back[0] and "lvconvert --merge" in back[0]["ansible.builtin.shell"]["cmd"]


def test_update_remedy_not_expressible_in_dsc_and_powershell():
    doc = update_doc_with_snapshot_remedy()
    assert X.dsc(doc)["apply"] is None and X.dsc(doc)["not_expressible"]
    assert X.powershell(doc)["apply"] is None and X.powershell(doc)["not_expressible"]
