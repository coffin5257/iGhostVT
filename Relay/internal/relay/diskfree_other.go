//go:build !linux && !darwin

package relay

// freeBytes cannot tell here; the drop zone's own limits still hold.
func freeBytes(string) (int64, bool) { return 0, false }
