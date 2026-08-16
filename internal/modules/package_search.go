package modules

import (
	"bufio"
	"context"
	"fmt"
	"os/exec"
	"sort"
	"strings"
)

// PackageSearch searches the host's OWN repositories for installable packages.
//
// It is the one verb the package snap-in was missing. `package` installs/removes and
// `package_facts` lists what is installed; nothing could answer "what could I install?". Without
// it a package browser has to fall back on a server-side catalogue, and a catalogue cannot know
// what a particular host can actually reach: configs/package_universe_real.json lists 8555 Debian
// packages but only 349 RedHat ones, and it knows nothing about a host's extra repositories.
// Asking the host is both more correct and family-agnostic for free.
//
// READ-ONLY BY CONSTRUCTION. Writes() is false, so a read-only host answers searches normally —
// a package browser that goes blind the moment the write gate is closed would be useless exactly
// where browsing is safest. Every backend command below is a query: apt-cache/dnf/zypper search
// mutate nothing, and no cache update is triggered (a search must not go to the network and must
// not take the dpkg/rpm lock).
type PackageSearch struct {
	LookPath func(string) (string, error)
	Runner   CommandRunner
}

// NewPackageSearch returns a PackageSearch backed by the real exec.LookPath and command runner.
func NewPackageSearch() *PackageSearch {
	return &PackageSearch{LookPath: exec.LookPath, Runner: defaultCommandRunner}
}

func (p *PackageSearch) Name() string { return "package_search" }

func (p *PackageSearch) Description() string {
	return "" +
		"Search THIS host's configured repositories for installable packages — the read side of " +
		"the package manager, answering \"what could I install?\" as `package_facts` answers " +
		"\"what is installed?\". Family-agnostic: apt-cache (Debian/Ubuntu), dnf/dnf5/yum " +
		"(RHEL family), zypper (SUSE), checked in that order. Returns {name, summary} per match, " +
		"capped by `limit` (default 50) with `truncated` saying whether more exist — a search box " +
		"must not stream thousands of rows.\n\n" +
		"Read-only: it issues query commands only, never refreshes the package cache and never " +
		"takes the package-manager lock, so it also works on a write-gated host.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: no core equivalent (package_facts covers installed only).\n" +
		"- Shell: apt-cache search / dnf search / zypper search."
}

func (p *PackageSearch) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"query": stringProp("Substring to search for, matched against package names and summaries."),
		"limit": map[string]any{
			"type": "integer",
			"description": "Maximum matches to return (default 50, max 500). `truncated` in the " +
				"result says whether the repositories held more.",
		},
		"names_only": boolProp(
			"Match only package NAMES, not summaries. Default false. A UI search box wants the "+
				"broad match; a name resolver wants this.", false),
	}, "query")
}

// Writes reports false: this module only queries. See the type comment — a read-only host must
// still be searchable.
func (p *PackageSearch) Writes() bool { return false }

func (p *PackageSearch) Run(ctx context.Context, params map[string]any, _ bool) (Result, error) {
	query, _ := params["query"].(string)
	query = strings.TrimSpace(query)
	if query == "" {
		return Result{}, fmt.Errorf("package_search: query is required")
	}
	limit, err := intParam(params, "limit", 50)
	if err != nil {
		return Result{}, fmt.Errorf("package_search: %w", err)
	}
	if limit <= 0 {
		limit = 50
	}
	if limit > 500 {
		limit = 500
	}
	namesOnly, err := boolParam(params, "names_only", false)
	if err != nil {
		return Result{}, fmt.Errorf("package_search: %w", err)
	}

	backend, args, parse, err := p.pickBackend(query)
	if err != nil {
		return Result{}, err
	}
	out, runErr := p.Runner(ctx, backend, args...)
	if runErr != nil {
		// A search that matches nothing exits non-zero on dnf and zypper. That is an EMPTY RESULT,
		// not a failure — reporting it as an error would make "no such package" look like a broken
		// host, and the UI could not tell the two apart.
		if len(strings.TrimSpace(string(out))) == 0 {
			return searchResult(backend, query, nil, limit), nil
		}
	}

	matches := parse(string(out))
	if namesOnly {
		needle := strings.ToLower(query)
		kept := matches[:0]
		for _, m := range matches {
			if strings.Contains(strings.ToLower(m.Name), needle) {
				kept = append(kept, m)
			}
		}
		matches = kept
	}
	rankMatches(matches, query)
	return searchResult(backend, query, matches, limit), nil
}

// rankMatches orders results by how well they answer the query, best first.
//
// Plain alphabetical order is wrong for a search box, and measurably so: searching a real host for
// "nginx" with limit=5 returned anonip, centreon-plugins, collectd-core, crowdsec and
// diaspora-installer — every one of them a SUMMARY match, with the package actually named nginx
// cut off below. Sorting then truncating buries the exact answer.
//
// So rank by where the query hit, alphabetical only inside a tier (stable, so equally-good matches
// keep a predictable order rather than shifting between calls).
func rankMatches(matches []searchMatch, query string) {
	q := strings.ToLower(strings.TrimSpace(query))
	tier := func(m searchMatch) int {
		name := strings.ToLower(m.Name)
		switch {
		case name == q:
			return 0 // exactly what was typed
		case strings.HasPrefix(name, q):
			return 1 // nginx → nginx-common, nginx-full
		case strings.Contains(name, q):
			return 2 // libnginx-mod-*
		default:
			return 3 // only the summary mentions it
		}
	}
	sort.SliceStable(matches, func(i, j int) bool {
		ti, tj := tier(matches[i]), tier(matches[j])
		if ti != tj {
			return ti < tj
		}
		return matches[i].Name < matches[j].Name
	})
}

type searchMatch struct {
	Name    string `json:"name"`
	Summary string `json:"summary"`
}

func searchResult(backend, query string, matches []searchMatch, limit int) Result {
	truncated := len(matches) > limit
	if truncated {
		matches = matches[:limit]
	}
	if matches == nil {
		matches = []searchMatch{}
	}
	return Result{
		Changed: false,
		Msg:     fmt.Sprintf("%d match(es) for %q via %s", len(matches), query, backend),
		Data: map[string]any{
			"query": query, "backend": backend, "matches": matches,
			"count": len(matches), "truncated": truncated,
		},
	}
}

// pickBackend returns the first available frontend, its query arguments, and the parser for its
// output format. Same detection order as the `package` module so both agree on which family this
// host is — two verbs disagreeing about the package manager would be the worse bug.
func (p *PackageSearch) pickBackend(query string) (string, []string, func(string) []searchMatch, error) {
	lookPath := p.LookPath
	if lookPath == nil {
		lookPath = exec.LookPath
	}
	for _, c := range []struct {
		binary string
		args   []string
		parse  func(string) []searchMatch
	}{
		// apt-cache, not apt: `apt search` prints a "unstable CLI interface" warning to stderr and
		// paginates differently between releases. apt-cache's output is stable and script-facing.
		{"apt-cache", []string{"search", "--", query}, parseAptCacheSearch},
		{"dnf", []string{"--quiet", "search", "--", query}, parseDnfSearch},
		{"dnf5", []string{"--quiet", "search", "--", query}, parseDnfSearch},
		{"yum", []string{"--quiet", "search", "--", query}, parseDnfSearch},
		{"zypper", []string{"--quiet", "search", "--", query}, parseZypperSearch},
	} {
		if _, err := lookPath(c.binary); err == nil {
			return c.binary, c.args, c.parse, nil
		}
	}
	return "", nil, nil, fmt.Errorf(
		"package_search: no supported package manager found (checked apt-cache, dnf, dnf5, yum, zypper)")
}

// parseAptCacheSearch reads "name - summary" lines.
func parseAptCacheSearch(out string) []searchMatch {
	var matches []searchMatch
	sc := bufio.NewScanner(strings.NewReader(out))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		name, summary, found := strings.Cut(line, " - ")
		if !found {
			name, summary = line, ""
		}
		matches = append(matches, searchMatch{Name: strings.TrimSpace(name), Summary: strings.TrimSpace(summary)})
	}
	return matches
}

// parseDnfSearch reads "name.arch : summary" lines, skipping the "=== Name Exactly Matched ==="
// section headers dnf prints between result groups.
func parseDnfSearch(out string) []searchMatch {
	var matches []searchMatch
	sc := bufio.NewScanner(strings.NewReader(out))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "==") || strings.HasPrefix(line, "Last metadata") {
			continue
		}
		name, summary, found := strings.Cut(line, " : ")
		if !found {
			continue // a continuation line of the previous summary; the first line is enough
		}
		// "httpd.x86_64" → "httpd". The arch is not part of the installable name for our purposes,
		// and keeping it would make the result disagree with what `package` expects.
		if dot := strings.LastIndex(name, "."); dot > 0 {
			name = name[:dot]
		}
		matches = append(matches, searchMatch{Name: strings.TrimSpace(name), Summary: strings.TrimSpace(summary)})
	}
	return matches
}

// parseZypperSearch reads the pipe-delimited table zypper prints, skipping its header and rule.
func parseZypperSearch(out string) []searchMatch {
	var matches []searchMatch
	sc := bufio.NewScanner(strings.NewReader(out))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if !strings.Contains(line, "|") || strings.HasPrefix(strings.TrimSpace(line), "--") {
			continue
		}
		cols := strings.Split(line, "|")
		if len(cols) < 3 {
			continue
		}
		name := strings.TrimSpace(cols[1])
		if name == "" || strings.EqualFold(name, "Name") {
			continue // the header row
		}
		matches = append(matches, searchMatch{Name: name, Summary: strings.TrimSpace(cols[2])})
	}
	return matches
}
