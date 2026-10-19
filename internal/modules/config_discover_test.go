package modules

import (
	"context"
	"errors"
	"reflect"
	"sort"
	"testing"
)

func TestParseUnitConfigPaths(t *testing.T) {
	cases := []struct {
		name string
		unit string
		want []string
	}{
		{
			name: "nginx -c argument",
			unit: "[Service]\nExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on;'\nExecStart=/usr/sbin/nginx -c /etc/nginx/nginx.conf\n",
			want: []string{"/etc/nginx/nginx.conf"},
		},
		{
			name: "mysql defaults-file + EnvironmentFile",
			unit: "[Service]\nEnvironmentFile=-/etc/default/mysql\nExecStart=/usr/sbin/mysqld --defaults-file=/etc/mysql/my.cnf\n",
			// --defaults-file=... is one token (not a separate arg), so it is
			// picked up as a bare config path; EnvironmentFile is picked up too.
			want: []string{"/etc/default/mysql"},
		},
		{
			name: "bare config path, binary excluded",
			unit: "[Service]\nExecStart=/usr/bin/redis-server /etc/redis/redis.conf\n",
			want: []string{"/etc/redis/redis.conf"},
		},
		{
			name: "runtime paths dropped",
			unit: "[Service]\nExecStart=/usr/sbin/sshd -f /etc/ssh/sshd_config -p /run/sshd.pid\n",
			want: []string{"/etc/ssh/sshd_config"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseUnitConfigPaths(tc.unit)
			sort.Strings(got)
			sort.Strings(tc.want)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("parseUnitConfigPaths = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestGuessCodec(t *testing.T) {
	cases := map[string][2]string{
		"/etc/docker/daemon.json": {"json", ""},
		"/etc/netplan/01.yaml":    {"yaml", ""},
		"/etc/ssh/sshd_config":    {"keyvalue", " "},
		"/etc/default/grub":       {"keyvalue", "="},
		"/etc/nginx/nginx.conf":   {"", ""},
	}
	for path, want := range cases {
		f, s := GuessCodec(path)
		if f != want[0] || s != want[1] {
			t.Errorf("GuessCodec(%q) = (%q,%q), want (%q,%q)", path, f, s, want[0], want[1])
		}
	}
}

func TestUnitFilePath(t *testing.T) {
	unit := "# /usr/lib/systemd/system/redis.service\n[Unit]\nDescription=Redis\n\n# /etc/systemd/system/redis.service.d/limit.conf\n"
	if got := unitFilePath(unit); got != "/usr/lib/systemd/system/redis.service" {
		t.Errorf("unitFilePath = %q", got)
	}
	if got := unitFilePath("[Unit]\nDescription=x\n"); got != "" {
		t.Errorf("no header comment → empty, got %q", got)
	}
}

func TestDeclaredConfigPaths(t *testing.T) {
	// rpm -qc: one path per line; dpkg ${Conffiles}: " path md5 [obsolete]".
	rpm := "/etc/logrotate.d/redis\n/etc/redis/redis.conf\n/etc/redis/sentinel.conf\n/var/lib/redis\n"
	dpkg := " /etc/default/redis-server 36255dd8\n /etc/init.d/redis-server 2a51c7aa\n /etc/redis/redis.conf eea5feff\n /etc/redis/old.conf 0000 obsolete\n"
	if got, want := declaredConfigPaths(rpm), []string{"/etc/logrotate.d/redis", "/etc/redis/redis.conf", "/etc/redis/sentinel.conf"}; !reflect.DeepEqual(got, want) {
		t.Errorf("rpm: got %v want %v", got, want)
	}
	if got, want := declaredConfigPaths(dpkg), []string{"/etc/default/redis-server", "/etc/redis/redis.conf"}; !reflect.DeepEqual(got, want) {
		t.Errorf("dpkg: got %v want %v", got, want)
	}
}

// The package lookup: rpm answers directly; on Debian the owner comes from
// dpkg-query -S (retrying the pre-usrmerge path) and its conffiles follow.
func TestPackageConfigFiles(t *testing.T) {
	rpmHost := &ConfigDiscover{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if name == "rpm" && args[0] == "-qcf" && args[1] == "/usr/lib/systemd/system/redis.service" {
			return []byte("/etc/redis/redis.conf\n"), nil
		}
		return nil, errors.New("unexpected " + name)
	}}
	if got := rpmHost.packageConfigFiles(context.Background(), "/usr/lib/systemd/system/redis.service"); !reflect.DeepEqual(got, []string{"/etc/redis/redis.conf"}) {
		t.Errorf("rpm host: %v", got)
	}
	debHost := &ConfigDiscover{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		switch {
		case name == "dpkg-query" && args[0] == "-S" && args[1] == "/lib/systemd/system/redis-server.service":
			return []byte("redis-server: /lib/systemd/system/redis-server.service\n"), nil
		case name == "dpkg-query" && args[0] == "-W" && args[len(args)-1] == "redis-server":
			return []byte(" /etc/redis/redis.conf eea5\n"), nil
		}
		return nil, errors.New("not found")
	}}
	if got := debHost.packageConfigFiles(context.Background(), "/usr/lib/systemd/system/redis-server.service"); !reflect.DeepEqual(got, []string{"/etc/redis/redis.conf"}) {
		t.Errorf("deb host: %v", got)
	}
}
