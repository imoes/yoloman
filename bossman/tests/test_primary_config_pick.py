"""Which file out of a .deb becomes the template — the root cause of the destructive templates.

`_pick_primary_config` chooses, from a package's declared conffiles, the one the qualify pipeline
parametrizes into `template.j2`. Everything downstream inherits that choice, and the Configure step
renders the result WHOLE-FILE to the catalog's config_path. Pick the wrong file and Configure
overwrites a live config with an unrelated one.

It picked wrong. The old rule took the FIRST conffile whose basename was in
`{cfg_base, name.conf, name.cfg, name}`, and the bare package name is the trap: openssh-server
ships both /etc/pam.d/sshd and /etc/ssh/sshd_config, "sshd" matches the PAM file, and pam.d sorts
first — so sshd's template WAS the PAM stack, aimed at sshd_config. Applying it locks you out of
the host. Measured: 7 of 90 catalog roles carried a template for a different file than their own
schema describes.
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path("/app/scripts")))
qualify = pytest.importorskip("qualify_packages", reason="qualify scripts not mounted")
pick = qualify._pick_primary_config


def test_pam_file_never_wins_over_the_real_config():
    """The exact case that produced the sshd template. pam.d sorts first and shares the name."""
    conffiles = ["/etc/pam.d/sshd", "/etc/ssh/sshd_config", "/etc/init.d/ssh", "/etc/ssh/ssh_config"]
    assert pick(conffiles, "sshd_config", "sshd", "/etc/ssh/sshd_config") == "/etc/ssh/sshd_config"
    # …and still right when the caller has only the basename, because the name tiers are ranked
    # rather than first-match. Both callers exist, so both are pinned.
    assert pick(conffiles, "sshd_config", "sshd") == "/etc/ssh/sshd_config"


def test_init_script_never_wins():
    """nfs-kernel-server and samba both ship an init script named after the package."""
    nfs = ["/etc/init.d/nfs-kernel-server", "/etc/nfs.conf",
           "/etc/default/nfs-kernel-server", "/etc/exports"]
    assert pick(nfs, "nfs.conf", "nfs-kernel-server", "/etc/nfs.conf") == "/etc/nfs.conf"
    smb = ["/etc/init.d/smbd", "/etc/samba/smb.conf", "/etc/pam.d/samba"]
    assert pick(smb, "smb.conf", "samba", "/etc/samba/smb.conf") == "/etc/samba/smb.conf"


def test_the_catalog_path_outranks_a_same_named_file_elsewhere():
    """When the catalog states the full path, nothing may beat it — not even an exact basename
    match in another directory."""
    conffiles = ["/etc/foo.conf", "/etc/foo/foo.conf"]
    assert pick(conffiles, "foo.conf", "foo", "/etc/foo/foo.conf") == "/etc/foo/foo.conf"


def test_bare_name_still_works_when_it_is_genuinely_the_config():
    """The name-only match is not removed, only kept out of the trap directories — plenty of
    packages really do ship /etc/<name> as their config."""
    assert pick(["/etc/sudoers", "/etc/sudo.conf"], "", "sudo.conf") == "/etc/sudo.conf"
    assert pick(["/etc/logrotate.d/apache2", "/etc/hosts"], "", "hosts") == "/etc/hosts"


def test_fragments_lose_to_a_real_file():
    """conf-available/ and *.d/ fragments are pieces of a config, not the config."""
    conffiles = ["/etc/apache2/conf-available/other.conf", "/etc/apache2/apache2.conf"]
    assert pick(conffiles, "", "apache2") == "/etc/apache2/apache2.conf"


def test_no_conffiles_is_none_not_a_guess():
    assert pick([], "x.conf", "x", "/etc/x.conf") is None
