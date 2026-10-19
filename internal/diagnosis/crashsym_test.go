package diagnosis

import (
	"debug/elf"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseKernelCrashReadsSegfaultAndTrapLines(t *testing.T) {
	seg := "probe[1234]: segfault at 10 ip 00007f3c8a1b2c4d sp 00007ffd5e6f7a80 error 6 in libc.so.6[7f3c8a0a1000+195000]"
	cf, ok := ParseKernelCrash(seg)
	if !ok || cf.Comm != "probe" || cf.PID != 1234 || cf.Kind != "segfault" || cf.FaultAddr == nil || *cf.FaultAddr != 0x10 ||
		cf.IP != 0x7f3c8a1b2c4d || cf.Module != "libc.so.6" || cf.MapStart != 0x7f3c8a0a1000 || cf.MapSize != 0x195000 {
		t.Fatalf("segfault: %+v", cf)
	}
	trap := "traps: svc[9][5678] general protection fault ip:401234 sp:7ffd0000 error:0 in probe[400000+2000]"
	cf, ok = ParseKernelCrash(trap)
	if !ok || cf.Kind != "general protection fault" || cf.IP != 0x401234 || cf.FaultAddr != nil || cf.Module != "probe" {
		t.Fatalf("trap: %+v", cf)
	}
	if _, ok := ParseKernelCrash("random kernel chatter"); ok {
		t.Fatal("a non-fault line must not parse")
	}
	// the newer kernel format measured on bossman-dev: module[<ip-offset>,base+size] + a "likely on CPU" tail
	real := "yoloman-crasher[813917]: segfault at 10 ip 000000000040187c sp 00007ffe5449f170 error 4 in yoloman-crasher[187c,401000+7e000] likely on CPU 3 (core 3, socket 0)"
	cf, ok = ParseKernelCrash(real)
	if !ok || cf.Module != "yoloman-crasher" || cf.IP != 0x40187c || cf.MapStart != 0x401000 || cf.MapSize != 0x7e000 || *cf.FaultAddr != 0x10 {
		t.Fatalf("newer format: %+v", cf)
	}
}

// TestSymbolizeNamesTheFunctionFromARealELF compiles a tiny C program and resolves an address inside it to its
// function through the program's own symbol table — the whole path from a (synthetic) kernel mapping to a name.
func TestSymbolizeNamesTheFunctionFromARealELF(t *testing.T) {
	cc, err := exec.LookPath("cc")
	if err != nil {
		t.Skip("no C compiler")
	}
	dir := t.TempDir()
	src := filepath.Join(dir, "p.c")
	bin := filepath.Join(dir, "p")
	if err := os.WriteFile(src, []byte("int crashy(int x){return *(int*)0;} int other(void){return 7;} int main(){return crashy(1)+other();}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command(cc, "-O0", "-no-pie", "-o", bin, src).CombinedOutput(); err != nil {
		t.Skipf("cc failed: %s", out)
	}
	ef, err := elf.Open(bin)
	if err != nil {
		t.Fatal(err)
	}
	syms, err := ef.Symbols()
	ef.Close()
	if err != nil {
		t.Skip("the test binary has no symbol table")
	}
	var crashy *elf.Symbol
	for i := range syms {
		if syms[i].Name == "crashy" {
			crashy = &syms[i]
		}
	}
	if crashy == nil {
		t.Skip("crashy not in the symbol table")
	}
	// a synthetic mapping: the kernel's map start is arbitrary; an ip inside crashy must resolve to it
	var execProg *elf.Prog
	ef2, _ := elf.Open(bin)
	defer ef2.Close()
	for _, p := range ef2.Progs {
		if p.Type == elf.PT_LOAD && p.Flags&elf.PF_X != 0 {
			execProg = p
		}
	}
	const mapStart = 0x555500000000
	ip := mapStart + (crashy.Value + 4) - execProg.Vaddr + (execProg.Off &^ 0xfff) - (execProg.Off &^ 0xfff)
	f := &CrashFrame{Comm: "p", Module: "p", IP: ip, MapStart: mapStart, MapSize: 0x100000, Kind: "segfault"}
	Symbolize(f, bin, nil)
	if !strings.Contains(f.Function, "crashy") {
		t.Fatalf("function = %q (gap %q)", f.Function, f.Gap)
	}
}
