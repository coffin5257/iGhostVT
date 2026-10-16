package relay

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/owngoal-dev/iGhostVT/Relay/internal/protocol"
	"github.com/owngoal-dev/iGhostVT/Relay/internal/store"
)

const testSHA = "0000000000000000000000000000000000000000000000000000000000000000"

// dropSession opens an admitted drop session.
func (h *harness) dropSession() net.Conn {
	h.t.Helper()
	c, hello := h.control(protocol.Version)
	send(h.t, c, protocol.Request{
		Role: protocol.RoleDrop,
		Sig:  sign(h.t, h.member, protocol.SignedMessage(protocol.RoleDrop, h.id, hello.Nonce, "")),
	})
	var w protocol.DropWelcome
	readJSON(h.t, c, &w)
	if !w.OK {
		h.t.Fatal("the drop session was refused")
	}
	return c
}

func dropAnswer(t *testing.T, c net.Conn) protocol.DropAnswer {
	t.Helper()
	var a protocol.DropAnswer
	readJSON(t, c, &a)
	return a
}

func writeChunks(t *testing.T, c net.Conn, data []byte, chunk int) {
	t.Helper()
	for len(data) > 0 {
		n := min(chunk, len(data))
		var header [4]byte
		binary.BigEndian.PutUint32(header[:], uint32(n))
		if _, err := c.Write(append(header[:], data[:n]...)); err != nil {
			t.Fatal(err)
		}
		data = data[n:]
	}
}

func endChunks(t *testing.T, c net.Conn) {
	t.Helper()
	if _, err := c.Write([]byte{0, 0, 0, 0}); err != nil {
		t.Fatal(err)
	}
}

func (h *harness) putFile(c net.Conn, name string, data []byte) string {
	h.t.Helper()
	send(h.t, c, protocol.DropRequest{Op: protocol.DropPut, Name: name, Size: int64(len(data)), Mode: 0o644, Encoding: protocol.EncodingNone})
	a := dropAnswer(h.t, c)
	if !a.OK || a.ID == "" || a.Offset != 0 {
		h.t.Fatalf("put: %+v", a)
	}
	writeChunks(h.t, c, data, 64*1024)
	endChunks(h.t, c)
	send(h.t, c, protocol.DropRequest{Op: protocol.DropCommit, SHA256: testSHA})
	done := dropAnswer(h.t, c)
	if !done.OK || done.Stored != int64(len(data)) {
		h.t.Fatalf("commit: %+v", done)
	}
	return a.ID
}

func getFile(t *testing.T, c net.Conn, id string, offset int64) ([]byte, protocol.DropAnswer) {
	t.Helper()
	send(t, c, protocol.DropRequest{Op: protocol.DropGet, ID: id, Offset: offset})
	a := dropAnswer(t, c)
	if !a.OK {
		return nil, a
	}
	data := make([]byte, a.Stored-offset)
	if _, err := io.ReadFull(c, data); err != nil {
		t.Fatal(err)
	}
	return data, a
}

func listFiles(t *testing.T, c net.Conn) []protocol.DropEntry {
	t.Helper()
	send(t, c, protocol.DropRequest{Op: protocol.DropList})
	a := dropAnswer(t, c)
	if !a.OK {
		t.Fatalf("ls: %+v", a)
	}
	return a.Files
}

func randomBytes(t *testing.T, n int) []byte {
	t.Helper()
	b := make([]byte, n)
	rand.Read(b)
	return b
}

func TestDropNeedsTheRelayKey(t *testing.T) {
	h := start(t, fastLimits())
	c, hello := h.control(protocol.Version)
	send(t, c, protocol.Request{
		Role: protocol.RoleDrop,
		Sig:  sign(t, newKey(t), protocol.SignedMessage(protocol.RoleDrop, h.id, hello.Nonce, "")),
	})
	if a := answer(t, c); a.OK || a.Reason != protocol.ReasonAuth {
		t.Fatalf("%+v", a)
	}
	expectClosed(t, c)
}

func TestDropPutListGet(t *testing.T) {
	h := start(t, fastLimits())
	data := randomBytes(t, 3<<20+17)
	up := h.dropSession()
	id := h.putFile(up, "build log.txt", data)

	down := h.dropSession()
	files := listFiles(t, down)
	if len(files) != 1 {
		t.Fatalf("%+v", files)
	}
	f := files[0]
	if f.ID != id || f.Name != "build log.txt" || f.Size != int64(len(data)) || f.Stored != int64(len(data)) ||
		!f.Complete || f.SHA256 != testSHA || f.Mode != 0o644 || f.Expires != nil {
		t.Fatalf("%+v", f)
	}
	got, _ := getFile(t, down, id, 0)
	if !bytes.Equal(got, data) {
		t.Fatal("the file came back different")
	}
	tail, _ := getFile(t, down, id, 1000)
	if !bytes.Equal(tail, data[1000:]) {
		t.Fatal("a resumed get came back different")
	}
	// The session goes on after a download.
	if len(listFiles(t, down)) != 1 {
		t.Fatal("ls after get")
	}
	manifest, err := os.ReadFile(filepath.Join(h.dir.DropDir(), dropManifest))
	if err != nil || !bytes.Contains(manifest, []byte("build log.txt")) {
		t.Fatalf("manifest: %v %s", err, manifest)
	}
}

func TestDropResumeAfterACut(t *testing.T) {
	h := start(t, fastLimits())
	data := randomBytes(t, 1<<20)
	c := h.dropSession()
	send(t, c, protocol.DropRequest{Op: protocol.DropPut, Name: "a.bin", Size: int64(len(data)), Encoding: protocol.EncodingZstd})
	a := dropAnswer(t, c)
	writeChunks(t, c, data[:300000], 100000)
	// Half a chunk, then the link dies.
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], 100000)
	c.Write(append(header[:], data[300000:350000]...))
	time.Sleep(100 * time.Millisecond)
	c.Close()

	c2 := h.dropSession()
	var resumed protocol.DropAnswer
	waitFor(t, func() bool {
		send(t, c2, protocol.DropRequest{Op: protocol.DropPut, ID: a.ID})
		resumed = dropAnswer(t, c2)
		return resumed.OK || resumed.Reason != protocol.ReasonBusy
	})
	if !resumed.OK || resumed.Offset != 350000 {
		t.Fatalf("resume: %+v", resumed)
	}
	writeChunks(t, c2, data[350000:], 200000)
	endChunks(t, c2)
	send(t, c2, protocol.DropRequest{Op: protocol.DropCommit, SHA256: testSHA})
	if done := dropAnswer(t, c2); !done.OK || done.Stored != int64(len(data)) {
		t.Fatalf("%+v", done)
	}
	got, _ := getFile(t, c2, a.ID, 0)
	if !bytes.Equal(got, data) {
		t.Fatal("the resumed file came back different")
	}
	// A committed file takes no more parts.
	send(t, c2, protocol.DropRequest{Op: protocol.DropPut, ID: a.ID})
	if r := dropAnswer(t, c2); r.OK {
		t.Fatal("a committed file was reopened")
	}
}

func TestDropIncompleteAndBusy(t *testing.T) {
	h := start(t, fastLimits())
	up := h.dropSession()
	send(t, up, protocol.DropRequest{Op: protocol.DropPut, Name: "x", Size: 10, Encoding: protocol.EncodingNone})
	a := dropAnswer(t, up)
	writeChunks(t, up, []byte("hello"), 5)

	other := h.dropSession()
	if _, r := getFile(t, other, a.ID, 0); r.Reason != protocol.ReasonIncomplete {
		t.Fatalf("%+v", r)
	}
	send(t, other, protocol.DropRequest{Op: protocol.DropPut, ID: a.ID})
	if r := dropAnswer(t, other); r.Reason != protocol.ReasonBusy {
		t.Fatalf("%+v", r)
	}
	send(t, other, protocol.DropRequest{Op: protocol.DropRemove, ID: a.ID})
	if r := dropAnswer(t, other); r.Reason != protocol.ReasonBusy {
		t.Fatalf("%+v", r)
	}
	if _, r := getFile(t, other, "nope", 0); r.Reason != protocol.ReasonUnknown {
		t.Fatalf("%+v", r)
	}
}

// A file lives while a connection that put or got it is open, and DropTTL
// after the last one closed; listing it keeps nothing alive.
func TestDropExpiresAfterTheLastConnection(t *testing.T) {
	limits := fastLimits()
	limits.DropTTL = 400 * time.Millisecond
	h := start(t, limits)
	up := h.dropSession()
	id := h.putFile(up, "f", []byte("data"))

	// Held by the uploader: well past the TTL, still there.
	time.Sleep(600 * time.Millisecond)
	lister := h.dropSession()
	if files := listFiles(t, lister); len(files) != 1 || files[0].Expires != nil {
		t.Fatalf("%+v", files)
	}

	reader := h.dropSession()
	getFile(t, reader, id, 0)
	up.Close()
	// The reader still holds it.
	time.Sleep(600 * time.Millisecond)
	if len(listFiles(t, lister)) != 1 {
		t.Fatal("expired while a reader held it")
	}
	reader.Close()
	waitFor(t, func() bool {
		files := listFiles(t, lister)
		return len(files) == 1 && files[0].Expires != nil
	})
	// Listing again and again does not keep it.
	waitFor(t, func() bool { return len(listFiles(t, lister)) == 0 })
	if _, err := os.Stat(filepath.Join(h.dir.DropDir(), id)); !os.IsNotExist(err) {
		t.Fatalf("the blob is still there: %v", err)
	}
}

func TestDropLimits(t *testing.T) {
	limits := fastLimits()
	limits.DropFileBytes = 100
	limits.DropBytes = 150
	limits.DropFiles = 3 // one, the "two" refused for room (kept to resume), and two
	limits.DropReserve = 0
	h := start(t, limits)

	c := h.dropSession()
	send(t, c, protocol.DropRequest{Op: protocol.DropPut, Name: "big", Size: 1000, Encoding: protocol.EncodingNone})
	a := dropAnswer(t, c)
	writeChunks(t, c, make([]byte, 101), 101)
	if r := dropAnswer(t, c); r.Reason != protocol.ReasonSize {
		t.Fatalf("%+v", r)
	}
	expectClosed(t, c)
	// Too big ever to finish: gone at once.
	waitFor(t, func() bool { return len(listFiles(t, h.dropSession())) == 0 })
	_ = a

	c = h.dropSession()
	h.putFile(c, "one", make([]byte, 100))
	send(t, c, protocol.DropRequest{Op: protocol.DropPut, Name: "two", Size: 60, Encoding: protocol.EncodingNone})
	dropAnswer(t, c)
	writeChunks(t, c, make([]byte, 60), 60)
	if r := dropAnswer(t, c); r.Reason != protocol.ReasonFull {
		t.Fatalf("%+v", r)
	}

	c = h.dropSession()
	h.putFile(c, "two", make([]byte, 10))
	send(t, c, protocol.DropRequest{Op: protocol.DropPut, Name: "three", Encoding: protocol.EncodingNone})
	if r := dropAnswer(t, c); r.Reason != protocol.ReasonFull {
		t.Fatalf("files: %+v", r)
	}
}

func TestDropRefusesBadNames(t *testing.T) {
	h := start(t, fastLimits())
	c := h.dropSession()
	for _, name := range []string{"", ".", "..", "a/b", "a\\b", "evil\x1b[2J", "line\nbreak", "rtl\u202etxt.exe", string(make([]byte, 256))} {
		send(t, c, protocol.DropRequest{Op: protocol.DropPut, Name: name, Encoding: protocol.EncodingNone})
		if r := dropAnswer(t, c); r.Reason != protocol.ReasonInvalid {
			t.Fatalf("%q: %+v", name, r)
		}
	}
	send(t, c, protocol.DropRequest{Op: protocol.DropPut, Name: "ok", Encoding: "gzip"})
	if r := dropAnswer(t, c); r.Reason != protocol.ReasonInvalid {
		t.Fatalf("encoding: %+v", r)
	}
	send(t, c, protocol.DropRequest{Op: protocol.DropPut, Name: "ok", Mode: 0o4755, Encoding: protocol.EncodingNone})
	if r := dropAnswer(t, c); r.Reason != protocol.ReasonInvalid {
		t.Fatalf("mode: %+v", r)
	}
	if !protocol.ValidDropName("报告 2026.pdf") {
		t.Fatal("a plain name was refused")
	}
}

func TestDropOversizedChunkEndsTheSession(t *testing.T) {
	h := start(t, fastLimits())
	c := h.dropSession()
	send(t, c, protocol.DropRequest{Op: protocol.DropPut, Name: "x", Encoding: protocol.EncodingNone})
	dropAnswer(t, c)
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], protocol.MaxDropChunk+1)
	c.Write(header[:])
	if r := dropAnswer(t, c); r.Reason != protocol.ReasonInvalid {
		t.Fatalf("%+v", r)
	}
	expectClosed(t, c)
}

func TestDropRemove(t *testing.T) {
	h := start(t, fastLimits())
	c := h.dropSession()
	id := h.putFile(c, "f", []byte("abc"))
	send(t, c, protocol.DropRequest{Op: protocol.DropRemove, ID: id})
	if r := dropAnswer(t, c); !r.OK {
		t.Fatalf("%+v", r)
	}
	if len(listFiles(t, c)) != 0 {
		t.Fatal("still listed")
	}
	if st := h.s.Status(); !st.DropEnabled || st.DropFiles != 0 || st.DropBytes != 0 {
		t.Fatalf("%+v", st)
	}
}

func TestDropEmptiedOnStartAndStop(t *testing.T) {
	dir := store.Dir(t.TempDir())
	h := startIn(t, dir, fastLimits())
	h.putFile(h.dropSession(), "f", []byte("abc"))
	h.s.Close()
	if _, err := os.Stat(dir.DropDir()); !os.IsNotExist(err) {
		t.Fatalf("the drop zone outlived the relay: %v", err)
	}
	// One a crash left behind is emptied by the next start.
	os.MkdirAll(dir.DropDir(), 0o700)
	os.WriteFile(filepath.Join(dir.DropDir(), "left-over"), []byte("x"), 0o600)
	h2 := startIn(t, dir, fastLimits())
	if len(listFiles(t, h2.dropSession())) != 0 {
		t.Fatal("files from before the start")
	}
	if _, err := os.Stat(filepath.Join(dir.DropDir(), "left-over")); !os.IsNotExist(err) {
		t.Fatal("a left-over file survived the start")
	}
}

func TestDropOff(t *testing.T) {
	limits := fastLimits()
	limits.DropBytes = 0
	h := start(t, limits)
	c, hello := h.control(protocol.Version)
	send(t, c, protocol.Request{
		Role: protocol.RoleDrop,
		Sig:  sign(t, h.member, protocol.SignedMessage(protocol.RoleDrop, h.id, hello.Nonce, "")),
	})
	if a := answer(t, c); a.OK || a.Reason != protocol.ReasonInvalid {
		t.Fatalf("%+v", a)
	}
}

// The most files at the longest, most escaped names, with every other field
// at its widest, still list in one frame.
func TestDropListFitsOneFrame(t *testing.T) {
	limits := fastLimits()
	h := start(t, limits)
	c := h.dropSession()
	// `"` costs two bytes in JSON; `<` and `&` would cost six with HTML
	// escaping, and must cost one.
	names := []string{strings.Repeat("\"", 255), strings.Repeat("\"", 254) + "&", strings.Repeat("\"", 254) + "<"}
	for i := 0; i < limits.DropFiles; i++ {
		send(t, c, protocol.DropRequest{
			Op: protocol.DropPut, Name: names[i%len(names)], Size: 1 << 53, Mode: 0o777,
			Mtime: -protocol.MaxDropMtime + 1, Encoding: protocol.EncodingZstd,
			Fingerprint: strings.Repeat("z", protocol.MaxDropFingerprint),
		})
		if a := dropAnswer(t, c); !a.OK {
			t.Fatalf("%+v", a)
		}
		endChunks(t, c)
		send(t, c, protocol.DropRequest{Op: protocol.DropCommit, SHA256: testSHA})
		dropAnswer(t, c)
	}
	c.Close()
	lister := h.dropSession()
	var files []protocol.DropEntry
	waitFor(t, func() bool {
		files = listFiles(t, lister)
		return len(files) == limits.DropFiles && files[0].Expires != nil
	})
	for _, f := range files {
		if f.Name != names[0] && f.Name != names[1] && f.Name != names[2] {
			t.Fatalf("%q", f.Name)
		}
	}
}

func TestDropRefusesWideFields(t *testing.T) {
	h := start(t, fastLimits())
	c := h.dropSession()
	for _, r := range []protocol.DropRequest{
		{Name: "f", Mtime: protocol.MaxDropMtime + 1},
		{Name: "f", Fingerprint: "has\"quote"},
		{Name: "f", Fingerprint: "UPPER"},
		{Name: "f", Fingerprint: strings.Repeat("a", protocol.MaxDropFingerprint+1)},
	} {
		r.Op, r.Encoding = protocol.DropPut, protocol.EncodingNone
		send(t, c, r)
		if a := dropAnswer(t, c); a.Reason != protocol.ReasonInvalid {
			t.Fatalf("%+v: %+v", r, a)
		}
	}
}

// A key rotation ends drop sessions admitted under the old key.
func TestDropRotateEndsSessions(t *testing.T) {
	h := start(t, fastLimits())
	c := h.dropSession()
	if _, err := h.s.Rotate(); err != nil {
		t.Fatal(err)
	}
	expectClosed(t, c)
}

// A session past DropLife takes no new request, so it cannot hold its files
// forever by listing once a minute.
func TestDropSessionRetires(t *testing.T) {
	limits := fastLimits()
	limits.DropLife = 300 * time.Millisecond
	h := start(t, limits)
	c := h.dropSession()
	time.Sleep(400 * time.Millisecond)
	send(t, c, protocol.DropRequest{Op: protocol.DropList})
	expectClosed(t, c)
}

func TestDropFingerprint(t *testing.T) {
	h := start(t, fastLimits())
	c := h.dropSession()
	send(t, c, protocol.DropRequest{Op: protocol.DropPut, Name: "f", Encoding: protocol.EncodingNone, Fingerprint: "v1:z10507l3:abc"})
	if a := dropAnswer(t, c); !a.OK {
		t.Fatalf("%+v", a)
	}
	endChunks(t, c)
	send(t, c, protocol.DropRequest{Op: protocol.DropCommit, SHA256: testSHA})
	dropAnswer(t, c)
	if files := listFiles(t, c); files[0].Fingerprint != "v1:z10507l3:abc" {
		t.Fatalf("%+v", files)
	}
	send(t, c, protocol.DropRequest{Op: protocol.DropPut, Name: "f", Encoding: protocol.EncodingNone, Fingerprint: "has space"})
	if a := dropAnswer(t, c); a.Reason != protocol.ReasonInvalid {
		t.Fatalf("%+v", a)
	}
}
