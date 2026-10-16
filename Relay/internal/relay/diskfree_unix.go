//go:build linux || darwin

package relay

import "syscall"

// freeBytes is the space an unprivileged writer may still use under path.
func freeBytes(path string) (int64, bool) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, false
	}
	return int64(st.Bavail) * int64(st.Bsize), true
}
