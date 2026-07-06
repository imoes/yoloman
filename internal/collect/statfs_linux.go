package collect

import "syscall"

// defaultStatfs is statfsFunc backed by the real statfs(2) syscall — this
// project targets Linux exclusively (see docs/plan.md), so no cross-
// platform abstraction is needed here.
func defaultStatfs(mountPoint string) (usedPct float64, totalBytes, usedBytes uint64, err error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(mountPoint, &st); err != nil {
		return 0, 0, 0, err
	}
	blockSize := uint64(st.Bsize) //nolint:unconvert // Bsize's width varies by arch; explicit conversion is intentional
	total := st.Blocks * blockSize
	free := st.Bfree * blockSize
	if total == 0 {
		return 0, 0, 0, nil
	}
	used := total - free
	return float64(used) / float64(total) * 100, total, used, nil
}
