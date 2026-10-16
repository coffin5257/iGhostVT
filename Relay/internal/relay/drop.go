package relay

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/owngoal-dev/iGhostVT/Relay/internal/protocol"
)

// The drop zone: files a member puts on the relay for any other member to
// take, so a file crosses between two devices at the speed of a TCP stream
// instead of as text typed into a shell. The relay stores what the uploader
// sent (zstd, as the CLI sends it) under an id of its own making and never
// decodes it; the name and the rest live in the manifest beside it.
//
// A file is held while any connection that put or got it is still open, and
// goes DropTTL after the last of those closed. Listing holds nothing. The
// whole zone is emptied when the relay starts and when it stops: nothing in
// it survives the process.

const dropManifest = "manifest.json"

type dropFile struct {
	entry   protocol.DropEntry
	holders int       // connections that put or got it and are still open
	expires time.Time // zero while held
	writing bool      // a connection is uploading it now
}

type dropZone struct {
	dir    string
	limits Limits
	log    *log.Logger

	mu     sync.Mutex
	files  map[string]*dropFile
	stored int64 // every file's stored bytes together, reserved ones included
	// sessions are the open drop connections, so a key rotation and the
	// relay stopping can end them.
	sessions map[net.Conn]bool
	closed   bool
	stop     chan struct{}
	done     chan struct{}
}

// newDropZone empties dir and starts the sweeper. A zero DropBytes turns the
// zone off: nil, and the drop role is refused.
func newDropZone(dir string, limits Limits, logger *log.Logger) (*dropZone, error) {
	if limits.DropBytes <= 0 {
		return nil, nil
	}
	if err := os.RemoveAll(dir); err != nil {
		return nil, fmt.Errorf("could not empty the drop zone: %w", err)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	z := &dropZone{
		dir:      dir,
		limits:   limits,
		log:      logger,
		files:    map[string]*dropFile{},
		sessions: map[net.Conn]bool{},
		stop:     make(chan struct{}),
		done:     make(chan struct{}),
	}
	if err := z.saveManifestLocked(); err != nil {
		return nil, err
	}
	go z.sweep()
	return z, nil
}

// close stops the sweeper and removes every file. Connections still open
// write to files that are gone; nothing reads them again.
func (z *dropZone) close() {
	z.mu.Lock()
	if z.closed {
		z.mu.Unlock()
		return
	}
	z.closed = true
	close(z.stop)
	z.files = map[string]*dropFile{}
	z.stored = 0
	z.mu.Unlock()
	z.endSessions()
	<-z.done
	os.RemoveAll(z.dir)
}

// endSessions closes every open drop connection; each lets go of what it
// held as it ends.
func (z *dropZone) endSessions() {
	z.mu.Lock()
	conns := make([]net.Conn, 0, len(z.sessions))
	for c := range z.sessions {
		conns = append(conns, c)
	}
	z.mu.Unlock()
	for _, c := range conns {
		c.Close()
	}
}

func (z *dropZone) sweep() {
	defer close(z.done)
	interval := z.limits.DropTTL / 4
	interval = min(max(interval, 10*time.Millisecond), 10*time.Second)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-z.stop:
			return
		case now := <-ticker.C:
			z.expire(now)
		}
	}
}

func (z *dropZone) expire(now time.Time) {
	z.mu.Lock()
	defer z.mu.Unlock()
	changed := false
	for id, f := range z.files {
		if f.holders == 0 && !f.expires.IsZero() && !now.Before(f.expires) {
			z.removeLocked(id, f)
			changed = true
			z.log.Printf("drop: %s expired", id)
		}
	}
	if changed {
		z.saveManifestOrLog()
	}
}

// removeLocked forgets a file and unlinks its blob. A download already
// reading it keeps the inode, and its bytes, until it finishes; the zone
// stops counting them now, which DropReserve's free-disk check covers.
func (z *dropZone) removeLocked(id string, f *dropFile) {
	delete(z.files, id)
	z.stored -= f.entry.Stored
	os.Remove(z.blobPath(id))
}

func (z *dropZone) blobPath(id string) string { return filepath.Join(z.dir, id) }

// saveManifestLocked writes every file's entry, replaced by a rename. Only
// for whoever looks at the volume: the relay itself reads it never.
func (z *dropZone) saveManifestLocked() error {
	data, err := json.MarshalIndent(struct {
		Files []protocol.DropEntry `json:"files"`
	}{z.entriesLocked()}, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(z.dir, "."+dropManifest+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), filepath.Join(z.dir, dropManifest))
}

func (z *dropZone) saveManifestOrLog() {
	if z.closed {
		return
	}
	if err := z.saveManifestLocked(); err != nil {
		z.log.Printf("drop: could not write the manifest: %v", err)
	}
}

func (z *dropZone) entriesLocked() []protocol.DropEntry {
	entries := make([]protocol.DropEntry, 0, len(z.files))
	for _, f := range z.files {
		e := f.entry
		if f.holders == 0 && !f.expires.IsZero() {
			at := f.expires.Unix()
			e.Expires = &at
		}
		entries = append(entries, e)
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Created != entries[j].Created {
			return entries[i].Created < entries[j].Created
		}
		return entries[i].ID < entries[j].ID
	})
	return entries
}

// usage is the zone's file count and stored bytes, for `status`.
func (z *dropZone) usage() (files int, stored int64) {
	z.mu.Lock()
	defer z.mu.Unlock()
	return len(z.files), z.stored
}

func newDropID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// dropSession is one admitted connection: what it holds, and its stream.
type dropSession struct {
	z    *dropZone
	conn net.Conn
	held map[string]bool
	buf  []byte
}

// errDropClosed ends a session after its answer has been written.
var errDropClosed = errors.New("drop session closed")

// handleDrop admits a member to the drop zone and serves its requests until
// it closes, falls silent, or breaks the protocol.
func (s *Server) handleDrop(conn net.Conn, relayID, nonce string, req protocol.Request) {
	relayKey, gen := s.currentKey()
	if !protocol.Verify(relayKey, protocol.SignedMessage(protocol.RoleDrop, relayID, nonce, ""), req.Sig) {
		refuse(conn, protocol.ReasonAuth)
		return
	}
	z := s.drop
	if z == nil {
		refuse(conn, protocol.ReasonInvalid)
		return
	}
	z.mu.Lock()
	admitted := !z.closed && len(z.sessions) < z.limits.DropConns
	if admitted {
		z.sessions[conn] = true
	}
	z.mu.Unlock()
	if !admitted {
		refuse(conn, protocol.ReasonFull)
		return
	}
	session := &dropSession{z: z, conn: conn, held: map[string]bool{}}
	defer session.end()
	// A rotation that ran between the check and the line above ended the
	// sessions it could see, and not this one.
	if _, now := s.currentKey(); now != gen {
		session.fail(protocol.ReasonAuth)
		return
	}

	if err := session.write(protocol.DropWelcome{
		OK:         true,
		TTL:        int64(z.limits.DropTTL / time.Second),
		FileBytes:  z.limits.DropFileBytes,
		TotalBytes: z.limits.DropBytes,
	}); err != nil {
		return
	}
	// A session cannot keep its files forever by asking for the list once
	// a minute: past DropLife it takes no new request.
	retire := time.Now().Add(z.limits.DropLife)
	for {
		deadline := time.Now().Add(z.limits.DropIdle)
		if retire.Before(deadline) {
			deadline = retire
		}
		conn.SetReadDeadline(deadline)
		body, err := protocol.ReadFrame(conn)
		if err != nil {
			return
		}
		var r protocol.DropRequest
		if err := json.Unmarshal(body, &r); err != nil {
			session.fail(protocol.ReasonInvalid)
			return
		}
		switch r.Op {
		case protocol.DropList:
			err = session.list()
		case protocol.DropPut:
			err = session.put(r)
		case protocol.DropGet:
			err = session.get(r)
		case protocol.DropRemove:
			err = session.remove(r)
		default:
			session.fail(protocol.ReasonInvalid)
			return
		}
		if err != nil {
			return
		}
	}
}

func (d *dropSession) write(v any) error {
	d.conn.SetWriteDeadline(time.Now().Add(d.z.limits.DropIdle))
	return protocol.WriteDropFrame(d.conn, v)
}

// answer refuses one request and keeps the session.
func (d *dropSession) answer(reason string) error {
	return d.write(protocol.DropAnswer{OK: false, Reason: reason})
}

// fail refuses and ends the session: the stream is no longer where a frame
// begins. Mid-upload the client's chunk is still arriving; closing on unread
// bytes would answer with a reset that can overtake the refusal, so the
// write side closes first and what the client still sends is read away for
// a moment.
func (d *dropSession) fail(reason string) error {
	d.write(protocol.DropAnswer{OK: false, Reason: reason})
	if tcp, ok := d.conn.(*net.TCPConn); ok {
		tcp.CloseWrite()
		tcp.SetReadDeadline(time.Now().Add(2 * time.Second))
		io.Copy(io.Discard, io.LimitReader(tcp, 8<<20))
	}
	d.conn.Close()
	return errDropClosed
}

// end lets go of every file this connection held; a file no connection
// holds starts its clock.
func (d *dropSession) end() {
	d.conn.Close()
	z := d.z
	z.mu.Lock()
	defer z.mu.Unlock()
	delete(z.sessions, d.conn)
	expires := time.Now().Add(z.limits.DropTTL)
	changed := false
	for id := range d.held {
		f := z.files[id]
		if f == nil {
			continue
		}
		f.holders--
		if f.holders == 0 {
			f.expires = expires
			changed = true
		}
	}
	if changed {
		z.saveManifestOrLog()
	}
}

// holdLocked counts this connection as one of the file's holders, once.
func (d *dropSession) holdLocked(id string, f *dropFile) {
	if d.held[id] {
		return
	}
	d.held[id] = true
	f.holders++
	f.expires = time.Time{}
}

func (d *dropSession) list() error {
	d.z.mu.Lock()
	entries := d.z.entriesLocked()
	d.z.mu.Unlock()
	return d.write(protocol.DropAnswer{OK: true, Files: entries})
}

func (d *dropSession) remove(r protocol.DropRequest) error {
	z := d.z
	z.mu.Lock()
	f := z.files[r.ID]
	reason := ""
	switch {
	case f == nil:
		reason = protocol.ReasonUnknown
	case f.writing:
		reason = protocol.ReasonBusy
	default:
		z.removeLocked(r.ID, f)
		z.saveManifestOrLog()
	}
	z.mu.Unlock()
	if reason != "" {
		return d.answer(reason)
	}
	z.log.Printf("drop: %s removed", r.ID)
	return d.write(protocol.DropAnswer{OK: true, ID: r.ID})
}

// put starts a file, or resumes one whose upload was cut off, then reads
// its chunks to the end and the commit after them.
func (d *dropSession) put(r protocol.DropRequest) error {
	z := d.z
	var id string
	var file *os.File
	var reason string
	var offset int64

	if r.ID == "" {
		if !protocol.ValidDropName(r.Name) || r.Size < 0 || r.Size > 1<<53 || r.Mode > 0o777 ||
			r.Mtime > protocol.MaxDropMtime || r.Mtime < -protocol.MaxDropMtime ||
			(r.Encoding != protocol.EncodingZstd && r.Encoding != protocol.EncodingNone) ||
			!protocol.ValidFingerprint(r.Fingerprint) {
			return d.answer(protocol.ReasonInvalid)
		}
		if !z.hasRoom() {
			return d.answer(protocol.ReasonFull)
		}
		id = newDropID()
		f, err := os.OpenFile(z.blobPath(id), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			z.log.Printf("drop: could not create a file: %v", err)
			return d.answer(protocol.ReasonFull)
		}
		file = f
		z.mu.Lock()
		switch {
		case z.closed:
			reason = protocol.ReasonInvalid
		case len(z.files) >= z.limits.DropFiles:
			reason = protocol.ReasonFull
		default:
			entry := &dropFile{
				entry: protocol.DropEntry{
					ID:          id,
					Name:        r.Name,
					Size:        r.Size,
					Encoding:    r.Encoding,
					Mode:        r.Mode,
					Mtime:       r.Mtime,
					Created:     time.Now().Unix(),
					Fingerprint: r.Fingerprint,
				},
				writing: true,
			}
			z.files[id] = entry
			d.holdLocked(id, entry)
			z.saveManifestOrLog()
		}
		z.mu.Unlock()
		if reason != "" {
			file.Close()
			os.Remove(z.blobPath(id))
			return d.answer(reason)
		}
		z.log.Printf("drop: %s started (%d bytes declared)", id, r.Size)
	} else {
		id = r.ID
		z.mu.Lock()
		f := z.files[id]
		switch {
		case f == nil:
			reason = protocol.ReasonUnknown
		case f.writing:
			reason = protocol.ReasonBusy
		case f.entry.Complete:
			reason = protocol.ReasonInvalid
		default:
			f.writing = true
			offset = f.entry.Stored
			d.holdLocked(id, f)
		}
		z.mu.Unlock()
		if reason != "" {
			return d.answer(reason)
		}
		opened, err := os.OpenFile(z.blobPath(id), os.O_WRONLY, 0)
		if err == nil {
			// A chunk cut off mid-write left bytes past what was counted.
			if err = opened.Truncate(offset); err == nil {
				_, err = opened.Seek(offset, io.SeekStart)
			}
			if err != nil {
				opened.Close()
			}
		}
		if err != nil {
			z.log.Printf("drop: could not reopen %s: %v", id, err)
			d.stopWriting(id)
			return d.answer(protocol.ReasonUnknown)
		}
		file = opened
	}
	defer file.Close()
	defer d.stopWriting(id)

	if err := d.write(protocol.DropAnswer{OK: true, ID: id, Offset: offset}); err != nil {
		return err
	}
	if d.buf == nil {
		d.buf = make([]byte, 256*1024)
	}
	reader := &idleReader{conn: d.conn, idle: z.limits.DropIdle}
	for {
		d.conn.SetReadDeadline(time.Now().Add(z.limits.DropIdle))
		n, err := protocol.ReadChunkHeader(d.conn)
		if err != nil {
			return d.fail(protocol.ReasonInvalid)
		}
		if n == 0 {
			break
		}
		if reason := z.reserve(id, int64(n)); reason != "" {
			if reason == protocol.ReasonSize {
				// It can never be finished; nothing should wait for it.
				z.mu.Lock()
				if f := z.files[id]; f != nil {
					z.removeLocked(id, f)
					z.saveManifestOrLog()
				}
				z.mu.Unlock()
			}
			return d.fail(reason)
		}
		sink := &recordingWriter{w: file}
		written, _ := io.CopyBuffer(sink, io.LimitReader(reader, int64(n)), d.buf)
		if written < int64(n) {
			// What landed counts, and a resume truncates to it.
			z.unreserve(id, int64(n)-written)
			if sink.err != nil {
				// The disk, not the link: a resume would fail the same way.
				z.log.Printf("drop: could not write %s: %v", id, sink.err)
				return d.fail(protocol.ReasonFull)
			}
			return errDropClosed
		}
	}

	d.conn.SetReadDeadline(time.Now().Add(z.limits.DropIdle))
	body, err := protocol.ReadFrame(d.conn)
	if err != nil {
		return err
	}
	var commit protocol.DropRequest
	if json.Unmarshal(body, &commit) != nil || commit.Op != protocol.DropCommit || !protocol.ValidSHA256(commit.SHA256) {
		return d.fail(protocol.ReasonInvalid)
	}
	z.mu.Lock()
	f := z.files[id]
	var stored int64
	if f != nil {
		f.entry.Complete = true
		f.entry.SHA256 = commit.SHA256
		stored = f.entry.Stored
		z.saveManifestOrLog()
	}
	z.mu.Unlock()
	if f == nil {
		return d.fail(protocol.ReasonUnknown)
	}
	z.log.Printf("drop: %s committed (%d bytes stored)", id, stored)
	return d.write(protocol.DropAnswer{OK: true, ID: id, Stored: stored})
}

func (d *dropSession) stopWriting(id string) {
	d.z.mu.Lock()
	if f := d.z.files[id]; f != nil {
		f.writing = false
	}
	d.z.mu.Unlock()
}

// hasRoom is whether the disk keeps DropReserve free.
func (z *dropZone) hasRoom() bool {
	free, ok := freeBytes(z.dir)
	return !ok || free >= z.limits.DropReserve
}

// reserve counts n more bytes against the file and the zone before they
// are written; the reason they would not fit, otherwise.
func (z *dropZone) reserve(id string, n int64) string {
	if !z.hasRoom() {
		return protocol.ReasonFull
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	f := z.files[id]
	switch {
	case f == nil:
		return protocol.ReasonUnknown
	case f.entry.Stored > z.limits.DropFileBytes-n:
		return protocol.ReasonSize
	case z.stored > z.limits.DropBytes-n:
		return protocol.ReasonFull
	}
	f.entry.Stored += n
	z.stored += n
	return ""
}

func (z *dropZone) unreserve(id string, n int64) {
	z.mu.Lock()
	defer z.mu.Unlock()
	if f := z.files[id]; f != nil {
		f.entry.Stored -= n
		z.stored -= n
	}
}

// get sends a committed file from offset to its end.
func (d *dropSession) get(r protocol.DropRequest) error {
	z := d.z
	z.mu.Lock()
	f := z.files[r.ID]
	reason := ""
	var stored int64
	switch {
	case f == nil:
		reason = protocol.ReasonUnknown
	case !f.entry.Complete:
		reason = protocol.ReasonIncomplete
	case r.Offset < 0 || r.Offset > f.entry.Stored:
		reason = protocol.ReasonInvalid
	default:
		stored = f.entry.Stored
		d.holdLocked(r.ID, f)
	}
	z.mu.Unlock()
	if reason != "" {
		return d.answer(reason)
	}
	file, err := os.Open(z.blobPath(r.ID))
	if err != nil {
		return d.answer(protocol.ReasonUnknown)
	}
	defer file.Close()
	if _, err := file.Seek(r.Offset, io.SeekStart); err != nil {
		return d.answer(protocol.ReasonUnknown)
	}
	if err := d.write(protocol.DropAnswer{OK: true, ID: r.ID, Offset: r.Offset, Stored: stored}); err != nil {
		return err
	}
	// In slices, each with a fresh deadline: a slow link that keeps taking
	// bytes is never cut, and a dead one is cut a DropIdle after it stopped.
	// A slice is small enough to cross at about 1 KB/s within the deadline.
	// io.CopyN from a file to a TCP connection is sendfile on Linux.
	const slice = 64 << 10
	for left := stored - r.Offset; left > 0; {
		n := min(left, slice)
		d.conn.SetWriteDeadline(time.Now().Add(z.limits.DropIdle))
		written, err := io.CopyN(d.conn, file, n)
		left -= written
		if err != nil {
			return err
		}
	}
	return nil
}

// recordingWriter keeps the file's write error apart from the connection's
// read error, and hides the file's ReadFrom, which would ignore the
// session's buffer and copy through one of its own per chunk.
type recordingWriter struct {
	w   io.Writer
	err error
}

func (r *recordingWriter) Write(p []byte) (int, error) {
	n, err := r.w.Write(p)
	if err != nil {
		r.err = err
	}
	return n, err
}

// idleReader refreshes the read deadline before every read, so an upload
// is cut only after DropIdle of silence, never for being long.
type idleReader struct {
	conn net.Conn
	idle time.Duration
}

func (r *idleReader) Read(p []byte) (int, error) {
	r.conn.SetReadDeadline(time.Now().Add(r.idle))
	return r.conn.Read(p)
}
