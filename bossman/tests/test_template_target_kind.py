"""A file existing is not the same as a file being a SETTING.

The path measurement answers "does the package ship something here". `/etc/cron.daily/logrotate` exists, is
measured `file`, and is a program that run-parts executes — and the Configure write path is WHOLE FILE, so
offering it means replacing a working script with a rendered template. Measured on the bindings the editor
offered: 27 of them.

The line this draws is deliberately narrow, and the exclusions matter as much as the refusals: a rule that
refused `.php` would remove the correct binding for /etc/phpmyadmin/config.inc.php, which really is how
phpMyAdmin is configured.
"""

import pytest

from bossman.services.template_index import unsuitable_target


@pytest.mark.parametrize("path, marker", [
    # run-parts directories: membership is by DIRECTORY, because that is what makes it certain. A file in
    # /etc/cron.daily is a program by contract, whatever it is called.
    ("/etc/cron.daily/logrotate", "run-parts"),
    ("/etc/cron.hourly/anything", "run-parts"),
    ("/etc/init.d/apparmor", "run-parts"),
    ("/etc/rc2.d/S01foo", "run-parts"),
    ("/etc/X11/Xsession.d/90xbrlapi", "run-parts"),
    ("/etc/network/if-up.d/ucarp", "run-parts"),
    ("/etc/kernel/postinst.d/dracut", "run-parts"),
    ("/etc/dhcp/dhclient-exit-hooks.d/ddclient", "run-parts"),
    ("/etc/apm/event.d/gpm", "run-parts"),
    ("/etc/NetworkManager/dispatcher.d/01-ifupdown", "run-parts"),
    # documentation and data tables
    ("/etc/apparmor.d/local/README", "documentation"),
    ("/etc/apticron/README", "documentation"),
    ("/etc/arp-scan/mac-vendor.txt", "documentation"),
    ("/etc/foo/CHANGELOG.md", "documentation"),
    # source code, kept narrow on purpose
    ("/etc/jabber-querybot/Querymodule.pm", "source code"),
])
def test_a_non_setting_is_refused_with_its_reason(path, marker):
    why = unsuitable_target(path)
    assert why, f"{path} was offered as an editable config file"
    assert marker in why
    # A refusal has to say what would go wrong, not merely that it is refused.
    assert "whole-file" in why or "whole file" in why or "render" in why


@pytest.mark.parametrize("path", [
    # /etc/cron.d holds crontab FRAGMENTS — schedule plus command — which are configuration. The difference
    # from /etc/cron.daily (scripts) is the whole point of doing this by directory.
    "/etc/cron.d/anacron",
    "/etc/cron.d/amavisd-new",
    # Real config grammars that happen to live in a *.d directory.
    "/etc/logrotate.d/swift",
    "/etc/apparmor.d/usr.bin.surf",
    "/etc/apt/apt.conf.d/50appstream",
    # CONFIG WRITTEN IN A PROGRAMMING LANGUAGE. Refusing an extension here would remove correct bindings to
    # win an argument about file names: these three ARE how the applications are configured.
    "/etc/phpmyadmin/config.inc.php",
    "/etc/prosody/prosody.cfg.lua",
    "/etc/mediawiki/LocalSettings.php",
    # ordinary config files
    "/etc/nginx/nginx.conf",
    "/etc/default/grub",
    "/etc/ssh/sshd_config",
])
def test_a_real_config_file_is_not_refused(path):
    assert unsuitable_target(path) is None, f"{path} would lose its editor"


def test_the_two_questions_are_separate():
    """A path can EXIST and still not be a setting. If this collapsed into the verdict check, the case that
    motivated the rule — /etc/cron.daily/logrotate, measured `file` — would pass straight through."""
    assert unsuitable_target("/etc/cron.daily/logrotate")          # exists, and is a program
    assert unsuitable_target("/etc/nginx/nginx.conf") is None      # exists, and is a setting
