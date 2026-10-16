package protocol

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"
)

// RoleDrop opens a drop zone session: a member puts files on the relay
// for any other member to take. PROTOCOL.md's "drop" section is the
// authority.
const RoleDrop = "drop"

// Drop zone operations, the `op` of every frame after the drop answer.
const (
	DropList   = "ls"
	DropPut    = "put"
	DropCommit = "commit"
	DropGet    = "get"
	DropRemove = "rm"
)

// Reasons a drop zone answer carries beyond the control protocol's.
const (
	ReasonUnknown    = "unknown"    // no file with that id
	ReasonIncomplete = "incomplete" // its upload has not been committed
	ReasonBusy       = "busy"       // another connection is uploading it
	ReasonSize       = "size"       // the file would pass the per-file limit
)

// Encodings a file may be stored in. The relay never decodes either: what
// it stores is what the uploader sent, and the downloader decodes.
const (
	EncodingZstd = "zstd"
	EncodingNone = "none"
)

// MaxDropChunk is the largest chunk of an upload's stream.
const MaxDropChunk = 1 << 20

// MaxDropName is the longest file name, in UTF-8 bytes.
const MaxDropName = 255

// DropRequest is one drop zone frame from the client; which fields matter
// depends on Op.
type DropRequest struct {
	Op       string `json:"op"`
	ID       string `json:"id,omitempty"`
	Name     string `json:"name,omitempty"`
	Size     int64  `json:"size,omitempty"`
	Mode     uint32 `json:"mode,omitempty"`
	Mtime    int64  `json:"mtime,omitempty"`
	Encoding string `json:"encoding,omitempty"`
	Offset   int64  `json:"offset,omitempty"`
	SHA256   string `json:"sha256,omitempty"`
	// Fingerprint is the uploader's own mark on the file it starts (lower-case
	// letters, digits and colons), kept
	// and listed but never read: what a client checks before it resumes
	// someone's partial upload as its own.
	Fingerprint string `json:"fingerprint,omitempty"`
}

// DropWelcome answers an admitted drop request.
type DropWelcome struct {
	OK         bool  `json:"ok"`
	TTL        int64 `json:"ttl"`        // seconds a file outlives its last connection
	FileBytes  int64 `json:"fileBytes"`  // the most one file may store
	TotalBytes int64 `json:"totalBytes"` // the most every file together may store
}

// DropEntry is a file's manifest row: everything about it but its bytes.
type DropEntry struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Size     int64  `json:"size"`   // the file's own size, as the uploader declared it
	Stored   int64  `json:"stored"` // bytes the relay holds, encoded
	Encoding string `json:"encoding"`
	Mode     uint32 `json:"mode"`
	Mtime    int64  `json:"mtime"`
	SHA256   string `json:"sha256,omitempty"` // of the decoded file; set at commit
	// Fingerprint is the uploader's, as it sent it with `put`.
	Fingerprint string `json:"fingerprint,omitempty"`
	Created     int64  `json:"created"`
	Complete    bool   `json:"complete"`
	// Expires is when the file goes, in Unix seconds; absent while a
	// connection that put or got it is still open.
	Expires *int64 `json:"expires,omitempty"`
}

// DropAnswer answers one drop zone frame.
type DropAnswer struct {
	OK     bool        `json:"ok"`
	Reason string      `json:"reason,omitempty"`
	ID     string      `json:"id,omitempty"`
	Offset int64       `json:"offset,omitempty"`
	Stored int64       `json:"stored,omitempty"`
	Files  []DropEntry `json:"files,omitempty"`
}

// WriteDropFrame writes v as one frame without HTML escaping: a name full
// of `<`, `>` and `&` would otherwise take six bytes for each, and an `ls`
// of the most files at the longest names must stay under MaxFrame.
func WriteDropFrame(w io.Writer, v any) error {
	var body bytes.Buffer
	body.Write([]byte{0, 0, 0, 0})
	encoder := json.NewEncoder(&body)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(v); err != nil {
		return err
	}
	frame := bytes.TrimSuffix(body.Bytes(), []byte("\n"))
	n := len(frame) - 4
	if n > MaxFrame {
		return fmt.Errorf("frame of %d bytes", n)
	}
	binary.BigEndian.PutUint32(frame, uint32(n))
	_, err := w.Write(frame)
	return err
}

// ReadChunkHeader reads an upload chunk's four length bytes. Zero ends the
// stream.
func ReadChunkHeader(r io.Reader) (int, error) {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return 0, err
	}
	n := binary.BigEndian.Uint32(header[:])
	if n > MaxDropChunk {
		return 0, fmt.Errorf("chunk of %d bytes", n)
	}
	return int(n), nil
}

// ValidDropName is a single path component a person could have typed: no
// separator, no control character, not `.` or `..`. The relay refuses
// anything else so no client is ever handed one; clients check again.
func ValidDropName(name string) bool {
	if name == "" || len(name) > MaxDropName || !utf8.ValidString(name) || name == "." || name == ".." {
		return false
	}
	if strings.ContainsAny(name, "/\\") {
		return false
	}
	for _, r := range name {
		// Controls, and the format characters that reorder or hide text:
		// a name printed in a terminal must read as what it is.
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) || r == '\u2028' || r == '\u2029' ||
			(r >= '\u200b' && r <= '\u200f') || (r >= '\u202a' && r <= '\u202e') ||
			(r >= '\u2066' && r <= '\u2069') || r == '\ufeff' {
			return false
		}
	}
	return true
}

// MaxDropFingerprint is the longest fingerprint, in bytes.
const MaxDropFingerprint = 128

// ValidFingerprint is lower-case letters, digits and colons,
// MaxDropFingerprint bytes at most: nothing JSON has to escape, so the
// longest `ls` stays within one frame.
func ValidFingerprint(s string) bool {
	if len(s) > MaxDropFingerprint {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c == ':') {
			return false
		}
	}
	return true
}

// MaxDropMtime bounds a modification time either side of the epoch: about
// 3,000 years, and never more digits than the frame budget counts on.
const MaxDropMtime = 1e11

// ValidSHA256 is 64 lower-case hex digits.
func ValidSHA256(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
