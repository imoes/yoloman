package ebpf

//go:generate go run github.com/cilium/ebpf/cmd/bpf2go -go-package ebpf -cc clang -cflags "-O2 -g -Wall -I/usr/include/x86_64-linux-gnu" -target amd64 -type event collector bpf/collector.c
