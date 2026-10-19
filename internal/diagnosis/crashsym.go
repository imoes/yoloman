package diagnosis

import (
	"debug/elf"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// CrashFrame is where a Linux process crashed (plan B14): the kernel's own fault line — module and instruction
// pointer — resolved to a function by the module's symbols. No core dump: the kernel logs every user-space fault with
// the mapping it happened in, and the module's build id names its debug symbols (local, or on a debuginfod server).
type CrashFrame struct {
	Line         string  `json:"line"`
	Comm         string  `json:"comm"`
	PID          int     `json:"pid"`
	Kind         string  `json:"kind"`       // "segfault", or the trap's own words ("general protection fault", "invalid opcode")
	FaultAddr    *uint64 `json:"fault_addr"` // the address that was accessed (segfault only)
	IP           uint64  `json:"ip"`
	Module       string  `json:"module"`
	MapStart     uint64  `json:"map_start"`
	MapSize      uint64  `json:"map_size"`
	ModulePath   string  `json:"module_path"`
	BuildID      string  `json:"build_id"`
	Address      uint64  `json:"address"` // the virtual address inside the module's ELF
	Function     string  `json:"function"`
	Displacement uint64  `json:"displacement"`
	SymbolSource string  `json:"symbol_source"`
	Gap          string  `json:"gap"`
}

var (
	// The mapping bracket is module[base+size] on older kernels and module[<ip-offset>,base+size] on newer ones
	// (measured: "in yoloman-crasher[187c,401000+7e000] likely on CPU 3"); the optional "<hex>," is ignored.
	// "probe[1234]: segfault at 10 ip 00007f3c8a1b2c4d sp 00007ffd5e6f7a80 error 6 in libc.so.6[7f3c8a0a1000+195000]"
	segfaultRe = regexp.MustCompile(`(\S+)\[(\d+)\]: segfault at ([0-9a-f]+) ip ([0-9a-f]+) sp [0-9a-f]+ error [0-9a-f]+ in ([^\[\s]+)\[(?:[0-9a-f]+,)?([0-9a-f]+)\+([0-9a-f]+)\]`)
	// "traps: probe[1234] general protection fault ip:7f3c8a1b2c4d sp:7ffd5e6f7a80 error:0 in libc.so.6[7f3c8a0a1000+195000]"
	trapRe = regexp.MustCompile(`traps: (\S+)\[(\d+)\] (.+?) ip:([0-9a-f]+) sp:[0-9a-f]+ error:[0-9a-f]+ in ([^\[\s]+)\[(?:[0-9a-f]+,)?([0-9a-f]+)\+([0-9a-f]+)\]`)
)

// ParseKernelCrash reads one kernel fault line (the format of arch/x86/mm/fault.c and the traps handler).
func ParseKernelCrash(line string) (CrashFrame, bool) {
	hexOf := func(s string) uint64 { n, _ := strconv.ParseUint(s, 16, 64); return n }
	if m := segfaultRe.FindStringSubmatch(line); m != nil {
		pid, _ := strconv.Atoi(m[2])
		addr := hexOf(m[3])
		return CrashFrame{Line: line, Comm: m[1], PID: pid, Kind: "segfault", FaultAddr: &addr, IP: hexOf(m[4]), Module: m[5],
			MapStart: hexOf(m[6]), MapSize: hexOf(m[7])}, true
	}
	if m := trapRe.FindStringSubmatch(line); m != nil {
		pid, _ := strconv.Atoi(m[2])
		return CrashFrame{Line: line, Comm: m[1], PID: pid, Kind: m[3], IP: hexOf(m[4]), Module: m[5],
			MapStart: hexOf(m[6]), MapSize: hexOf(m[7])}, true
	}
	return CrashFrame{}, false
}

// FetchDebug returns the path of the debug file for a build id, or an error (debuginfod, a cache …).
type FetchDebug func(buildID string) (string, error)

// Symbolize resolves f.IP to a function of the module at modulePath. The mapping the kernel names is the module's
// executable PT_LOAD segment, so its file offset is ip - map start + that segment's page-aligned offset, and the ELF
// virtual address follows from the segment. Symbols, in order: the local debug file (/usr/lib/debug/.build-id/…),
// fetch (debuginfod), the module's own symbol table, its exported (dynamic) symbols — the last named as such, because
// the nearest exported function may not be the one that ran.
func Symbolize(f *CrashFrame, modulePath string, fetch FetchDebug) {
	f.ModulePath = modulePath
	ef, err := elf.Open(modulePath)
	if err != nil {
		f.Gap = "the module " + modulePath + " could not be read as ELF: " + err.Error()
		return
	}
	defer ef.Close()
	var exec *elf.Prog
	for _, p := range ef.Progs {
		if p.Type == elf.PT_LOAD && p.Flags&elf.PF_X != 0 {
			exec = p
			break
		}
	}
	if exec == nil || f.IP < f.MapStart || f.IP >= f.MapStart+f.MapSize {
		f.Gap = fmt.Sprintf("ip 0x%x is not inside the mapping %s[%x+%x] the kernel named", f.IP, f.Module, f.MapStart, f.MapSize)
		return
	}
	const page = 0x1000
	fileOff := f.IP - f.MapStart + (exec.Off &^ (page - 1))
	f.Address = fileOff - exec.Off + exec.Vaddr
	f.BuildID = buildID(ef)

	try := func(path, source string, dynamic bool) bool {
		sf := ef
		if path != modulePath {
			o, err := elf.Open(path)
			if err != nil {
				return false
			}
			defer o.Close()
			sf = o
		}
		syms, err := sf.Symbols()
		if dynamic {
			syms, err = sf.DynamicSymbols()
		}
		if err != nil || len(syms) == 0 {
			return false
		}
		name, disp, exact := nearestFunc(syms, f.Address)
		if name == "" {
			return false
		}
		f.Function, f.Displacement, f.SymbolSource = moduleBase(f.Module)+"!"+name, disp, source
		if !exact {
			f.SymbolSource += " — nearest preceding function; the address lies outside its recorded size"
		}
		return true
	}
	if f.BuildID != "" && len(f.BuildID) > 2 {
		local := filepath.Join("/usr/lib/debug/.build-id", f.BuildID[:2], f.BuildID[2:]+".debug")
		if _, err := os.Stat(local); err == nil && try(local, "local debug symbols "+local, false) {
			return
		}
		if fetch != nil {
			if p, err := fetch(f.BuildID); err == nil {
				if try(p, "debuginfod (build id "+f.BuildID+")", false) {
					return
				}
			} else {
				f.Gap = "debug symbols for build id " + f.BuildID + " could not be fetched: " + clip(err.Error(), 160)
			}
		}
	}
	if try(modulePath, "the module's own symbol table", false) {
		f.Gap = ""
		return
	}
	if try(modulePath, "the module's exported symbols only (no debug symbols)", true) {
		return
	}
	if f.Gap == "" {
		f.Gap = "no symbols cover 0x" + strconv.FormatUint(f.Address, 16) + " in " + f.Module
	}
}

func nearestFunc(syms []elf.Symbol, addr uint64) (string, uint64, bool) {
	var best *elf.Symbol
	for i := range syms {
		s := &syms[i]
		if elf.ST_TYPE(s.Info) != elf.STT_FUNC || s.Value == 0 || s.Value > addr {
			continue
		}
		if best == nil || s.Value > best.Value {
			best = s
		}
	}
	if best == nil {
		return "", 0, false
	}
	return best.Name, addr - best.Value, best.Size == 0 || addr < best.Value+best.Size
}

func buildID(ef *elf.File) string {
	sec := ef.Section(".note.gnu.build-id")
	if sec == nil {
		return ""
	}
	data, err := sec.Data()
	if err != nil || len(data) < 16 {
		return ""
	}
	namesz := ef.ByteOrder.Uint32(data[0:4])
	descsz := ef.ByteOrder.Uint32(data[4:8])
	start := 12 + (namesz+3)&^3
	if int(start+descsz) > len(data) {
		return ""
	}
	return hex.EncodeToString(data[start : start+descsz])
}

func moduleBase(m string) string {
	b := filepath.Base(m)
	if i := strings.Index(b, ".so"); i > 0 {
		return b[:i]
	}
	return b
}
