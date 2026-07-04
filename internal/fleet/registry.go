package fleet

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"

	"github.com/mutkluge/agentic-mcp/internal/config"
)

const registrySchemaSQL = `
CREATE TABLE IF NOT EXISTS satellites (
	name TEXT PRIMARY KEY,
	address TEXT NOT NULL,
	token TEXT NOT NULL,
	poll_interval_ns INTEGER NOT NULL DEFAULT 60000000000,
	created_at INTEGER NOT NULL
);
`

// SatelliteRegistry is the durable, dynamic counterpart to config.yaml's
// static proxy.satellites list — satellites enrolled at runtime (via this
// agent's own POST /api/v1/enroll, when acting as a Selecta) or removed
// via DELETE /api/v1/proxy/satellites/{name}, persisted so the list
// survives a restart. Its own SQLite file, separate from the metrics store
// and the ACL store, for the same single-purpose-abstraction reasoning
// that already gave the ACL its own file: this is runtime-mutable
// operational config, not time-series data.
type SatelliteRegistry struct {
	db *sql.DB
}

// OpenRegistry opens (creating if necessary) the satellite registry at path.
func OpenRegistry(path string) (*SatelliteRegistry, error) {
	if path != ":memory:" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return nil, fmt.Errorf("creating satellite registry directory for %q: %w", path, err)
		}
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("opening satellite registry %q: %w", path, err)
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(registrySchemaSQL); err != nil {
		db.Close()
		return nil, fmt.Errorf("creating satellite registry schema in %q: %w", path, err)
	}
	return &SatelliteRegistry{db: db}, nil
}

func (r *SatelliteRegistry) Close() error { return r.db.Close() }

// Add inserts sat, or updates its address/token/poll interval if a
// satellite with the same name is already registered — re-registering
// (e.g. a satellite's address changed) is idempotent by design, not an error.
func (r *SatelliteRegistry) Add(ctx context.Context, sat config.Satellite) error {
	if sat.Name == "" {
		return fmt.Errorf("satellite name must not be empty")
	}
	if sat.Address == "" {
		return fmt.Errorf("satellite %q: address must not be empty", sat.Name)
	}
	interval := sat.PollInterval.Duration()
	if interval <= 0 {
		interval = time.Minute
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO satellites (name, address, token, poll_interval_ns, created_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(name) DO UPDATE SET
			address = excluded.address,
			token = excluded.token,
			poll_interval_ns = excluded.poll_interval_ns
	`, sat.Name, sat.Address, sat.Token, int64(interval), time.Now().Unix())
	if err != nil {
		return fmt.Errorf("registering satellite %q: %w", sat.Name, err)
	}
	return nil
}

// Remove deletes the satellite named name, if present. Removing an
// unknown name is not an error — the end state (that name is not
// registered) is what the caller wanted either way.
func (r *SatelliteRegistry) Remove(ctx context.Context, name string) error {
	_, err := r.db.ExecContext(ctx, `DELETE FROM satellites WHERE name = ?`, name)
	if err != nil {
		return fmt.Errorf("removing satellite %q: %w", name, err)
	}
	return nil
}

// List returns every dynamically registered satellite.
func (r *SatelliteRegistry) List(ctx context.Context) ([]config.Satellite, error) {
	rows, err := r.db.QueryContext(ctx, `SELECT name, address, token, poll_interval_ns FROM satellites ORDER BY name`)
	if err != nil {
		return nil, fmt.Errorf("listing satellites: %w", err)
	}
	defer rows.Close()

	var out []config.Satellite
	for rows.Next() {
		var sat config.Satellite
		var intervalNs int64
		if err := rows.Scan(&sat.Name, &sat.Address, &sat.Token, &intervalNs); err != nil {
			return nil, err
		}
		sat.PollInterval = config.Duration(time.Duration(intervalNs))
		out = append(out, sat)
	}
	return out, rows.Err()
}
