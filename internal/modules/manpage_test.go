package modules

import (
	"compress/gzip"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeMan(t *testing.T, dir, rel, body string, gz bool) {
	t.Helper()
	p := filepath.Join(dir, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if !gz {
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	f, err := os.Create(p + ".gz")
	if err != nil {
		t.Fatal(err)
	}
	w := gzip.NewWriter(f)
	w.Write([]byte(body))
	w.Close()
	f.Close()
}

const manSshdConfig = `.\" comment
.TH SSHD_CONFIG 5
.SH NAME
sshd_config \- OpenSSH daemon configuration file
.SH DESCRIPTION
.B sshd
reads configuration data from
.I /etc/ssh/sshd_config .
.SH OPTIONS
.TP
.B PermitRootLogin
Specifies whether root can log in using
.BR ssh (1).
The default is
.Cm prohibit-password .
.TP
.B Port
Specifies the port number that
.B sshd
listens on. The default is 22.
.SH FILES
/etc/ssh/sshd_config
`

const mdocCrontab = `.Dd 2024
.Dt CRONTAB 1
.Sh NAME
.Nm crontab
.Nd maintain crontab files for individual users
.Sh SYNOPSIS
.Nm
.Op Fl u Ar user
.Ar file
.Sh DESCRIPTION
The
.Nm
program edits the table of
.Xr cron 8 .
`

func manFixture(t *testing.T) *Manpage {
	dir := t.TempDir()
	writeMan(t, dir, "man5/sshd_config.5", manSshdConfig, true)
	writeMan(t, dir, "man1/crontab.1", mdocCrontab, false)
	writeMan(t, dir, "man1/crontab2.1", ".so man1/crontab.1\n", false)
	writeMan(t, dir, "de/man1/crontab.1", mdocCrontab, false) // a translation: not listed
	return &Manpage{Dirs: []string{dir}}
}

func TestManpage_SearchMatchesNameAndSummary(t *testing.T) {
	m := manFixture(t)
	res, err := m.Run(context.Background(), map[string]any{"query": "openssh daemon"}, false)
	if err != nil {
		t.Fatal(err)
	}
	results := res.Data.(map[string]any)["results"].([]any)
	if len(results) != 1 {
		t.Fatalf("want 1 result, got %v", results)
	}
	r := results[0].(map[string]any)
	if r["page"] != "sshd_config" || r["section"] != "5" || r["summary"] != "OpenSSH daemon configuration file" {
		t.Errorf("unexpected result %v", r)
	}
	if n := res.Data.(map[string]any)["pages_installed"]; n != 3 {
		t.Errorf("translations must not be listed; pages_installed=%v", n)
	}
}

func TestManpage_FullTextFindsADirective(t *testing.T) {
	m := manFixture(t)
	res, _ := m.Run(context.Background(), map[string]any{"query": "permitrootlogin", "full_text": true}, false)
	results := res.Data.(map[string]any)["results"].([]any)
	if len(results) != 1 {
		t.Fatalf("want 1 result, got %v", results)
	}
	if lines := results[0].(map[string]any)["matches"].([]string); !strings.Contains(lines[0], "PermitRootLogin") {
		t.Errorf("matches should quote the line: %v", lines)
	}
}

func TestManpage_ReadHeadingAndGrep(t *testing.T) {
	m := manFixture(t)
	res, _ := m.Run(context.Background(), map[string]any{"page": "sshd_config", "heading": "options"}, false)
	text := res.Data.(map[string]any)["text"].(string)
	if !strings.Contains(text, "PermitRootLogin") || strings.Contains(text, "/etc/ssh/sshd_config\n") && strings.Contains(text, "FILES") {
		t.Errorf("heading should cut to OPTIONS: %q", text)
	}
	if !strings.Contains(text, "ssh(1)") || strings.Contains(text, `\f`) || strings.Contains(text, ".BR") {
		t.Errorf("roff not rendered: %q", text)
	}
	res, _ = m.Run(context.Background(), map[string]any{"page": "sshd_config", "grep": "port number"}, false)
	text = res.Data.(map[string]any)["text"].(string)
	if !strings.Contains(text, "listens on") || strings.Contains(text, "root can log in") || !strings.Contains(text, "[OPTIONS]") {
		t.Errorf("grep should return the Port paragraph with its heading: %q", text)
	}
}

func TestManpage_MdocAndSoRedirect(t *testing.T) {
	m := manFixture(t)
	res, _ := m.Run(context.Background(), map[string]any{"page": "crontab2"}, false)
	text := res.Data.(map[string]any)["text"].(string)
	for _, want := range []string{"NAME", "crontab - maintain crontab files", "[-u user]", "cron(8)"} {
		if !strings.Contains(text, want) {
			t.Errorf("mdoc render lacks %q: %q", want, text)
		}
	}
}

func TestManpage_NoPagesIsNamed(t *testing.T) {
	m := &Manpage{Dirs: []string{t.TempDir()}}
	res, err := m.Run(context.Background(), map[string]any{"query": "ssh"}, false)
	if err != nil {
		t.Fatal(err)
	}
	if note, _ := res.Data.(map[string]any)["note"].(string); !strings.HasPrefix(note, "no manual pages are installed") {
		t.Errorf("missing pages must be named, got %v", res.Data)
	}
	res, _ = manFixture(t).Run(context.Background(), map[string]any{"page": "nosuch"}, false)
	if note, _ := res.Data.(map[string]any)["note"].(string); !strings.Contains(note, "no page \"nosuch\"") {
		t.Errorf("an absent page must be named, got %v", res.Data)
	}
}

func TestManpage_LiteralBlocksKeepTheirLinesAndDefinitionsComeFirst(t *testing.T) {
	dir := t.TempDir()
	writeMan(t, dir, "man5/crontab.5", `.TH CRONTAB 5
.SH NAME
crontab \- tables for driving cron
.SH DESCRIPTION
A line mentions MAILTO in passing.
.TP
.B MAILTO
Where output is mailed.
.SH EXAMPLE CRON FILE
.nf
MAILTO=paul
5 0 * * *  $HOME/bin/daily.job
.fi
`, false)
	m := &Manpage{Dirs: []string{dir}}
	res, _ := m.Run(context.Background(), map[string]any{"page": "crontab", "heading": "example cron file"}, false)
	if text := res.Data.(map[string]any)["text"].(string); !strings.Contains(text, "MAILTO=paul\n    5 0 * * *") {
		t.Errorf("a literal block must keep its line breaks: %q", text)
	}
	if h := res.Data.(map[string]any)["headings"].([]string); len(h) != 3 {
		t.Errorf("only .SH lines are headings: %v", h)
	}
	res, _ = m.Run(context.Background(), map[string]any{"page": "crontab", "grep": "mailto"}, false)
	if text := res.Data.(map[string]any)["text"].(string); !strings.HasPrefix(text, "[DESCRIPTION]\n  MAILTO") {
		t.Errorf("the defining paragraph must come first: %q", text)
	}
}

// asciidoctor pages (chrony.conf) open with macro definitions and a groff-only \{ block, and use `.fam C` inside
// examples; none of it is text. And a name search ranks whole words above substrings.
func TestManpage_AsciidoctorSetupIsNotTextAndRankingPrefersWords(t *testing.T) {
	dir := t.TempDir()
	writeMan(t, dir, "man5/chrony.conf.5", `.TH "CHRONY.CONF" "5"
.ie \n(.g .ds Aq \(aq
.de URL
\fI\\$2\fP <\\$1>\\$3
..
.if \n[.g] \{\
.  mso www.tmac
.  LINKSTYLE blue R < >
.\}
.SH "NAME"
chrony.conf \- chronyd configuration file
.SH "EXAMPLES"
.nf
.fam C
makestep 1.0 3
.fam
.fi
`, false)
	writeMan(t, dir, "man3/grantpt.3", ".TH GRANTPT 3\n.SH NAME\ngrantpt \\- grant access to the slave pseudoterminal\n", false)
	writeMan(t, dir, "man8/ntpd.8", ".TH NTPD 8\n.SH NAME\nntpd \\- NTP daemon program\n", false)
	m := &Manpage{Dirs: []string{dir}}
	res, _ := m.Run(context.Background(), map[string]any{"page": "chrony.conf"}, false)
	d := res.Data.(map[string]any)
	if h := d["headings"].([]string); len(h) != 2 {
		t.Errorf("only NAME and EXAMPLES are headings, got %v", h)
	}
	if text := d["text"].(string); strings.Contains(text, "LINKSTYLE") || strings.Contains(text, "$2") || !strings.Contains(text, "    makestep 1.0 3") {
		t.Errorf("setup must not render as text: %q", text)
	}
	res, _ = m.Run(context.Background(), map[string]any{"query": "ntp"}, false)
	first := res.Data.(map[string]any)["results"].([]any)[0].(map[string]any)["page"]
	if first != "ntpd" {
		t.Errorf("ntpd must rank above grantpt, got %v first", first)
	}
}

// pages_installed is the host's count whatever the section filter; the filtered count is pages_in_section, and an
// empty section does not claim the host has no pages.
func TestManpage_PagesInstalledIsTheHostCount(t *testing.T) {
	root := t.TempDir()
	writeMan(t, root, "man5/foo.5", ".TH FOO 5\n.SH NAME\nfoo \\- a file\n", false)
	writeMan(t, root, "man8/food.8", ".TH FOOD 8\n.SH NAME\nfood \\- a daemon\n", false)
	m := &Manpage{Dirs: []string{root}}
	res, err := m.Run(context.Background(), map[string]any{"page": "foo", "section": "5"}, false)
	if err != nil {
		t.Fatal(err)
	}
	d := res.Data.(map[string]any)
	if d["pages_installed"] != 2 || d["pages_in_section"] != 1 {
		t.Errorf("pages_installed=%v pages_in_section=%v, want 2 and 1", d["pages_installed"], d["pages_in_section"])
	}
	res, _ = m.Run(context.Background(), map[string]any{"query": "foo", "section": "3"}, false)
	d = res.Data.(map[string]any)
	if note, _ := d["note"].(string); !strings.Contains(note, "section") || strings.Contains(note, "no manual pages are installed") {
		t.Errorf("empty section note = %q", note)
	}
}
