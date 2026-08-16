package modules

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
)

// package_search is the read side of the package manager: `package` installs/removes,
// `package_facts` lists what IS installed, this answers what COULD be. The tests pin the two
// things a search box depends on — that each family's output shape is parsed into the same
// {name, summary}, and that "no match" is an empty result rather than an error.

func searchWith(t *testing.T, have string, out string, runErr error, params map[string]any) Result {
	t.Helper()
	m := &PackageSearch{
		LookPath: func(bin string) (string, error) {
			if bin == have {
				return "/usr/bin/" + bin, nil
			}
			return "", errors.New("not found")
		},
		Runner: func(_ context.Context, _ string, _ ...string) ([]byte, error) {
			return []byte(out), runErr
		},
	}
	res, err := m.Run(context.Background(), params, false)
	if err != nil {
		t.Fatalf("package_search: %v", err)
	}
	return res
}

func matchNames(t *testing.T, res Result) []string {
	t.Helper()
	raw := res.Data.(map[string]any)["matches"].([]searchMatch)
	names := make([]string, 0, len(raw))
	for _, m := range raw {
		names = append(names, m.Name)
	}
	return names
}

func TestPackageSearchParsesAptCache(t *testing.T) {
	out := "apache2 - Apache HTTP Server\n" +
		"apache2-bin - Apache HTTP Server (modules and other binary files)\n" +
		"libapache2-mod-php - server-side, HTML-embedded scripting language\n"
	res := searchWith(t, "apt-cache", out, nil, map[string]any{"query": "apache"})
	names := matchNames(t, res)
	if len(names) != 3 || names[0] != "apache2" {
		t.Fatalf("apt-cache output not parsed: %v", names)
	}
	first := res.Data.(map[string]any)["matches"].([]searchMatch)[0]
	if first.Summary != "Apache HTTP Server" {
		t.Fatalf("summary lost: %q", first.Summary)
	}
	if res.Data.(map[string]any)["backend"] != "apt-cache" {
		t.Fatal("the backend must be reported — the caller needs to know which family answered")
	}
}

func TestPackageSearchParsesDnfAndDropsTheArch(t *testing.T) {
	// The arch suffix is not part of the installable name, and keeping it would make the result
	// disagree with what the `package` module expects to be handed back.
	out := "=========== Name Exactly Matched: httpd ===========\n" +
		"httpd.x86_64 : Apache HTTP Server\n" +
		"httpd-tools.x86_64 : Tools for use with the Apache HTTP Server\n"
	names := matchNames(t, searchWith(t, "dnf", out, nil, map[string]any{"query": "httpd"}))
	if len(names) != 2 || names[0] != "httpd" || names[1] != "httpd-tools" {
		t.Fatalf("dnf output not parsed / arch not stripped: %v", names)
	}
}

func TestPackageSearchParsesZypper(t *testing.T) {
	out := "S | Name    | Summary                | Type\n" +
		"--+---------+------------------------+--------\n" +
		"  | apache2 | The Apache Web Server  | package\n"
	res := searchWith(t, "zypper", out, nil, map[string]any{"query": "apache"})
	names := matchNames(t, res)
	if len(names) != 1 || names[0] != "apache2" {
		t.Fatalf("zypper table not parsed (header/rule must be skipped): %v", names)
	}
}

func TestPackageSearchNoMatchIsEmptyNotAnError(t *testing.T) {
	// dnf and zypper exit non-zero when nothing matches. Surfacing that as an error would make
	// "no such package" indistinguishable from "this host is broken".
	res := searchWith(t, "dnf", "", errors.New("exit status 1"), map[string]any{"query": "nosuchthing"})
	if res.Data.(map[string]any)["count"].(int) != 0 {
		t.Fatal("expected an empty result")
	}
	if res.Changed {
		t.Fatal("a search must never report a change")
	}
}

func TestPackageSearchCapsAndSaysSo(t *testing.T) {
	// A search box must not be handed thousands of rows, and it must be able to tell the user that
	// what it shows is not everything.
	var out string
	for i := 0; i < 120; i++ {
		out += fmt.Sprintf("pkg%03d - summary\n", i)
	}
	res := searchWith(t, "apt-cache", out, nil, map[string]any{"query": "pkg", "limit": 10})
	d := res.Data.(map[string]any)
	if d["count"].(int) != 10 {
		t.Fatalf("limit ignored: %v", d["count"])
	}
	if d["truncated"] != true {
		t.Fatal("truncation must be reported, not silent")
	}
}

func TestPackageSearchNamesOnlyExcludesSummaryMatches(t *testing.T) {
	out := "apache2 - Apache HTTP Server\n" +
		"libapache2-mod-php - scripting language\n" +
		"nginx - a web server, an alternative to apache\n"
	names := matchNames(t, searchWith(t, "apt-cache", out, nil,
		map[string]any{"query": "apache", "names_only": true}))
	for _, n := range names {
		if n == "nginx" {
			t.Fatal("names_only still matched on the summary")
		}
	}
	if len(names) != 2 {
		t.Fatalf("expected the two name matches, got %v", names)
	}
}

func TestPackageSearchIsReadOnly(t *testing.T) {
	// Load-bearing: the write gate consults Writes(). A package browser that goes blind on a
	// read-only host would be useless exactly where browsing is safest.
	if NewPackageSearch().Writes() {
		t.Fatal("package_search must not be classified as a write")
	}
}

func TestPackageSearchNeedsAQuery(t *testing.T) {
	_, err := NewPackageSearch().Run(context.Background(), map[string]any{"query": "  "}, false)
	if err == nil {
		t.Fatal("a blank query must be refused, not answered with the whole repository")
	}
}

func TestPackageSearchWithoutAnyPackageManagerSaysWhatItLookedFor(t *testing.T) {
	m := &PackageSearch{LookPath: func(string) (string, error) { return "", errors.New("nope") }}
	_, err := m.Run(context.Background(), map[string]any{"query": "x"}, false)
	if err == nil {
		t.Fatal("expected an error when no frontend exists")
	}
	// The message names what was checked, so an operator on an unusual distro can see immediately
	// which frontend to add rather than being told only that it "failed".
	for _, want := range []string{"apt-cache", "dnf", "zypper"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error does not say it looked for %s: %v", want, err)
		}
	}
}

func TestPackageSearchPutsTheExactNameFirst(t *testing.T) {
	// The defect this guards, measured on a real host: searching "nginx" with limit=5 returned
	// anonip, centreon-plugins, collectd-core, crowdsec and diaspora-installer — five summary
	// matches, with the package literally named nginx cut off below. Alphabetical order plus a cap
	// buries the answer, which is exactly what a search box must not do.
	out := "anonip - Anonymize IP-addresses in log-files\n" +
		"crowdsec - lightweight security engine, works with nginx\n" +
		"libnginx-mod-http-geoip - GeoIP module\n" +
		"nginx-common - small, powerful, scalable web/proxy server - common files\n" +
		"nginx - small, powerful, scalable web/proxy server\n"
	names := matchNames(t, searchWith(t, "apt-cache", out, nil,
		map[string]any{"query": "nginx", "limit": 3}))
	want := []string{"nginx", "nginx-common", "libnginx-mod-http-geoip"}
	for i, w := range want {
		if names[i] != w {
			t.Fatalf("rank %d: want %s, got %v", i, w, names)
		}
	}
}

func TestPackageSearchRankingIsStableWithinATier(t *testing.T) {
	// Equally good matches must keep a predictable order, or the list reshuffles under the cursor
	// between keystrokes.
	out := "nginx-full - full\nnginx-core - core\nnginx-light - light\n"
	first := matchNames(t, searchWith(t, "apt-cache", out, nil, map[string]any{"query": "nginx"}))
	second := matchNames(t, searchWith(t, "apt-cache", out, nil, map[string]any{"query": "nginx"}))
	if fmt.Sprint(first) != fmt.Sprint(second) {
		t.Fatalf("order not stable: %v vs %v", first, second)
	}
	if first[0] != "nginx-core" {
		t.Fatalf("within a tier the order should be alphabetical, got %v", first)
	}
}
