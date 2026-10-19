# Kernel tuning — the LLM proposes, the kernel only runs what was checked

## The idea

A language model never runs inside the kernel. The kernel works with time budgets of microseconds and does not
use floating point; a model is too slow by orders of magnitude and cannot be verified. Every serious approach
therefore splits the work into two planes. The model sits in user space as the control plane. In the kernel run
only small, verified programs (eBPF, checked by the kernel's own verifier) or plain parameter values (sysctl, cgroup
limits, the boot command line).

yoloman already is that control plane. It observes (the eBPF collector, PSI, metrics), it can only act through
declared modules, every change goes through a plan and a dry run, it keeps generations to roll back to, and the
remediation loop already knows proposal, guardrail, apply, verify and rollback. What was missing was the kernel side:
knowing what a kernel can be tuned with, modules for the tunables, and a way to decide by measurement whether a
change made things better.

## The decision that shapes everything: choose, do not write

The model does **not** write scheduler code. The SchedCP work (NeurIPS 2025) measured the alternative: having an
agent write a scheduler from scratch took 33 minutes, cost 6 dollars and often made performance worse. Choosing
and parameterising from a curated set of existing schedulers was up to 1.79 times faster and 13 times cheaper.
yoloman therefore offers a catalogue — the sched_ext schedulers of the `scx` project (scx_bpfland, scx_lavd,
scx_rusty, scx_layered), sysctl values, cgroup limits, readahead, the CPU governor and kernel command line
parameters — and the model picks and parameterises from it. Freely written eBPF can come later, as a module
proposal through `submit_module` that the validator checks and that only ever runs in a rehearsal first.

## The building blocks

1. **Kernel capabilities as facts.** Before anything is proposed, the agent says what this kernel supports:
   whether BTF is present, whether sched_ext is built in and which BPF scheduler is attached, the relevant `CONFIG_*`
   flags, the boot loader (where a command line is persisted) and the init system (how a value survives a reboot).
   *Done — see below.*
2. **Observation that can be compared.** Run-queue latency, OOM kills and signals become stored metrics, so a
   window before a change can be compared with the window after it. *Done — see below.*
3. **Tunable modules.** `sched_ext`, `systemd_resource`, `blockdev_tuning`, `cpu_governor`, `kernel_cmdline`. Each
   reports the value before and after, supports check mode and says whether a value is live (effective now, lost
   at reboot), persistent (survives a reboot), or pending a reboot. *Done — see below.*
4. **Tunables as desired state,** so plan, apply, generations and rollback cover them like any config file. sysctl
   stays with its existing codec — one way to reach a result, not two. *Done — see below.*
5. **Benchmarks and experiments.** Fixed workload profiles (hackbench or schbench for the scheduler, fio for I/O,
   stress-ng or sysbench for CPU and memory) and an experiment record whose verdict is one of `better`, `worse`,
   `no_difference`, `inconclusive` or `aborted`. An effect inside the measured noise is `no_difference`, never
   `better`.
6. **Rehearsal on a Proxmox VM.** Snapshot, apply, benchmark baseline and candidate alternately, roll the VM back to
   the snapshot. Kernel changes cannot be rehearsed in a container.
7. **The tuning loop** reuses remediation: the same guardrails (kill switch off by default, production only when
   allowed, rate and blast-radius limits). Verify means the rehearsal said `better` and production shows no regression
   in the window after the change; otherwise the previous generation is restored. Each proposal carries its reason in
   the diagnosis format: evidence, claim, before, after, rollback and verify.
8. **Every common distribution.** Only the way a value is persisted differs between distribution families. Each
   tunable has one dispatch on the OS family and the detected boot loader and init system. A combination that is not
   supported reports `unsupported` with its reason instead of failing silently.

## Block 1: what the kernel can be tuned with

The package `internal/kernelcaps` reads files only and never runs a binary. Every answer is a named state that
cites the file that proved it.

- **btf** is `present`, `absent` or `unknown`, from `/sys/kernel/btf/vmlinux`. sched_ext schedulers are CO-RE
  programs and need it.
- **config** holds the flags `CONFIG_SCHED_CLASS_EXT`, `CONFIG_DEBUG_INFO_BTF`, `CONFIG_BPF_SYSCALL`,
  `CONFIG_BPF_JIT`, `CONFIG_BPF_EVENTS`, `CONFIG_CGROUP_BPF` and `CONFIG_PSI`, each `y`, `m` or `n`. They come from
  `/proc/config.gz`, the running kernel's own view, and otherwise from `/boot/config-<release>`. The source is
  named; when neither is readable the source is `unknown`. A flag that does not appear in a readable config is `n`.
- **sched_ext** is `unsupported`, `disabled`, `enabling`, `enabled`, `disabling` or `unknown`, from
  `/sys/kernel/sched_ext/state`. When enabled, `ops` names the attached BPF scheduler. When the sysfs directory is
  missing, the reason is derived from the config: built without it, config unreadable, or built in but sysfs missing
  (`unknown`, because that combination should not happen).
- **boot_loader** is `uki`, `systemd-boot`, `grub`, `extlinux` or `unknown`. systemd's EFI variables are the
  strongest evidence because the loader wrote them during this boot, so they are checked before `grub.cfg` or
  `extlinux.conf` (a stale `grub.cfg` next to systemd-boot is common).
- **init_system** is `systemd`, `openrc` or `unknown`, from `/run/systemd/system` or `/run/openrc`.
- **ebpf_collector** is `loaded`, `failed` (with the error), `disabled` (with the config switch) or `not_started`
  (the process never tried, for example the one-shot `run-module` command). Before, a failed load was only a log
  line.

The document appears in two places, filled by the same detector:

- as the fact `yoloman_kernel_caps` of the `setup` module, so a runbook can write
  `when: yoloman_kernel_caps.sched_ext.state != 'unsupported'`. There is no `ansible_` alias, because Ansible has
  no such fact.
- as `kernel_caps` in the host inventory (`GET /api/v1/hosts/overview`).

Verified on this workstation (kernel 7.0.0-38-generic, Ubuntu): BTF present, all seven flags `y` from
`/boot/config-7.0.0-38-generic`, sched_ext `disabled`, boot loader `grub` (`/boot/grub/grub.cfg`), init system
`systemd`.

## Block 2: observation that can be compared

Before this block, run-queue latency, OOM kills and signals could only be asked for live: the run-queue histogram
was a cumulative in-kernel map, and the other two were lists of recent events. Nothing was stored, so there was
no window before a change to compare with the window after it. The collect loop now writes three per-interval series,
using the same "count, then snapshot and reset per tick" convention as `tcp_retransmit_total`. Read the raw value
per point; no `rate()` is needed.

- `runq_latency_us_bucket{le}`: tasks that waited `le` microseconds (log2 buckets) to get a CPU during the interval.
  The kernel map is never reset, so the agent subtracts the previous snapshot. A bucket that went down means the map
  was recreated, and the current value then counts as the whole interval. A bucket with no change is not written.
- `oom_kill_total`: OOM victims in the interval, written every tick, including zero.
- `signal_total{signal}`: deliveries of the notable signals the collector watches, per signal name. A signal that
  was not delivered in the interval is not written, so absence means zero.

Cardinality is bounded on purpose (see docs/metrics-storage.md): about 30 buckets, one OOM series and one series per
notable signal. Nothing is labelled by PID or command. The recent-event lists and their MCP tools (`oom_kills`,
`signals`, `runq_latency`) are unchanged.

Verified on this workstation by running the agent as root for 45 seconds on its own port and database:
- `runq_latency_us_bucket` had 13 buckets from 1 µs to 4096 µs under an eight-way spin load.
- `signal_total{signal="SIGKILL"}` was exactly 3 after killing three `sleep` processes.
- An allocation of 300 MB in a scope limited to 30 MB showed `oom_kill_total` = 1 in the interval of the kill. The
  `oom-kills` list named the same process (python3, PID 883443).

## Block 3: the tunable modules

Five modules are baked into the agent (`internal/starmodules/embedded/modules/yoloman/`), so every host has them
without a push. They share one result shape, because the tuning loop has to treat them alike:

- `before` and `after`: the values as the kernel or systemd reports them.
- `persistence`: `live` (effective now, lost at reboot), `persistent` (also effective after a reboot) or
  `pending_reboot` (configured, not yet running).
- `backend`: the file or mechanism that holds the value.
- `rollback`: the parameters of **one** call that restores the state before this call, persistence included.
  When yoloman's persistence file did not exist before, the rollback is `state: absent` together with the old
  values: the file is removed and the old values are set live.

Every module checks what it needs **before** it changes anything, so a refusal never leaves a half-applied
change. Refusals start with a word the loop can act on: `unsupported:` (this host cannot do it, with the
reason), `tool_unavailable:` (a package is missing) or `conflict:` (someone else manages it).

| Module | What it sets | Persistence |
|---|---|---|
| `yoloman.sched_ext` | a scheduler of the scx project (`scx_bpfland`, `scx_lavd`, `scx_rusty` …) with arguments, or back to the fair class | yoloman's own service (`yoloman-sched-ext.service` or `/etc/init.d/yoloman-sched-ext`), enabled at boot |
| `yoloman.systemd_resource` | CPUWeight, CPUQuota, MemoryMax/High/Low/SwapMax, IOWeight, TasksMax, AllowedCPUs of one unit | yoloman's drop-in `/etc/systemd/system/<unit>.d/90-yoloman-resource.conf`; live via `set-property --runtime` |
| `yoloman.blockdev_tuning` | readahead and I/O scheduler of one block device | udev rule matching the device by ID_WWN, else ID_SERIAL, else the kernel name (`match_stable: false`) |
| `yoloman.cpu_governor` | cpufreq governor and energy/performance preference on all CPUs | `tmpfiles.d` (systemd) or `local.d` (OpenRC) |
| `yoloman.kernel_cmdline` | add or remove boot parameters | grubby; otherwise the GRUB defaults file that really defines the variable, then update-grub or grub(2)-mkconfig; extlinux on Alpine. Always `pending_reboot` until `/proc/cmdline` agrees |

How each module decides:

- **sched_ext** runs the scheduler as yoloman's own service, so "stop what yoloman started" is exact. A scheduler
  someone else started (the distribution's `scx.service`, `scx_loader`) is a `conflict` and is never stopped. The
  module waits until the kernel reports `enabled`. If the scheduler does not attach in time, it is stopped
  again, not left enabled at boot, and the error carries the last log lines. The service has no automatic
  restart: when the kernel's watchdog ejects a scheduler, it stays off and is visible as off, instead of
  flapping.
- **systemd_resource** compares the way systemd reports values (`6G` equals `6442450944`, `150%` equals
  `CPUQuotaPerSecUSec=1.500000s`), so a second run is unchanged. An empty value is valid: systemd's empty
  assignment resets the property, and that is how a property that was `[not set]` is rolled back.
- **kernel_cmdline** refuses a GRUB variable that the shell computes (`$VAR`, backquotes) instead of rewriting it.
  On Debian and Ubuntu the last `/etc/default/grub.d/*.cfg` that sets a variable wins, as it does for
  `grub-mkconfig`, so a cloud image's override is edited where it really takes effect. systemd-boot and UKI
  hosts are `unsupported` for now, because how their entries are regenerated differs per distribution
  (kernel-install, mkinitcpio, sdbootutil).

The OS family comes from one table now (`internal/osfamily`). Before, the setup fact and the Starlark
`ctx.facts()` used two different mappings, and the Starlark one did not know SUSE, Arch or Alpine. `ctx.facts()`
also carries `kernel_caps` from the same detector as block 1.

Verified on this workstation, as root, against throwaway targets:

- `blockdev_tuning` on a fresh loop device set readahead 2560 → 4096 and the scheduler none → mq-deadline and
  wrote the udev rule; the second run was unchanged. Running the reported rollback restored the values and
  removed the rule.
- `systemd_resource` on a transient unit set CPUWeight 400, MemoryHigh 256M, CPUQuota 150% and TasksMax 64.
  The unit's cgroup showed `cpu.weight` 400 and `memory.high` 268435456; the second run was unchanged. Running
  the reported rollback restored `cpu.weight` 100 and `memory.high` max and removed the drop-in.
- `kernel_cmdline` in check mode found `/etc/default/grub` as the effective file, predicted `pending_reboot` and
  the rollback, and wrote nothing (the checksum was unchanged).
- `cpu_governor` was refused with `unsupported: no cpufreq driver`: this workstation is a VM. `sched_ext` was
  refused with `tool_unavailable: scx_bpfland`: scx is not installed.

Verified on a real Debian 13 VM (`test-deployment.example.internal`, kernel 6.12.101, agent build `0.57.94+kt1`).
Everything ran through Bossman: the agent update through `POST /api/v1/agents/{id}/update`, every module call
through the MCP tool `call_agent_tool`.

- `yoloman_kernel_caps` reported `sched_ext: unsupported` with the reason
  `CONFIG_SCHED_CLASS_EXT=n in /boot/config-6.12.101+deb13-amd64`: Debian's 6.12 kernel is built without
  sched_ext. It also reported the eBPF collector `loaded`, boot loader grub and init system systemd. `sched_ext`
  refused with that reason; `cpu_governor` refused with "no cpufreq driver".
- `blockdev_tuning` on the real disk `sda` (matched by ID_SERIAL) set readahead 128 → 1024 and wrote the rule; the
  second run was unchanged, and the reported rollback restored 128 and removed the rule.
- `systemd_resource` on `cron.service` set CPUWeight 50, MemoryHigh 128M and TasksMax 32 (the cgroup showed
  `cpu.weight` 50 and `memory.high` 134217728); the second run was unchanged, and the reported rollback restored
  every value and removed the drop-in.
- `kernel_cmdline` added `transparent_hugepage=madvise` and reported `pending_reboot`. After a reboot,
  `/proc/cmdline` contained it, the kernel ran THP in `[madvise]` mode, and the module reported `persistent` and
  unchanged. The reported rollback (`remove: [transparent_hugepage]`) followed by another reboot gave back the
  original command line and `[always]`.

Not yet verified: a real BPF scheduler attaching. Neither Debian 13 nor Ubuntu 24.04 ships a kernel with
sched_ext plus the scx package; Fedora, Arch or Ubuntu 25.x do. The cpufreq path also needs bare metal or a VM
that exposes cpufreq.

## Block 4: tunables as desired state

A tunable is the resource kind `tunable` (`bossman/bossman/services/resources/tunable.py`), so plan, apply,
generations and rollback work as they do for a container or a config file. The same MCP tools and REST routes drive
it: `resource_observe`, `resource_plan`, `resource_apply`, `resource_generations` and `resource_rollback`, and
`/api/v1/agents/{id}/resources/tunable/{name}/…`.

- **Name**: `<tunable>[:<target>]`. `sched_ext`, `cpu_governor` and `kernel_cmdline` exist once per host;
  `systemd_resource:<unit>` and `blockdev_tuning:<device>` once per unit or device. The target fills the module's
  identifying parameter. A spec that names a different unit or device is refused, never silently retargeted.
- **desired** is `{"params": {...}}`, the parameters of the agent module `yoloman.<tunable>`.
- **plan** runs the module in check mode and returns before/after, persistence, backend and the undo, or
  `action: refused` with `refusal.kind` (`unsupported`, `tool_unavailable`, `conflict`, `error`) and the module's
  reason. A refused plan is never applied.
- **apply** records a generation that holds the applied `params` **and** the module's `undo`. An apply that changes
  nothing records nothing, so the history only contains changes.
- **observe** asks the module, in check mode, about the last applied spec. `drift: true` means the host no longer
  matches what yoloman set. A tunable yoloman never managed is `managed: false`.
- **rollback(n)** re-applies generation n as a new generation, like every other kind. **rollback(0)** is the named
  state "before yoloman managed this": it applies generation 1's undo. If generation 1 has been pruned (only 30 are
  kept), the refusal says so, because the baseline is then no longer known.

Verified end to end through MCP against the real Debian 13 VM `test-deployment`, with a Bossman API instance
built from this branch:
- `systemd_resource:cron.service` started as `managed: false`. The plan showed CPUWeight `""` → 50 and
  MemoryHigh infinity → 128M, `persistent`.
- The apply recorded generation 1, and the host showed CPUWeight=50, MemoryHigh=134217728 and the drop-in. A
  second apply recorded no generation.
- observe reported `managed`, `drift: false`.
- `resource_rollback(generation=0)` recorded generation 2 and returned the host to `[not set]` and infinity,
  without the drop-in.
- `sched_ext` was planned as `refused`, kind `unsupported`, with Debian's `CONFIG_SCHED_CLASS_EXT=n` as the reason.
- `resource_observe` with kind `service` now works over MCP, which it did not before.

**A deviation from the plan, on purpose.** The plan put the generations into the agent (`internal/state`). Bossman's
resource store already keeps 30 generations per resource and is what the MCP tools and the UI read. Two generation
stores for one tunable would be two sources of truth that can disagree, so the agent's modules stay stateless and
report their undo, and Bossman keeps the history.

**Found on the way: MCP could not reach three kinds.** The MCP resource tools built resources through their own
if-chain, which knew only docker, helm, config and role, while REST used the registry and also knew package,
service and k8s. Both now go through `services.resources.build`, the one construction path, and the operator guide
lists every kind.

## Block 5: measuring

`yoloman.benchmark` runs **one** run of one fixed profile per call, so an experiment can alternate baseline and
candidate (A/B/A/B) and slow drift lands on both sides. Every result names its metric, unit, `higher_is_better`,
the tool and its version, and the exact command.

| Profile | Tool | Metric |
|---|---|---|
| `sched_latency` | cyclictest, SCHED_OTHER threads | p99 wake-up latency, µs. More than 1% of samples above the 10 ms histogram are reported as `p99_beyond_histogram`; the max is then given instead |
| `sched_throughput` | hackbench (10 groups, 2000 loops) | time, s |
| `cpu` | stress-ng matrixprod | bogo ops/s |
| `memory` | sysbench memory | MiB/s |
| `io_randread` | fio 4k random read, direct I/O, on a 256 MiB scratch file | IOPS (+ completion-latency p99) |

Verified on test-deployment (Debian 13, 2 vCPU) after the tools were installed with the `apt` module through MCP:
hackbench 4.517 s, stress-ng 3016.8 ops/s, sysbench 8498.81 MiB/s, fio 21976 IOPS (p99 74.24 µs).

`sched_latency` at first failed with "Unable to change scheduling policy" although the agent runs as root with
CAP_SYS_NICE. The cause is the agent unit's `RestrictRealtime=true`, a seccomp filter that every child process
inherits. On systemd hosts every profile therefore runs as its own transient unit, outside the agent's filter and
cgroup limits, and the result says `isolation`. The unit is started with `--no-block` and then waited for, with its
output in files under `/run`: `systemd-run --wait/--pipe` from inside the agent's unit failed on systemd 259 (Fedora 44)
with "Connection timed out" for every transient service, while systemd 257 (Debian 13) accepted it.

Measured with the same agent build on both:

| Host | sched_throughput | sched_latency (p99) | cpu | memory | io_randread |
|---|---|---|---|---|---|
| Debian 13, kernel 6.12 (test-deployment) | 4.496 s | 75 µs | 3016.8 ops/s | 8498.81 MiB/s | 21976 IOPS |
| Fedora 44, kernel 6.19 (kt-sched-01) | 5.87 s | 78 µs | 3204.7 ops/s | 8249.4 MiB/s | 21197 IOPS |
| Ubuntu 26.04.1 LTS, kernel 7.0 (kt-ubuntu-01) | 4.427 s | 80 µs | 3129.18 ops/s | 8225.57 MiB/s | 22366 IOPS |
| AlmaLinux 10.2, kernel 6.12 el10 (kt-alma-01, CPU model x86-64-v3) | 3.849 s | 78 µs | 3062.21 ops/s | — (sysbench is not in Alma's repositories) | 21174 IOPS |

On Fedora, cyclictest and hackbench are in `realtime-tests`: Fedora's `rt-tests` contains no binaries.

**A real BPF scheduler on Fedora 44 (kernel 6.19):** sched_ext is `disabled`, BTF is present, and the packaged
schedulers are installed. All of them fail to load their BPF program into this kernel with `Invalid argument`:
`scx_rusty` 0.5.4, and `scx_simple` and `scx_central` from scx_c_schedulers 0.1.8 (built for fc41). Fedora 44 ships
scx userspace from 2024 that no longer matches the kernel. The module behaved as designed each time: it stopped the
service, did not enable it at boot, returned the scheduler's own log lines, and the kernel stayed on the fair class.
A working BPF scheduler needs current scx built from upstream.

AlmaLinux 10.2's kernel (6.12.0-211.65.1.el10_2) is built with sched_ext (`disabled`, BTF present, eBPF collector
loaded), unlike Debian 13's 6.12. Neither AlmaLinux nor EPEL 10 packages scx, so there too a BPF scheduler needs
scx built from upstream.
Ubuntu 26.04.1 (kernel 7.0.0-38) is the same: sched_ext `disabled`, BTF present, and no scx package in main,
universe or multiverse.

### Building scx from upstream: `yoloman.scx_install`

Because no distribution ships working scx userspace, `yoloman.scx_install` builds a pinned release from source. It
runs `git clone --branch <tag>` and `cargo build --release --locked -p scx_<name>…` as the transient unit
`yoloman-scx-build-<version>` (Nice 10, idle I/O, CPUWeight 20), installs the binaries into
`/opt/yoloman/scx/<version>/bin` with a `BUILD-INFO` file (commit, rustc, date), and links
`/usr/local/bin/scx_<name>` to them. `yoloman.sched_ext` then finds them with `command -v`, before any packaged copy.

- States: `built` (present and linked), `building` (the unit runs; calling again starts nothing new and waits up to
  `wait` seconds), `absent`. A failed build fails the call with its last log lines, and the next call starts over.
- There is no `latest`: the version is a tag, so a build is reproducible. The default is v1.1.4.
- Missing build tools are `tool_unavailable` with this family's package names (git, make, clang, llvm, libelf,
  pkg-config, cargo, rustc and the zlib, zstd and seccomp headers), to be installed with the package module. A
  non-yoloman file at `/usr/local/bin/scx_<name>` is a `conflict`, and so is removing a build that
  `yoloman.sched_ext` is running.
- The yoloman links always point at exactly one version, so the rollback is one call: `absent`, or the version that
  was linked before, which is only relinked, not rebuilt.

Measured on Ubuntu 26.04.1 (2 vCPU, through MCP):
- The first build attempt failed with "make is required to compile libbpf-sys", so `make` is now in the tool check.
- v1.1.4 with rusty, bpfland and lavd then built in 4 min 03 s and used 1.44 GB under `/var/tmp` plus 0.2 GB of
  crates.
- A second call during the build answered `building` without starting another one.

**A real BPF scheduler attached.** Through the tunable resource (`resource_apply` kind `tunable`, name `sched_ext`,
`{"params": {"scheduler": "bpfland", "persistent": false}}`), `scx_bpfland` 1.1.4 attached to Ubuntu 26.04's kernel
7.0. The kernel reported `enabled` and ops `bpfland_1.1.4_x86_64_unknown_linux_gnu`. `resource_rollback(0)`
returned it to `disabled`, the fair class. Three runs each:

| | fair class (EEVDF) | scx_bpfland |
|---|---|---|
| hackbench, s (lower is better) | 4.515, 5.102, 4.667 (median 4.667) | 4.308, 4.111, 4.391 (median 4.308) |
| cyclictest p99, µs | 79, 274, 74 (median 79) | 82, 84, 80 (median 82) |

For hackbench the ranges do not overlap: the worst bpfland run beat the best fair-class run, and the median is 7.7 %
lower. With three runs a side that is a hint, not yet a verdict of `better`. The wake-up latency shows no difference
in the median; only the fair class had an outlier (274 µs). The experiment record of block 5, with more runs and the
noise band, is what turns this into a verdict.

The tuning tools got Bossman's long tool timeout (900 s instead of 30 s): a benchmark run, update-grub and waiting
for a scheduler to attach all outlast the default.

### Experiments: does a tunable help?

`experiment_start(host, tunable, params, profile, runs=5)` (REST `POST /api/v1/agents/{id}/experiments`,
`services/experiment.py`, table `tuning_experiments`) measures one candidate against the host as it is. The runs
alternate A (as is) and B (the candidate), so slow drift lands on both sides. B is set with the tunable's module
and undone with the undo that same module reported, so the resource history does not fill up with flip-flops.
At the end the module is asked, in check mode, whether the host is back at A (`restored`).
`experiment_status(id, wait_s)` follows it, and `experiments(host)` lists them.

The verdict is one of `better`, `worse`, `no_difference`, `inconclusive` or `aborted`, and it answers two
separate questions:
- **Do the sides differ?** A two-sided Mann-Whitney U test, exact for 3–20 runs a side and robust to an outlier,
  decides at p < 0.05.
- **Does the difference matter?** It must move the median by at least 2 %.
- So: `better`/`worse` needs both. Below 2 % is `no_difference`. 2 % or more without significance is `inconclusive`
  ("run more"). Runs that scatter by more than 25 % (relative IQR) are `inconclusive` too. Every summary names
  its rule.

Refused before anything changes:
- a candidate the host refuses or already has;
- `runs` outside 3–20;
- a tunable that needs a reboot, unless it runs as a rehearsal.

The rule was measured into shape on Ubuntu 26.04 (fair class against `scx_bpfland`, hackbench):
- A "ranges must not overlap" rule called a 9.4 % gain (5+5 runs) `no_difference` because of one outlier.
- A "the move must exceed the runs' noise band" rule then called a 6.6 % gain with p = 0.0015 (10+10 runs)
  `no_difference`. That rule compared a difference of medians with the scatter of single runs; the median's
  uncertainty shrinks with the number of runs, the single run's scatter does not.
- Re-judged under the current rule, the two experiments are `inconclusive` (p = 0.151) and `better`: **scx_bpfland
  shortens hackbench by 6.6 % on this 2-vCPU VM** (median 4.733 s → 4.419 s, host restored to A after 20
  switches).

## Block 6: rehearsal on a Proxmox VM

`experiment_start(..., snapshot=true)` on a VM that Bossman deployed works like this:
1. It takes a disk snapshot (`ProxmoxClient.vm_snapshot`).
2. It runs the experiment.
3. It rolls the VM back to the snapshot, starts it again and deletes the snapshot. The summary records
   `rolled_back`.

With a snapshot, a tunable that needs a reboot (`kernel_cmdline`) becomes testable. It cannot alternate, so it
runs A×n, then the candidate plus a reboot (the agent's `reboot` module, then waiting for the next report), then
B×n, and the summary says the order was sequential. vCenter snapshots are refused as not supported yet. An
experiment cut off by a Bossman restart is marked `aborted` with the undo it may still need.

## scx in the agent

`scripts/build-scx.sh` builds the scx version and schedulers that `yoloman.scx_install` defaults to (it reads them
from the module) in the official Rust container. It strips the binaries and refuses any that needs a glibc newer
than 2.39 (AlmaLinux 10). `build-agent-deb.sh` puts the build into the `.deb` and `.rpm` at
`/usr/lib/yoloman/scx/<version>/`. libelf and zstd are recommended, not required. `scx_install` with
`source=auto` (the default) links that build after an `ldd` check, which names a missing library with its
package. It builds from upstream only for another version or set of schedulers.

Measured:
- v1.1.4 with rusty, bpfland and lavd built in 4 minutes (the scx repository's rust-toolchain pulled rustc 1.99.1).
- The package grew from 18.6 to 26.7 MB.
- With agent 0.57.96+kt6 on **Fedora 44** and **AlmaLinux 10.2**, the bundled build was linked without a
  compiler. `scx_bpfland` attached through the tunable resource (`enabled`, ops
  `bpfland_1.1.4_x86_64_unknown_linux_gnu`) and `rollback(0)` returned both to the fair class.
- Fedora's own scx packages had failed on the same kernel with "Invalid argument".

More distributions (openSUSE, Arch, Alpine) are prepared, not built: docs/netinstall-more-distros.md.

## Test hosts through MCP: deploying a VM

A rehearsal needs a VM, so deploying one is part of the MCP surface (`services/vm_provision.py`, the same code as
`POST /api/v1/provisioning/vm-hosts/{id}/auto-provision`):

- `vm_hosts(placement=True)` lists the hypervisors, each node's storages and bridges, and the golden images.
- `check_ip(addresses)` and `suggest_free_ips(prefix)` ask three sources (`services/ip_check.py`): Bossman's own
  records, NetBox when configured (`BOSSMAN_NETBOX_URL` plus a token, or a username and password for a read-only
  session), and a live ping plus ARP from an enrolled agent in the same subnet. An address is free only when the
  live probe ran and saw nothing and no record holds it. Measured on 192.0.2.0/24: NetBox listed .225 (a VM Bossman
  had provisioned) and .226 as available, and both answered ARP.
- `deploy_vm(..., dry_run=True)` lists every pre-flight check: image ready, node, storage and bridge exist, hostname
  not an enrolled host, address free. `dry_run=False` refuses while any check fails, then creates the VM and arms
  the PXE restore. `deployment_status(hostname)` shows the restore step and the enrolment.

Verified through MCP: placement of "PVE Lab" (pve1–0223, bridge vmbr0), `check_ip` (192.0.2.134 free; .222,
.225 and .226 in use, each with its MAC), and the `deploy_vm` dry run for 192.0.2.134/24 on VLAN 1028 with all six
checks passing.

### DHCP only for the VM's MAC

While netboot is on, the PXE container's DHCP is derived from the active jobs (`services/netboot_dhcp.py`) and is
one of three named states:
- `restricted`: every active job names its MAC. dnsmasq gets one `dhcp-host` line per MAC plus
  `dhcp-ignore=tag:!known`, so every other machine on the segment is ignored. This is what `deploy_vm` produces,
  because the hypervisor hands out the MAC.
- `open`: a restore job armed without a MAC (the next machine that boots claims it) opens DHCP to everyone, but only
  for `BOSSMAN_NETBOOT_OPEN_DHCP_MINUTES` (default 15). Once a machine claims the job, its MAC is recorded and the
  state becomes `restricted`.
- `off`: no active job, netboot disabled, or the wildcard window has ended.

In full DHCP mode a network install's MAC is bound to the static address its deployment was checked for, so the
installer gets exactly that address. In `off` no dnsmasq runs at all, so nothing listens on the segment (no DHCP 67, no TFTP 69). While a job is
armed it runs without DNS (`port=0`); clients get `PXE_DNS_SERVER` as their DNS server.
`GET /api/v1/netboot/config` carries `dhcp_mode`, `dhcp_macs`, `dhcp_hosts`
(MAC and address) and `dhcp_reason`, and the container logs the reason
with every change. A MAC that is not exactly `xx:xx:xx:xx:xx:xx` is dropped, which fails closed: nobody is served.
`set_netboot(enabled)` switches netboot over MCP. It is the same implementation as the WebUI toggle and needs an
all-hosts grant.

### Four distributions through their own installers

The image restore is Debian-only (grub-install, initramfs-tools, dpkg). `deploy_vm(install="<distro>[-<release>]")`
installs with the distribution's own network installer instead (`services/netinstall.py`, table `netinstall_jobs`).
Without a release, the newest stable or LTS release is read from the mirror at deploy time, so "debian" means
Debian 13.7 today and the next point release tomorrow, without a code change.

| install | Installer | Configuration | Default packages | Minimum memory | CPU model |
|---|---|---|---|---|---|
| `fedora` | Anaconda | kickstart (`ks.cfg`) | scx_rusty, scx_c_schedulers, sysbench, realtime-tests, fio, stress-ng, curl | 2048 MB | hypervisor default |
| `alma` | Anaconda | kickstart (`ks.cfg`) | realtime-tests, fio, stress-ng, curl | 2048 MB | `x86-64-v3` |
| `debian` | debian-installer | preseed (`preseed.cfg`) | rt-tests, fio, stress-ng, sysbench, curl | 1024 MB | hypervisor default |
| `ubuntu` | subiquity autoinstall | cloud-init NoCloud seed (`user-data`, `meta-data`) | rt-tests, fio, stress-ng, sysbench, curl | 8192 MB | hypervisor default |

Every install follows the same steps:
1. The VM is created **stopped** and its MAC is taken from the hypervisor.
2. The agent identity is minted with the same `plan_offline_install` the restore uses, and the host is enrolled
   with an install downtime.
3. The installer configuration is generated: static network, the corporate proxy for the package repository only,
   root locked, the agent port opened, and the package list. Every package is checked against the release's
   repositories before the VM exists; a missing one fails the dry run with its name.
4. The pxe container mirrors kernel, initrd and the installer payload (stage2 `install.img`, or the Ubuntu ISO)
   locally once per release, writes `pxelinux.cfg/01-<mac>` for exactly this MAC, and serves the configuration
   under a random path. Only then does it report the MAC ready, and Bossman starts the VM: a VM started at once
   PXE-booted before its boot entry existed and gave up.
5. One shared `finish.sh` runs at the end of each installer and puts the agent in place, fetched from the pxe
   container directly, never through the proxy.
6. The job is `done` the first time the new agent reports, so there is no installer callback. It is `failed` after
   two hours of silence.

Ubuntu needs 8 GB because its initramfs downloads the whole live-server ISO (2.93 GB for 26.04.1) into its root tmpfs, which is half the RAM: with 6 GB, wget stopped at 2.29 GB on both attempts (nginx log), and the installer sat idle with nothing written to disk. AlmaLinux 10 needs the CPU
model `x86-64-v3` (see below).

### Finalizing a deployment with a playbook

`deploy_vm(finalize_runbook=..., finalize_variables=..., finalize_apply=...)` and the wizard's Finalize step name a
stored runbook to run once the new host first reports (`services/finalize.py`, table `deploy_finalizations`). Its
states are `waiting`, `running`, `done` and `failed`, with a per-step summary. A role is refused (it is desired
state, bound with the role workflow, not run once), and an unknown name fails the dry run. `finalize_apply=false`
runs it in check mode. A model may let it apply only while YOLO mode is on; the dry run says so as the check
"finalization may apply". A person in the wizard may apply it, as with running a runbook by hand.

Found on the way, each measured and fixed:
- `PXE_INTERFACE=br-ens19` was a member-less bridge in state DOWN next to the real `ens19` that holds 192.0.2.130.
  dnsmasq ran and logged nothing, because no broadcast ever reached it. The entrypoint now uses the UP interface that
  carries `PXE_LISTEN_IP` and logs why.
- `PXE_LISTEN_IP` is missing from `docker-compose.override.yml`, so the compose placeholder 192.0.2.130 made nginx
  fail and the container exit.
- `inst.proxy` on the kernel line sent even the local kickstart request to the corporate proxy, and the installer
  never fetched it. Stage2 is now served locally and the kernel line has no proxy.
- `build-pe.sh` copied `vmlinuz-*` while the reused PE root held two kernels after a Debian point release, which
  failed with "target is not a directory". It now takes the newest kernel and its own initrd.
- `test_netboot_toggle_disables_checkin_even_with_a_db_secret` switched the shared, live netboot off on every run,
  and on failure left the repository's test secret live. Both netboot test paths now restore the previous values.

- A package missing from `%packages` makes the installer stop and ask in text mode. Measured: Fedora has no
  `scx-scheds` (it ships `scx_rusty`, `scx_layered`, `scx_rustland` and `scx_c_schedulers`), and the VM spun one CPU
  with no disk or network progress. `deploy_vm` now checks every package against the release and updates
  repositories before the VM exists, and the kickstart includes the updates repository.
- The IP check had picked as its probe a host that had never reported (the VM being installed), so every verdict
  became `unknown`. Only agents that have reported are used now, freshest first, with up to three tries.
- Three parallel installs exhausted the pxe container's DHCP range of two addresses: the third VM got
  "no address available" and never booted. Each MAC now gets the static address its deployment was checked for
  (`dhcp_hosts` in `/netboot/config`, `dhcp-host=<mac>,<ip>` in dnsmasq), so the range cannot run dry. A restore
  job, which has no address yet, keeps using the range.
- AlmaLinux 10 is built for x86-64-v3. Created without a CPU type, Proxmox gave the VM `kvm64`: the kernel booted
  and fetched `install.img` (285 MB), then the VM spun one core with zero bytes written to disk for 50 minutes.
  Each driver now names the CPU model it needs (`cpu_model`) and `vm_status` shows it. With `x86-64-v3` the same
  install wrote 865 MB within three minutes.
- A test (`test_poll_once_only_polls_enrolled_agents`) polled every enrolled agent in the shared database with a
  fake client and stamped each real host as seen, version `0.0.0-test`. A waiting Ubuntu install took that for its
  first report and was marked done, and the pxe container removed its seed and boot entry while the installer
  still needed them; the installer then waited for input. The test now polls only its own two agents.

`vm_status` (power state, net0 with VLAN tag, boot order, and the CPU, network and disk counters that tell a working
installer from a stuck one without a console), `vm_power` (start, stop, reset, shutdown) and `vm_delete` (only a VM
Bossman created, whose job names its vmid; all-hosts grant) made the diagnosis and the redeploy possible over MCP.

## The same deployment in the UI

Deploy → Install hosts lists every host Bossman installed, VM or bare metal, network install or golden-image restore, with the
install state, whether the new host's agent has reported, and the finalization playbook's outcome. A deployment a
model started over MCP appears there too, because both use the same service code.

"Install a host" opens the one install wizard (Disk images → New deployment opens it on its image). Its steps are
Target (a VM on a hypervisor, or bare metal by MAC; optionally from a saved template), Operating system (a network
install, or a golden image with this deployment's own volume sizing), Machine, Network (with the
bootstrap→production VLAN handoff for an image), Roles & playbook, Review (save as template) and Progress.
While a step is incomplete, Next stays disabled and the reason is shown next to it ("Choose a node", "Memory must be
at least 8192 MB", "This address is in use"). The operating-system step asks the mirror for the newest stable or LTS
release and pre-fills that release's default packages and minimum memory. Suggest and Check on the network step ask
Bossman's records, NetBox and a live ping/ARP from an agent in the subnet. The playbook field searches the stored
runbooks and refuses a name that does not exist. Review runs the dry run and lists every pre-flight check, and
Deploy unlocks only when all of them pass. Progress then polls the deployment every ten seconds.

The REST surface is `bossman/bossman/api/provision_deploy.py`. One difference from MCP is deliberate: a person in
the wizard may let the finalization apply without YOLO mode, as with running a runbook by hand, while a model needs
YOLO mode for that.

## A model deploys a host

`python -m bossman.tools.mcp_agent` lets any OpenAI-compatible model drive Bossman through its MCP server. The
model gets the operator guide plus a chosen subset of the tools, every call runs with a real API token (so the
ACL, the dry-run defaults and the refusals apply), and each step is logged as JSONL with its duration. No
`max_tokens` is sent, and thinking is off by default.

The console model is `qwen3.8-27b` at `https://llm.example.internal/qwen27b`, set through
`BOSSMAN_HERMES_WEB_BASE_URL` / `BOSSMAN_HERMES_WEB_MODEL`. It calls tools correctly, but slowly: about 16 prompt
tokens/s and 1.25 generated tokens/s. The full tool list is tens of thousands of tokens, so a probe gets the subset
its task needs.

**The probe (2026-10-18).** The model got nine tools (`suggest_free_ips`, `check_ip`, `deploy_vm`,
`deployment_status`, `vm_status`, `call_agent_tool`, `resource_plan`, `resource_apply`, `resource_rollback`) and
one goal: deploy a Fedora host, measure, tune readahead, measure again, roll back, report. It finished in 13 model
rounds and 14 minutes with no failed step:
- It took 192.0.2.139 from `suggest_free_ips` and confirmed it with `check_ip` (Bossman, NetBox and the live probe
  all empty).
- It read all ten checks of the dry run before deploying `kt-probe-01` (Fedora 44, done after 6 min 13 s).
- It followed the install with `deployment_status(wait_s=300)`: two calls instead of a poll loop. Before `wait_s`
  existed, it would have spent one round per poll.
- `blockdev_tuning:sda`: the plan showed readahead 8192 → 1024 KB, persistent through a udev rule. The apply
  recorded generation 1, `rollback(0)` recorded generation 2, and a final plan confirmed 8192 KB.
- fio `io_randread` gave 20,505 IOPS before and 21,090 after. The model itself called the +2.85 % noise for a single
  20-second run, and noted that readahead hardly matters for 4k direct reads. It reported that the tunable applies
  and reverts, not that it improves anything, which is the honesty block 5 asks for.

## Developer notes

- Code: `internal/kernelcaps/kernelcaps.go` with tests in `kernelcaps_test.go`. The roots (`ProcRoot`, `SysRoot`,
  `BootRoot`, `RunRoot`) can be injected, the same test seam as `internal/inventory`.
- Wiring: `internal/modules/setup.go` (field `Kernel`) and `internal/inventory/inventory.go` (field `Kernel`).
  `cmd/agentic-mcpd/main.go` calls `kernelcaps.SetCollectorStatus` from `startEBPFCollector`.
- Block 2: `Collector.SnapshotRunqLatency` (delta via `runqDelta`) and `Collector.SnapshotEventCounters` in
  `internal/ebpf/collector.go`. They are called from the collect loop in `cmd/agentic-mcpd/main.go`, next to
  `SnapshotConnCounters`.
- To add a config flag, append it to `kernelcaps.ConfigFlags`. Every flag in that list is always reported.
- Block 3: the modules are `internal/starmodules/embedded/modules/yoloman/{sched_ext,systemd_resource,blockdev_tuning,cpu_governor,kernel_cmdline}.{star,yaml}`, plus `scx_install` (builds scx; `TestScxInstall*` simulate the build unit and the links).
  Their logic is tested in `internal/starmodules/embedded/tunables_test.go` against `fakeHost`, an in-memory host
  (a map of files plus a command handler). `TestRollbackRestoresTheHostExactly` runs each module's reported
  rollback and requires the host to be identical afterwards. A new tunable module gets a case there.
- Block 4: a new tunable is one entry in `TUNABLES` (`services/resources/tunable.py`): module, identifying
  parameter, description. Tests: `bossman/tests/test_resource_tunable.py` (DB-backed, through the MCP tools).
