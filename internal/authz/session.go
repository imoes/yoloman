package authz

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"sync"
	"time"
)

// session is one logged-in identity with an expiry.
type session struct {
	identity Identity
	expires  time.Time
}

// SessionStore holds server-side sessions created after a successful PAM
// login, keyed by an opaque token handed to the client (as a cookie or
// header) and resolved back to an Identity on each subsequent request.
type SessionStore struct {
	mu       sync.Mutex
	sessions map[string]session
	ttl      time.Duration
	now      func() time.Time
}

// NewSessionStore returns a SessionStore whose sessions expire after ttl.
func NewSessionStore(ttl time.Duration) *SessionStore {
	return &SessionStore{
		sessions: map[string]session{},
		ttl:      ttl,
		now:      time.Now,
	}
}

// Create starts a new session for identity and returns its token.
func (s *SessionStore) Create(identity Identity) (string, error) {
	token, err := randomToken()
	if err != nil {
		return "", fmt.Errorf("generating session token: %w", err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sessions[token] = session{identity: identity, expires: s.now().Add(s.ttl)}
	return token, nil
}

// Resolve returns the Identity for token, if it exists and has not expired.
func (s *SessionStore) Resolve(token string) (Identity, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.sessions[token]
	if !ok {
		return Identity{}, false
	}
	if s.now().After(sess.expires) {
		delete(s.sessions, token)
		return Identity{}, false
	}
	return sess.identity, true
}

// Revoke ends the session for token, if any.
func (s *SessionStore) Revoke(token string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.sessions, token)
}

func randomToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}
