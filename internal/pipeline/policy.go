// Package pipeline runs whitelisted argv stages chained together natively
// in Go (stdout of stage N piped to stdin of stage N+1) — the equivalent of
// a shell pipeline, but with no shell interpreter, no redirects, no
// substitution, and every stage's binary and arguments checked against a
// configured policy first.
package pipeline

import (
	"fmt"
	"os"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

// AllowedCommand describes one binary permitted to appear as a pipeline
// stage, and any argument patterns forbidden for it.
type AllowedCommand struct {
	Binary         string   `yaml:"binary"`
	ForbidPatterns []string `yaml:"forbid_patterns"`
}

// Policy is the set of binaries permitted in pipeline stages, loaded from
// commands.yaml.
type Policy struct {
	Allow []AllowedCommand `yaml:"allow"`
}

// LoadPolicy reads and parses a commands.yaml-style policy file, eagerly
// validating that every forbid pattern compiles as a regular expression.
func LoadPolicy(path string) (*Policy, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading command policy %q: %w", path, err)
	}
	var p Policy
	if err := yaml.Unmarshal(data, &p); err != nil {
		return nil, fmt.Errorf("parsing command policy %q: %w", path, err)
	}
	for _, ac := range p.Allow {
		for _, pat := range ac.ForbidPatterns {
			if _, err := regexp.Compile(pat); err != nil {
				return nil, fmt.Errorf("command policy %q: invalid forbid_pattern %q for %q: %w", path, pat, ac.Binary, err)
			}
		}
	}
	return &p, nil
}

// EmptyPolicy returns a policy that allows nothing — the safe default when
// no commands.yaml is configured.
func EmptyPolicy() *Policy { return &Policy{} }

// Validate checks one pipeline stage (argv, stage[0] is the binary) against
// the policy: the binary must be explicitly allowed, and its arguments must
// not match any of that binary's forbidden patterns.
func (p *Policy) Validate(stage []string) error {
	if len(stage) == 0 {
		return fmt.Errorf("empty pipeline stage")
	}
	binary := stage[0]

	var allowed *AllowedCommand
	for i := range p.Allow {
		if p.Allow[i].Binary == binary {
			allowed = &p.Allow[i]
			break
		}
	}
	if allowed == nil {
		return fmt.Errorf("command %q is not in the allowed command list", binary)
	}

	argStr := strings.Join(stage[1:], " ")
	for _, pat := range allowed.ForbidPatterns {
		re := regexp.MustCompile(pat) // already validated in LoadPolicy
		if re.MatchString(argStr) {
			return fmt.Errorf("arguments to %q match forbidden pattern %q", binary, pat)
		}
	}
	return nil
}
