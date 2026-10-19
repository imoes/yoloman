"""package_e2e_worklist.classify: one route per package, and a directory is never routed as a config file."""

from bossman.services.template_gate import DirectorySet
from bossman.tools.package_e2e_worklist import classify


def test_a_package_whose_only_etc_path_is_a_directory_has_no_config():
    # chkconfig lists /etc/init.d (a symlink in the RPM); the qualify pass gave it an ini codec and the pod failed
    # with "is a directory". A path other paths lie beneath is a directory.
    known = DirectorySet.of(["/etc/init.d/ssh", "/etc/init.d"])
    codecs = {"/etc/init.d": {"codec": "ini", "packages": ["chkconfig"]}}
    row = classify("redhat", "chkconfig", {"config_paths": ["/etc/init.d"]}, {}, codecs, {}, known)
    assert row["route"] == "no-config" and "directory" in row["reason"]


def test_a_real_file_beside_the_directory_keeps_its_route():
    known = DirectorySet.of(["/etc/init.d/ssh", "/etc/thing.conf"])
    codecs = {"/etc/thing.conf": {"codec": "keyvalue", "separator": "=", "comment": "#", "packages": ["thing"]}}
    row = classify("redhat", "thing", {"config_paths": ["/etc/init.d", "/etc/thing.conf"]}, {}, codecs, {}, known)
    assert row["route"] == "rule-codec" and row["path"] == "/etc/thing.conf"


def test_a_package_the_repository_replaces_is_routed_to_its_replacement():
    # dnf install hirte installs bluechi-controller (Obsoletes: hirte < 0.6.0): hirte's own file is on no host.
    replaced = {"hirte": {"by": "bluechi-controller", "evr": "0.4.0-1.el9", "obsoletes": "hirte < 0.6.0"}}
    codecs = {"/etc/hirte/hirte.conf": {"codec": "ini", "packages": ["hirte"]}}
    row = classify("redhat", "hirte", {"config_paths": ["/etc/hirte/hirte.conf"]}, {}, codecs, {}, (), replaced)
    assert row["route"] == "replaced" and row["by"] == "bluechi-controller" and "Obsoletes" in row["reason"]
