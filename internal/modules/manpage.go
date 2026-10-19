package modules

import (
	"bufio"
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
)

// Manpage searches and reads the manual pages installed on the host — the documentation of exactly the versions
// that run there. For an agentic OS this is the most valuable reference there is: with it even a small model can
// look up which option, directive or file does what, instead of guessing from training data written for another
// release. Pure Go: the roff/mdoc sources are read from the man directories (gzip included) and rendered to plain
// text natively, so it works on hosts without man-db or groff (most containers).
type Manpage struct {
	// Dirs overrides the man directories (tests). Empty: $MANPATH, else the standard locations.
	Dirs []string
}

// NewManpage returns a Manpage module.
func NewManpage() *Manpage { return &Manpage{} }

func (m *Manpage) Name() string { return "manpage" }

func (m *Manpage) Description() string {
	return "" +
		"Search and read the manual pages installed on this host (the documentation of the versions that actually " +
		"run here). Read-only.\n\n" +
		"How to use it, in two steps:\n" +
		"1. SEARCH: `query` with a few keywords (e.g. \"ssh daemon\", \"crontab\", \"nftables\") matches page names " +
		"and their one-line NAME summaries, like apropos. Add `full_text: true` to search inside the pages too " +
		"(slower; returns the matching lines) — use it for an option or directive name (\"PermitRootLogin\", " +
		"\"max_connections\").\n" +
		"2. READ: `page` (+ optional `section`, e.g. \"5\" for file formats, \"8\" for daemons/admin commands, " +
		"\"1\" for user commands) returns the page as plain text. Narrow it with `heading` (e.g. \"OPTIONS\", " +
		"\"FILES\", \"EXAMPLES\") or `grep` (a word; only the paragraphs containing it), and `max_chars`.\n\n" +
		"If the host has no manual pages installed (common in container images, which exclude /usr/share/man), " +
		"the result says so in `note` instead of returning an empty list.\n\n" +
		"Cross-tool equivalents: `apropos`/`man -k` (search), `man -K` (full text), `man <section> <page>` (read)."
}

func (m *Manpage) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"query":     stringProp(`Search words (all must match, case-insensitive), e.g. "ssh daemon". Searches page names and NAME summaries.`),
		"full_text": boolProp(`Also search inside the pages and return matching lines (slower).`, false),
		"page":      stringProp(`A page to read, e.g. "sshd_config". Takes precedence over query.`),
		"section":   stringProp(`Manual section to restrict to, e.g. "5" (file formats) or "8" (administration).`),
		"heading":   stringProp(`When reading: return only this section of the page, e.g. "OPTIONS".`),
		"grep":      stringProp(`When reading: return only the paragraphs containing this word.`),
		"max_chars": intProp(`When reading: cut the text at this many characters (default 12000).`),
		"limit":     intProp(`When searching: at most this many results (default 20).`),
	})
}

func (m *Manpage) Writes() bool { return false }

func (m *Manpage) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	query, _ := stringParam(params, "query", false, "")
	page, _ := stringParam(params, "page", false, "")
	section, _ := stringParam(params, "section", false, "")
	heading, _ := stringParam(params, "heading", false, "")
	grep, _ := stringParam(params, "grep", false, "")
	fullText, _ := boolParam(params, "full_text", false)
	maxChars, _ := intParam(params, "max_chars", 12000)
	limit, _ := intParam(params, "limit", 20)
	if page == "" && strings.TrimSpace(query) == "" {
		return Result{}, fmt.Errorf("manpage: give `query` to search or `page` to read")
	}
	// pages_installed is always the HOST's count. It was the count after the section filter, so the same host
	// reported 1370 pages for a search and 135 for a read of sshd_config(5) — one name, two meanings. The
	// filtered count has its own name.
	files := m.pages(section)
	installed := len(files)
	if section != "" {
		installed = len(m.pages(""))
	}
	data := map[string]any{"pages_installed": installed}
	if section != "" {
		data["pages_in_section"] = len(files)
	}
	if len(files) == 0 {
		data["note"] = noManpagesNote()
		if installed > 0 {
			data["note"] = fmt.Sprintf("no manual pages in section %q on this host (%d pages in other sections)", section, installed)
		}
		if page != "" {
			data["page"] = page
		} else {
			data["results"] = []any{}
		}
		return Result{Data: data}, nil
	}
	if page != "" {
		return m.read(files, page, section, heading, grep, maxChars, data)
	}
	return m.search(ctx, files, query, fullText, limit, data)
}

// manFile is one page source: /usr/share/man/man5/sshd_config.5.gz → name sshd_config, section 5.
type manFile struct {
	path, name, section string
}

var manName = regexp.MustCompile(`^(.+)\.([0-9][a-z0-9]*)(\.gz)?$`)

func (m *Manpage) dirs() []string {
	if len(m.Dirs) > 0 {
		return m.Dirs
	}
	if mp := os.Getenv("MANPATH"); mp != "" {
		return strings.Split(mp, ":")
	}
	return []string{"/usr/share/man", "/usr/local/share/man", "/usr/local/man"}
}

// pages lists the English page sources (man<N>/ directly under each man dir; translations live in <lang>/man<N>).
func (m *Manpage) pages(section string) []manFile {
	var out []manFile
	for _, dir := range m.dirs() {
		subs, _ := filepath.Glob(filepath.Join(dir, "man*"))
		for _, sub := range subs {
			entries, err := os.ReadDir(sub)
			if err != nil {
				continue
			}
			for _, e := range entries {
				mm := manName.FindStringSubmatch(e.Name())
				if mm == nil || e.IsDir() {
					continue
				}
				if section != "" && !strings.HasPrefix(mm[2], section) {
					continue
				}
				out = append(out, manFile{path: filepath.Join(sub, e.Name()), name: mm[1], section: mm[2]})
			}
		}
	}
	return out
}

func noManpagesNote() string {
	note := "no manual pages are installed on this host"
	if _, err := os.Stat("/etc/dpkg/dpkg.cfg.d/docker"); err == nil {
		note += " — this looks like a Debian container image, which excludes /usr/share/man (see /etc/dpkg/dpkg.cfg.d/docker)"
	} else if _, err := os.Stat("/etc/dpkg/dpkg.cfg.d/excludes"); err == nil {
		note += " — dpkg excludes them (/etc/dpkg/dpkg.cfg.d/excludes)"
	} else if b, err := os.ReadFile("/etc/dnf/dnf.conf"); err == nil && strings.Contains(string(b), "tsflags=nodocs") {
		note += " — dnf installs packages without documentation (tsflags=nodocs in /etc/dnf/dnf.conf)"
	}
	return note
}

// readSource returns the roff source, following a `.so man5/x.5` redirection once.
func readSource(path string) (string, error) {
	text, err := readMaybeGzip(path)
	if err != nil {
		return "", err
	}
	if first := strings.TrimSpace(strings.SplitN(text, "\n", 2)[0]); strings.HasPrefix(first, ".so ") {
		target := strings.TrimSpace(strings.TrimPrefix(first, ".so "))
		root := filepath.Dir(filepath.Dir(path))
		for _, cand := range []string{filepath.Join(root, target), filepath.Join(root, target+".gz")} {
			if t, err := readMaybeGzip(cand); err == nil {
				return t, nil
			}
		}
	}
	return text, nil
}

func readMaybeGzip(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	var r io.Reader = f
	if strings.HasSuffix(path, ".gz") {
		gz, err := gzip.NewReader(f)
		if err != nil {
			return "", err
		}
		defer gz.Close()
		r = gz
	}
	b, err := io.ReadAll(io.LimitReader(r, 8<<20))
	return string(b), err
}

func (m *Manpage) search(ctx context.Context, files []manFile, query string, fullText bool, limit int, data map[string]any) (Result, error) {
	words := strings.Fields(strings.ToLower(query))
	type hit struct {
		f        manFile
		summary  string
		score    int
		snippets []string
	}
	var (
		hits []hit
		mu   sync.Mutex
		wg   sync.WaitGroup
	)
	work := make(chan manFile)
	// One page at a time is I/O and gunzip bound; 8400 pages took 8 s in full text on one core.
	for w := 0; w < runtime.NumCPU(); w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for f := range work {
				if h, ok := scorePage(f, words, fullText); ok {
					mu.Lock()
					hits = append(hits, hit{h.f, h.summary, h.score, h.snippets})
					mu.Unlock()
				}
			}
		}()
	}
	for _, f := range files {
		if ctx.Err() != nil {
			break
		}
		work <- f
	}
	close(work)
	wg.Wait()
	sort.SliceStable(hits, func(i, j int) bool {
		if hits[i].score != hits[j].score {
			return hits[i].score > hits[j].score
		}
		return hits[i].f.name < hits[j].f.name
	})
	if limit <= 0 {
		limit = 20
	}
	results := []any{}
	for i, h := range hits {
		if i == limit {
			break
		}
		r := map[string]any{"page": h.f.name, "section": h.f.section, "summary": h.summary, "path": h.f.path}
		if len(h.snippets) > 0 {
			r["matches"] = h.snippets
		}
		results = append(results, r)
	}
	data["query"], data["full_text"], data["results"], data["total_matches"] = query, fullText, results, len(hits)
	if len(hits) == 0 {
		data["note"] = "no page matches all of the words; try fewer or other words, or full_text=true"
	}
	return Result{Data: data}, nil
}

func (m *Manpage) read(files []manFile, page, section, heading, grep string, maxChars int, data map[string]any) (Result, error) {
	var chosen *manFile
	for i := range files {
		if files[i].name == page && (section == "" || strings.HasPrefix(files[i].section, section)) {
			if chosen == nil || files[i].section < chosen.section {
				chosen = &files[i]
			}
		}
	}
	data["page"] = page
	if chosen == nil {
		var near []string
		for _, f := range files {
			if strings.Contains(strings.ToLower(f.name), strings.ToLower(page)) {
				near = append(near, f.name+"("+f.section+")")
				if len(near) == 10 {
					break
				}
			}
		}
		data["note"] = fmt.Sprintf("no page %q%s is installed on this host", page, map[bool]string{true: " in section " + section, false: ""}[section != ""])
		data["similar"] = near
		return Result{Data: data}, nil
	}
	src, err := readSource(chosen.path)
	if err != nil {
		return Result{}, fmt.Errorf("manpage: read %s: %w", chosen.path, err)
	}
	text := renderRoff(src)
	headings := pageHeadings(text)
	if heading != "" {
		text = sectionOf(text, heading)
		if text == "" {
			data["note"] = fmt.Sprintf("the page has no section %q; its sections are listed in `headings`", heading)
		}
	}
	if grep != "" {
		text = paragraphsWith(text, grep)
		if text == "" {
			data["note"] = fmt.Sprintf("no paragraph of the page mentions %q", grep)
		}
	}
	if maxChars <= 0 {
		maxChars = 12000
	}
	text = plain(text)
	truncated := len(text) > maxChars
	if truncated {
		text = text[:maxChars]
	}
	data["section"], data["path"], data["text"], data["truncated"], data["headings"] = chosen.section, chosen.path, text, truncated, headings
	return Result{Data: data}, nil
}

type pageHit struct {
	f        manFile
	summary  string
	score    int
	snippets []string
}

// scorePage reads one page and scores it against the search words (0 = no match).
func scorePage(f manFile, words []string, fullText bool) (pageHit, bool) {
	src, err := readSource(f.path)
	if err != nil {
		return pageHit{}, false
	}
	if !fullText {
		src = untilSecondHeading(src) // NAME is all a name search reads
	}
	text := renderRoff(src)
	summary := nameSummary(text)
	hay := strings.ToLower(f.name + " " + summary)
	score := 0
	if containsAll(hay, words) {
		// Whole words and name prefixes before substrings: "ntp" must rank ntpd and "NTP daemon" above grantpt.
		lname := strings.ToLower(f.name)
		score = 100
		for _, w := range words {
			switch {
			case lname == w:
				score += 1000
			case strings.HasPrefix(lname, w):
				score += 400
			case wordIn(hay, w):
				score += 200
			}
		}
		if lname == strings.Join(words, " ") || lname == strings.Join(words, "_") {
			score += 1000
		}
	}
	var snippets []string
	if fullText {
		low := strings.ToLower(text)
		if containsAll(low, words) {
			for _, line := range strings.Split(text, "\n") {
				if containsAny(strings.ToLower(line), words) {
					snippets = append(snippets, strings.TrimSpace(plain(line)))
					if len(snippets) == 3 {
						break
					}
				}
			}
			if score == 0 {
				score = 10 + strings.Count(low, words[0])
			}
		}
	}
	if score > 0 {
		return pageHit{f, summary, score, snippets}, true
	}
	return pageHit{}, false
}

// untilSecondHeading cuts a roff source after its NAME section (the first heading's body).
func untilSecondHeading(src string) string {
	seen := 0
	for i := 0; i < len(src); {
		j := strings.IndexByte(src[i:], '\n')
		line := src[i:]
		if j >= 0 {
			line = src[i : i+j]
		}
		if strings.HasPrefix(line, ".SH") || strings.HasPrefix(line, ".Sh") {
			seen++
			if seen == 2 {
				return src[:i]
			}
		}
		if j < 0 {
			break
		}
		i += j + 1
	}
	return src
}

// wordIn: w occurs in s as a whole word (bounded by non-letters/digits).
func wordIn(s, w string) bool {
	for i := strings.Index(s, w); i >= 0; {
		before := i == 0 || !isWordByte(s[i-1])
		end := i + len(w)
		after := end == len(s) || !isWordByte(s[end])
		if before && after {
			return true
		}
		next := strings.Index(s[i+1:], w)
		if next < 0 {
			break
		}
		i += next + 1
	}
	return false
}

func isWordByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

func containsAll(s string, words []string) bool {
	for _, w := range words {
		if !strings.Contains(s, w) {
			return false
		}
	}
	return len(words) > 0
}

func containsAny(s string, words []string) bool {
	for _, w := range words {
		if strings.Contains(s, w) {
			return true
		}
	}
	return false
}

// nameSummary is the NAME section's one line, after the dash: "sshd_config - OpenSSH daemon configuration file".
func nameSummary(text string) string {
	body := sectionOf(text, "NAME")
	line := strings.Join(strings.Fields(body), " ")
	if i := strings.Index(line, " - "); i >= 0 {
		return strings.TrimSpace(line[i+3:])
	}
	return line
}

// pageHeadings lists the top-level headings of a rendered page (lines in capitals at column 0).
func pageHeadings(text string) []string {
	var out []string
	for _, l := range strings.Split(text, "\n") {
		if isHeading(l) {
			out = append(out, plain(l))
		}
	}
	return out
}

// headingMark starts every line the renderer wrote for .SH/.Sh. A heading is what the PAGE declared, not a guess
// from the text: ffmpeg writes bold labels like "DV" alone at column 0, and `ARGV[2] = "A"` is content. Stripped
// from everything handed out (plain()).
const headingMark = "\x01"

func isHeading(l string) bool { return strings.HasPrefix(l, headingMark) }

// plain removes the heading marks for output.
func plain(s string) string { return strings.ReplaceAll(s, headingMark, "") }

// sectionOf returns one top-level section of a rendered page (its body, without the heading), matched
// case-insensitively; empty when absent.
func sectionOf(text, heading string) string {
	want := strings.ToUpper(strings.TrimSpace(heading))
	var b strings.Builder
	in := false
	for _, l := range strings.Split(text, "\n") {
		if isHeading(l) {
			if in {
				break
			}
			in = strings.TrimSpace(plain(l)) == want
			continue
		}
		if in {
			b.WriteString(l + "\n")
		}
	}
	return strings.TrimSpace(b.String())
}

// paragraphsWith keeps the blank-line-separated paragraphs containing word (case-insensitive), each with the heading
// it sits under, so a hit on a directive comes with its explanation.
func paragraphsWith(text, word string) string {
	w := strings.ToLower(word)
	var out, defs []string
	current := ""
	for _, para := range strings.Split(text, "\n\n") {
		first := strings.SplitN(strings.TrimLeft(para, "\n"), "\n", 2)[0]
		if isHeading(first) {
			current = plain(first)
		}
		if strings.Contains(strings.ToLower(para), w) {
			p := "[" + current + "]\n" + strings.Trim(para, "\n")
			// The paragraph that DEFINES the word (a tagged item starting with it) comes first: for a directive
			// that is its explanation, where a mention in a list of keywords is noise.
			if strings.HasPrefix(strings.ToLower(strings.TrimSpace(para)), w) {
				defs = append(defs, p)
			} else {
				out = append(out, p)
			}
		}
	}
	return strings.Join(append(defs, out...), "\n\n")
}

// ---- roff / mdoc → plain text ---------------------------------------------------------------------------------------

var (
	fontEsc  = regexp.MustCompile(`\\f(\[[^\]]*\]|\(..|.)`)
	sizeEsc  = regexp.MustCompile(`\\s[+-]?\d+`)
	namedEsc = regexp.MustCompile(`\\(\(..|\[[^\]]*\])`)
	strEsc   = regexp.MustCompile(`\\\*(\(..|\[[^\]]*\]|.)`)
)

var namedChars = map[string]string{
	"em": "—", "en": "–", "hy": "-", "aq": "'", "dq": "\"", "lq": "\"", "rq": "\"", "oq": "'", "cq": "'", "bu": "•",
	"co": "©", "rg": "®", "tm": "™", "mu": "×", "de": "°", "ti": "~", "ha": "^", "ba": "|", "rs": "\\", "sl": "/",
	"Lq": "\"", "Rq": "\"", "ga": "`", "dg": "†", "->": "→", "<-": "←", "<=": "≤", ">=": "≥", "!=": "≠",
}

// motionEsc: escapes with a quoted argument that produce no text (\h'…' motion, \w'…' width, \o'…' overstrike, …)
// and \k<x> (mark), \z<c> (zero width): removed — they leaked as "\w" into 1 in 5 pages.
var motionEsc = regexp.MustCompile(`\\[hvwoDNXlLSZbx]'[^']*'|\\k.|\\z`)

// inline strips roff escapes from one line of text.
func inline(s string) string {
	s = motionEsc.ReplaceAllString(s, "")
	s = fontEsc.ReplaceAllString(s, "")
	s = sizeEsc.ReplaceAllString(s, "")
	s = strEsc.ReplaceAllStringFunc(s, func(m string) string {
		name := strings.Trim(m[2:], "([]")
		if v, ok := namedChars[name]; ok {
			return v
		}
		return ""
	})
	s = namedEsc.ReplaceAllStringFunc(s, func(m string) string {
		name := strings.Trim(m[1:], "([]")
		if v, ok := namedChars[name]; ok {
			return v
		}
		return ""
	})
	r := strings.NewReplacer(`\-`, "-", `\e`, `\`, `\&`, "", `\ `, " ", `\~`, " ", `\|`, "", `\^`, "", `\c`, "",
		`\0`, " ", `\(`, "", `\%`, "", `\:`, "", `\/`, "", `\,`, "")
	return r.Replace(s)
}

// macroArgs splits a macro line's arguments, honouring double quotes.
func macroArgs(s string) []string {
	var out []string
	var cur strings.Builder
	inQ := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' && inQ && i+1 < len(s) && s[i+1] == '"':
			cur.WriteByte('"')
			i++
		case c == '"':
			inQ = !inQ
		case (c == ' ' || c == '\t') && !inQ:
			if cur.Len() > 0 {
				out = append(out, cur.String())
				cur.Reset()
			}
		default:
			cur.WriteByte(c)
		}
	}
	if cur.Len() > 0 {
		out = append(out, cur.String())
	}
	return out
}

// mdocInline is filled in init(): its entries call mdocLine, which reads the map (an initialization cycle otherwise).
var mdocInline map[string]func(args []string, name string) string

func init() {
	mdocInline = map[string]func(args []string, name string) string{
		"Fl": func(a []string, _ string) string { return mdocJoin(a, "-") },
		"Nm": func(a []string, name string) string {
			if len(a) == 0 {
				return name
			}
			return strings.Join(a, " ")
		},
		"Xr": func(a []string, _ string) string {
			if len(a) >= 2 {
				return a[0] + "(" + a[1] + ")" + strings.Join(a[2:], "")
			}
			return strings.Join(a, " ")
		},
		"Op":  func(a []string, n string) string { return "[" + mdocLine(a, n) + "]" },
		"Oo":  func(a []string, n string) string { return "[" + mdocLine(a, n) },
		"Oc":  func(a []string, n string) string { return "]" + mdocLine(a, n) },
		"Dq":  func(a []string, n string) string { return "\"" + mdocLine(a, n) + "\"" },
		"Qq":  func(a []string, n string) string { return "\"" + mdocLine(a, n) + "\"" },
		"Sq":  func(a []string, n string) string { return "'" + mdocLine(a, n) + "'" },
		"Pq":  func(a []string, n string) string { return "(" + mdocLine(a, n) + ")" },
		"Brq": func(a []string, n string) string { return "{" + mdocLine(a, n) + "}" },
		"Aq":  func(a []string, n string) string { return "<" + mdocLine(a, n) + ">" },
		"Ns":  func(a []string, n string) string { return "\x00" + mdocLine(a, n) },
	}
}

// mdocJoin prefixes the words up to the next macro name (`Fl u Ar user` → "-u" + "user"); the rest is rendered as an
// mdoc line of its own.
func mdocJoin(a []string, prefix string) string {
	var parts []string
	for i, x := range a {
		if _, macro := mdocInline[x]; macro || isMdocWord(x) {
			return strings.TrimSpace(strings.Join(parts, " ") + " " + mdocLine(a[i:], ""))
		}
		if len(x) == 1 && strings.ContainsAny(x, ".,;:)]") {
			parts = append(parts, x)
			continue
		}
		parts = append(parts, prefix+x)
	}
	return strings.Join(parts, " ")
}

// mdocLine renders the arguments of an mdoc line, where macro names may appear inline ("Fl v Ar file").
func mdocLine(a []string, name string) string {
	var parts []string
	for i := 0; i < len(a); i++ {
		if f, ok := mdocInline[a[i]]; ok {
			parts = append(parts, f(a[i+1:], name))
			break
		}
		if isMdocWord(a[i]) {
			continue
		}
		parts = append(parts, a[i])
	}
	joined := strings.ReplaceAll(strings.Join(parts, " "), " \x00", "")
	return closingPunct.ReplaceAllString(joined, "$1")
}

// closingPunct: mdoc passes punctuation as separate words (`Cm AcceptEnv ,`); it attaches to the word before.
var closingPunct = regexp.MustCompile(` ([.,;:)\]])`)

func isMdocWord(s string) bool {
	switch s {
	case "Ar", "Cm", "Pa", "Dv", "Ev", "Em", "Sy", "Li", "Ql", "Va", "Ic", "Fn", "Fa", "Ft", "Er", "Tn", "Ux", "Bx",
		"No", "Ad", "Lk", "Mt", "Ms", "Sx", "Vt", "Cd", "At":
		return true
	}
	return false
}

// renderRoff renders man(7) and mdoc(7) sources to plain text: headings at column 0 in capitals, paragraphs separated
// by blank lines, tagged items indented. Good enough for a model to read; not a typesetter.
func renderRoff(src string) string {
	var b strings.Builder
	name := ""
	para := func() {
		if !strings.HasSuffix(b.String(), "\n\n") {
			if !strings.HasSuffix(b.String(), "\n") {
				b.WriteString("\n")
			}
			b.WriteString("\n")
		}
	}
	text := func(s string) {
		s = strings.TrimSpace(inline(s))
		if s == "" {
			return
		}
		cur := b.String()
		if cur != "" && !strings.HasSuffix(cur, "\n") && !strings.HasSuffix(cur, " ") {
			b.WriteString(" ")
		}
		b.WriteString(s)
	}
	newline := func() {
		if !strings.HasSuffix(b.String(), "\n") {
			b.WriteString("\n")
		}
	}
	sc := bufio.NewScanner(strings.NewReader(src))
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	tagNext := false
	literal := false // inside .nf/.EX/.Bd -literal: lines keep their breaks (config examples, crontab lines)
	skipDef := false // inside `.de NAME` … `..`: a macro's definition, not text
	skipPic := false // inside `.PS` … `.PE`: a pic(1) drawing
	mdoc := false    // set by .Dd/.Dt
	braceDepth := 0  // inside `.if … \{` … `\}`: groff-only setup blocks (asciidoctor pages open with one)
	for sc.Scan() {
		line := sc.Text()
		if skipDef {
			if strings.HasPrefix(line, "..") {
				skipDef = false
			}
			continue
		}
		if skipPic {
			if strings.HasPrefix(line, ".PE") {
				skipPic = false
			}
			continue
		}
		if braceDepth > 0 {
			braceDepth += strings.Count(line, `\{`) - strings.Count(line, `\}`)
			continue
		}
		if strings.HasPrefix(line, `.\"`) || strings.HasPrefix(line, `'\"`) || line == "." {
			continue
		}
		if (strings.HasPrefix(line, ".if") || strings.HasPrefix(line, ".ie") || strings.HasPrefix(line, ".el")) &&
			strings.Contains(line, `\{`) {
			braceDepth = strings.Count(line, `\{`) - strings.Count(line, `\}`)
			continue
		}
		if strings.HasPrefix(line, ".de ") || strings.HasPrefix(line, ".am ") || strings.HasPrefix(line, ".de1 ") {
			skipDef = true
			continue
		}
		if literal && !strings.HasPrefix(line, ".") && !strings.HasPrefix(line, "'") {
			newline()
			b.WriteString("    " + strings.TrimRight(inline(line), " ") + "\n")
			continue
		}
		if !strings.HasPrefix(line, ".") && !strings.HasPrefix(line, "'") {
			if tagNext {
				text(line)
				newline()
				b.WriteString("    ")
				tagNext = false
				continue
			}
			text(line)
			continue
		}
		fields := strings.SplitN(strings.TrimLeft(line[1:], " \t"), " ", 2)
		macro := fields[0]
		rest := ""
		if len(fields) > 1 {
			rest = fields[1]
		}
		args := macroArgs(rest)
		switch macro {
		case "nf", "EX", "Vb": // .Vb: pod2man's verbatim block (ffmpeg, perl pages)
			newline()
			literal = true
			continue
		case "PS": // a pic(1) picture: drawing commands, not text
			skipPic = true
			continue
		case "fi", "EE", "Ve":
			literal = false
			newline()
			continue
		case "Bd":
			if strings.Contains(rest, "-literal") || strings.Contains(rest, "-unfilled") {
				newline()
				literal = true
			}
			continue
		case "Ed":
			literal = false
			newline()
			continue
		}
		switch macro {
		case "Dd", "Dt":
			mdoc = true // an mdoc(7) page: .Sh is its section heading
		case "Sh":
			para()
			if !mdoc { // pod2man defines its own .Sh (a subsection) on man(7) pages — ffmpeg's "DV" was a heading
				b.WriteString("  " + strings.TrimSpace(inline(strings.Join(args, " "))) + "\n")
				break
			}
			b.WriteString(headingMark + strings.ToUpper(strings.TrimSpace(inline(strings.Join(args, " ")))) + "\n")
		case "SH":
			para()
			b.WriteString(headingMark + strings.ToUpper(strings.TrimSpace(inline(strings.Join(args, " ")))) + "\n")
		case "SS", "Ss":
			para()
			b.WriteString("  " + strings.TrimSpace(inline(strings.Join(args, " "))) + "\n")
		case "PP", "P", "LP", "Pp", "sp":
			para()
		case "br":
			newline()
		case "TP":
			para()
			b.WriteString("  ")
			tagNext = true
		case "HP": // hanging paragraph: its argument is an indent (`\w'…'u`), not a tag
			para()
		case "IP":
			para()
			if len(args) > 0 && strings.TrimSpace(args[0]) != "" {
				b.WriteString("  ")
				text(args[0])
				newline()
				b.WriteString("    ")
			}
		case "It":
			para()
			b.WriteString("  ")
			text(mdocLine(args, name))
			newline()
			b.WriteString("    ")
		case "B", "I", "SM", "SB":
			text(strings.Join(args, " "))
		case "BR", "RB", "BI", "IB", "IR", "RI":
			text(strings.Join(args, ""))
		case "Nm":
			if name == "" && len(args) > 0 {
				name = args[0]
			}
			text(mdocInline["Nm"](args, name))
		case "Nd":
			text("- " + strings.Join(args, " "))
		case "TH", "Os", "nf", "fi", "in", "ad", "na", "nh", "hy", "ne", "ft", "ps", "ta", "ll", "RS",
			"RE", "Bl", "El", "Bd", "Ed", "Rs", "Re", "de", "ds", "nr", "if", "ie", "el", "so", "UR", "UE", "MT", "ME",
			"tr", "cs", "ss", "PD", "TS", "TE", "EQ", "EN", "Sm", "Lb", "In", "Ex", "Rv":
			// layout only (or tables/equations, whose cells still arrive as text lines)
		default:
			if f, ok := mdocInline[macro]; ok {
				text(f(args, name))
			} else if macro != "" && macro == strings.ToLower(macro) {
				// A lowercase request (.fam C, .ss, .als, .mso, .ce …) is layout: its arguments are never text.
				// Rendered, `.fam C` inside chrony.conf's examples made dozens of headings called "C".
			} else {
				text(mdocLine(args, name))
			}
		}
	}
	out := regexp.MustCompile(`\n{3,}`).ReplaceAllString(b.String(), "\n\n")
	return strings.TrimSpace(out) + "\n"
}
