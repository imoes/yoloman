package modules

import (
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// TestManpage_SweepRealPages renders every manual page of the machine it runs on and reports what leaked through the
// renderer: roff escapes, request lines, headings that are not section names. Opt-in (MANPAGE_SWEEP=1): it depends
// on the host's pages, and its job is to find renderer gaps, not to gate a build.
func TestManpage_SweepRealPages(t *testing.T) {
	if os.Getenv("MANPAGE_SWEEP") != "1" {
		t.Skip("set MANPAGE_SWEEP=1 to render every installed manual page")
	}
	m := NewManpage()
	files := m.pages("")
	// roff escapes only: `\n`, `\t` in a C page are text the page documents.
	escape := regexp.MustCompile(`\\(f[A-Z(\[]|s[+-]?\d|\(..|\*|\[[a-z]|[hvwoDNXlLkz]'|c$)`)
	request := regexp.MustCompile(`(?m)^\.[a-zA-Z]{1,3}\b`)
	bad := map[string][]string{}
	for _, f := range files {
		src, err := readSource(f.path)
		if err != nil {
			continue
		}
		text := renderRoff(src)
		if escape.MatchString(text) {
			bad["escape"] = append(bad["escape"], f.name+"("+f.section+"): "+escape.FindString(text))
		}
		if request.MatchString(text) {
			bad["request"] = append(bad["request"], f.name+"("+f.section+"): "+request.FindString(text))
		}
		for _, h := range pageHeadings(text) {
			if len(strings.TrimSpace(h)) <= 2 || strings.ContainsAny(h, "=$%\\") {
				bad["heading"] = append(bad["heading"], f.name+"("+f.section+"): "+h)
				break
			}
		}
		if nameSummary(text) == "" {
			bad["no-summary"] = append(bad["no-summary"], f.name+"("+f.section+")")
		}
	}
	t.Logf("rendered %d pages", len(files))
	kinds := make([]string, 0, len(bad))
	for k := range bad {
		kinds = append(kinds, k)
	}
	sort.Strings(kinds)
	for _, k := range kinds {
		list := bad[k]
		t.Logf("%-10s %5d (%.1f%%) e.g. %v", k, len(list), 100*float64(len(list))/float64(len(files)), list[:min(len(list), 6)])
	}
}
