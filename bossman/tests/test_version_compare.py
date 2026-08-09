"""Tests for the dpkg / rpm version comparators used in CVE correlation."""

from bossman.services.version_compare import dpkg_compare, rpm_evr_compare


def test_dpkg_basic_ordering():
    assert dpkg_compare("1.0", "2.0") == -1
    assert dpkg_compare("2.0", "1.0") == 1
    assert dpkg_compare("1.0", "1.0") == 0


def test_dpkg_epoch():
    # An epoch dominates the upstream version.
    assert dpkg_compare("1:0.1", "2.0") == 1
    assert dpkg_compare("2.0", "1:0.1") == -1


def test_dpkg_revision_and_debrev():
    assert dpkg_compare("1.2.3-1", "1.2.3-2") == -1
    assert dpkg_compare("2.31-13+deb11u5", "2.31-13+deb11u6") == -1
    assert dpkg_compare("13.8+deb13u5", "13.8+deb13u6") == -1


def test_dpkg_tilde_sorts_before():
    # ~ pre-releases sort *before* the release.
    assert dpkg_compare("1.0~rc1", "1.0") == -1
    assert dpkg_compare("1.0~beta", "1.0~rc1") == -1


def test_dpkg_numeric_vs_length():
    assert dpkg_compare("1.10", "1.9") == 1  # numeric, not lexical
    assert dpkg_compare("1.0.0", "1.0") == 1


def test_rpm_basic_and_release():
    assert rpm_evr_compare("1.0-1", "1.0-2") == -1
    assert rpm_evr_compare("1.2-3.el9", "1.2-4.el9") == -1
    assert rpm_evr_compare("1.0-1", "1.0-1") == 0


def test_rpm_epoch():
    assert rpm_evr_compare("1:1.0-1", "2.0-1") == 1


def test_rpm_numeric_outranks_alpha():
    # A numeric segment is newer than an alphabetic one at the same position.
    assert rpm_evr_compare("1.0.1", "1.0.a") == 1


def test_rpm_tilde_and_caret():
    assert rpm_evr_compare("1.0~rc1", "1.0") == -1  # tilde is a pre-release
    assert rpm_evr_compare("1.0^post", "1.0") == 1  # caret is a post-release


def test_rpm_numeric_length():
    assert rpm_evr_compare("1.10", "1.9") == 1
