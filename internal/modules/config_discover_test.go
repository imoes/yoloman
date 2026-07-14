package modules

import (
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

func TestGuessFormat(t *testing.T) {
	for path, want := range map[string]string{
		"/etc/docker/daemon.json": "json",
		"/etc/netplan/01.yaml":    "yaml",
		"/etc/ssh/sshd_config":    "keyvalue",
		"/etc/nginx/nginx.conf":   "",
	} {
		if got := guessFormat(path); got != want {
			t.Errorf("guessFormat(%q) = %q, want %q", path, got, want)
		}
	}
}
