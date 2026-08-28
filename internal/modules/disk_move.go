package modules

import (
	"context"
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// disk_move — move a partition's raw block range to a new offset on the SAME
// device, the way GParted does it (see ../gparted/src/CopyBlocks.cc):
//
//   - The copy is a plain block copy, so it is filesystem-AGNOSTIC as long as the
//     length is unchanged: a move is "the same bytes, somewhere else". Resizing a
//     filesystem is a separate operation (resize2fs et al.).
//   - Direction matters. When the destination lies AFTER the source the two
//     ranges overlap, and copying forwards would overwrite bytes that have not
//     been read yet. GParted solves this by negating its block size and starting
//     at the end (CopyBlocks.cc:106-112); we copy backwards for the same reason.
//   - A move is long-running, so it does NOT block the request: `start` returns a
//     job id immediately and the copy continues in a goroutine; `status` reports
//     progress. That is what makes it safe over a stateless API — a request
//     timeout can no longer kill a half-finished copy (the agent's `command`
//     module binds its child to the request context, which is exactly why a
//     dd-through-command approach was unsafe for this).
//   - On failure the copied region is NOT rolled back automatically; the reported
//     error names the ranges so the caller can restore from its table backup.
type DiskMove struct {
	jobs sync.Map // job id -> *moveJob
	seq  atomic.Uint64
}

func NewDiskMove() *DiskMove { return &DiskMove{} }

func (d *DiskMove) Name() string { return "disk_move" }

func (d *DiskMove) Description() string {
	return "" +
		"Move a partition's raw block range to a new offset on the same block device — the " +
		"copy half of a gparted-style 'Resize/Move'. Filesystem-agnostic: the same number of " +
		"bytes is copied to a new start, so any filesystem survives (resize the filesystem " +
		"separately if the size must change). Overlapping ranges are handled by copying " +
		"BACKWARDS when the destination lies after the source, so nothing is overwritten " +
		"before it is read. Long-running by nature, therefore asynchronous: action=start " +
		"returns a job id and copies in the background (a request timeout cannot kill it), " +
		"action=status reports {state, done_bytes, total_bytes, error}, action=cancel stops " +
		"it. The caller is responsible for having the partition UNMOUNTED and for rewriting " +
		"the partition table afterwards."
}

func (d *DiskMove) InputSchema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"action": map[string]any{
				"type":        "string",
				"enum":        []string{"start", "status", "cancel"},
				"description": "start a copy, poll its status, or cancel it",
			},
			"device":     map[string]any{"type": "string", "description": "block device, e.g. /dev/sdb"},
			"src_offset": map[string]any{"type": "integer", "description": "source start in BYTES"},
			"dst_offset": map[string]any{"type": "integer", "description": "destination start in BYTES"},
			"length":     map[string]any{"type": "integer", "description": "number of BYTES to copy"},
			"block_size": map[string]any{"type": "integer",
				"description": "copy buffer in bytes (default 4 MiB)"},
			"job_id": map[string]any{"type": "string", "description": "status/cancel: the id from start"},
		},
		"required": []string{"action"},
	}
}

// Writes reports that this module changes state (it writes to a block device).
func (d *DiskMove) Writes() bool { return true }

type moveJob struct {
	ID         string `json:"job_id"`
	Device     string `json:"device"`
	SrcOffset  int64  `json:"src_offset"`
	DstOffset  int64  `json:"dst_offset"`
	Length     int64  `json:"total_bytes"`
	Backwards  bool   `json:"backwards"`
	StartedAt  string `json:"started_at"`
	done       atomic.Int64
	state      atomic.Value // string: running | done | failed | cancelled
	errMsg     atomic.Value // string
	cancelFunc context.CancelFunc
}

func (j *moveJob) snapshot() map[string]any {
	state, _ := j.state.Load().(string)
	errMsg, _ := j.errMsg.Load().(string)
	done := j.done.Load()
	pct := 0.0
	if j.Length > 0 {
		pct = float64(done) / float64(j.Length) * 100
	}
	return map[string]any{
		"job_id": j.ID, "device": j.Device, "state": state,
		"src_offset": j.SrcOffset, "dst_offset": j.DstOffset,
		"total_bytes": j.Length, "done_bytes": done, "percent": pct,
		"backwards": j.Backwards, "started_at": j.StartedAt, "error": errMsg,
	}
}

func (d *DiskMove) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	action, err := stringParam(params, "action", true, "")
	if err != nil {
		return Result{}, err
	}
	switch action {
	case "status", "cancel":
		id, err := stringParam(params, "job_id", true, "")
		if err != nil {
			return Result{}, err
		}
		v, ok := d.jobs.Load(id)
		if !ok {
			return Result{}, fmt.Errorf("no such job %q", id)
		}
		job := v.(*moveJob)
		if action == "cancel" {
			if job.cancelFunc != nil {
				job.cancelFunc()
			}
		}
		return Result{Changed: false, Data: job.snapshot()}, nil
	case "start":
		return d.start(params, dryRunArg)
	}
	return Result{}, fmt.Errorf("action must be start|status|cancel, got %q", action)
}

func (d *DiskMove) start(params map[string]any, dryRun bool) (Result, error) {
	device, err := stringParam(params, "device", true, "")
	if err != nil {
		return Result{}, err
	}
	for _, k := range []string{"src_offset", "dst_offset", "length"} {
		if v, ok := params[k]; !ok || v == nil {
			return Result{}, fmt.Errorf("%s is required", k)
		}
	}
	src, err := intParam(params, "src_offset", 0)
	if err != nil {
		return Result{}, err
	}
	dst, err := intParam(params, "dst_offset", 0)
	if err != nil {
		return Result{}, err
	}
	length, err := intParam(params, "length", 0)
	if err != nil {
		return Result{}, err
	}
	blockSize, err := intParam(params, "block_size", 4<<20)
	if err != nil {
		return Result{}, err
	}
	if length <= 0 {
		return Result{}, fmt.Errorf("length must be positive")
	}
	if src < 0 || dst < 0 {
		return Result{}, fmt.Errorf("offsets must not be negative")
	}
	if blockSize <= 0 {
		blockSize = 4 << 20
	}
	if src == dst {
		return Result{Changed: false, Msg: "source and destination are identical — nothing to move"}, nil
	}
	// Copy backwards whenever the destination starts after the source: the ranges
	// may overlap, and a forward copy would clobber unread bytes (GParted does the
	// same by negating its block size and starting at the end).
	backwards := dst > src

	if dryRun {
		return Result{Changed: false, Msg: fmt.Sprintf(
			"would copy %d bytes on %s from offset %d to %d (%s)",
			length, device, src, dst, map[bool]string{true: "backwards", false: "forwards"}[backwards]),
		}, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	job := &moveJob{
		ID:     fmt.Sprintf("mv-%d-%d", time.Now().UnixNano()/1e6, d.seq.Add(1)),
		Device: device, SrcOffset: int64(src), DstOffset: int64(dst), Length: int64(length),
		Backwards: backwards, StartedAt: time.Now().UTC().Format(time.RFC3339),
		cancelFunc: cancel,
	}
	job.state.Store("running")
	job.errMsg.Store("")
	d.jobs.Store(job.ID, job)

	go func() {
		defer cancel()
		if err := copyRange(ctx, job, int64(blockSize)); err != nil {
			if ctx.Err() != nil {
				job.state.Store("cancelled")
			} else {
				job.state.Store("failed")
			}
			job.errMsg.Store(err.Error())
			return
		}
		job.state.Store("done")
	}()

	return Result{Changed: true, Msg: "copy started", Data: job.snapshot()}, nil
}

// copyRange does the actual block copy, forwards or backwards, on one open file
// handle for both reading and writing (the source and destination live on the
// same device). It fsyncs at the end so the data is on the platter before the
// caller rewrites the partition table.
func copyRange(ctx context.Context, job *moveJob, blockSize int64) error {
	f, err := os.OpenFile(job.Device, os.O_RDWR, 0)
	if err != nil {
		return fmt.Errorf("opening %s: %w", job.Device, err)
	}
	defer f.Close()

	buf := make([]byte, blockSize)
	remaining := job.Length
	for remaining > 0 {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("cancelled after %d of %d bytes", job.done.Load(), job.Length)
		}
		n := blockSize
		if n > remaining {
			n = remaining
		}
		// forwards: take from the front; backwards: take from the back
		var off int64
		if job.Backwards {
			off = remaining - n
		} else {
			off = job.Length - remaining
		}
		if _, err := f.ReadAt(buf[:n], job.SrcOffset+off); err != nil {
			return fmt.Errorf("reading %d bytes at %d: %w", n, job.SrcOffset+off, err)
		}
		if _, err := f.WriteAt(buf[:n], job.DstOffset+off); err != nil {
			return fmt.Errorf("writing %d bytes at %d: %w", n, job.DstOffset+off, err)
		}
		remaining -= n
		job.done.Add(n)
	}
	if err := f.Sync(); err != nil {
		return fmt.Errorf("syncing %s: %w", job.Device, err)
	}
	return nil
}
