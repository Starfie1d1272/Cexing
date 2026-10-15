package configpipeline

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"syscall"
)

var versionDirectory = regexp.MustCompile(`^version-[A-Za-z0-9_-]+$`)
var profileFile = regexp.MustCompile(`(?i)^[^/\\\x00-\x1f]{1,128}\.ya?ml$`)

type StorageUsage struct {
	Versions        int   `json:"versions"`
	Bytes           int64 `json:"bytes"`
	RemovedVersions int   `json:"removedVersions"`
	RemovedBytes    int64 `json:"removedBytes"`
}

type gcSource struct {
	Original        []byte
	Overlays        [][]byte
	Digest          string
	ProfileID       string
	Metadata        string
	SmartConversion bool
	RegionPlan      *RegionPlan
	GlobalMerge     string
	EditIntent      *EditIntent
	RegionChoice    *RegionChoice
}

func strictJSON(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if decoder.Decode(new(any)) != io.EOF {
		return errors.New("trailing data")
	}
	return nil
}

// Collect is called only under the host's single configuration gate/worker.
// Async readers must hold a read lease; candidates carry .pending until Publish.
// All references are validated before deleting anything. Unknown schema, files,
// pending transactions and leases fail closed. Pins are extra backup/rollback refs.
func (s FileStore) Collect(ctx context.Context, expected Snapshot, pins []Version) (StorageUsage, error) {
	usage := StorageUsage{}
	before, err := os.Lstat(s.Root)
	if err != nil || !before.IsDir() {
		return usage, errors.New("GC_ROOT_INVALID")
	}
	root, err := os.OpenRoot(s.Root)
	if err != nil {
		return usage, errors.New("GC_ROOT_INVALID")
	}
	defer root.Close()
	guard, err := lockGC(root, syscall.LOCK_EX)
	if err != nil {
		return usage, errors.New("GC_READER_BUSY")
	}
	defer guard.Close()
	opened, err := root.Stat(".")
	if err != nil || !os.SameFile(before, opened) {
		return usage, errors.New("GC_ROOT_INVALID")
	}
	raw, err := root.ReadFile("state.json")
	if err != nil {
		return usage, errors.New("GC_STATE_INVALID")
	}
	var state Snapshot
	if strictJSON(raw, &state) != nil || !reflect.DeepEqual(state, expected) {
		return usage, errors.New("GC_STATE_INVALID")
	}
	loaded, err := s.Load(ctx)
	if err != nil || !reflect.DeepEqual(state, loaded) {
		return usage, errors.New("GC_STATE_INVALID")
	}
	retained := map[string]bool{}
	keep := func(v *Version) bool {
		if v == nil {
			return true
		}
		if !s.valid(v) || !versionDirectory.MatchString(v.ID) {
			return false
		}
		retained[v.ID] = true
		return true
	}
	if !keep(state.Current) || !keep(state.Previous) {
		return usage, errors.New("GC_REFERENCE_INVALID")
	}
	for _, v := range state.Profiles {
		if !keep(&v) {
			return usage, errors.New("GC_REFERENCE_INVALID")
		}
	}
	for _, v := range pins {
		if !keep(&v) {
			return usage, errors.New("GC_REFERENCE_INVALID")
		}
	}
	if state.Current != nil && state.Profiles[state.Current.ProfileID].ID != state.Current.ID {
		return usage, errors.New("GC_REFERENCE_INVALID")
	}
	entries, err := fs.ReadDir(root.FS(), ".")
	if err != nil {
		return usage, errors.New("GC_READ_FAILED")
	}
	type candidate struct {
		name, id string
		info     os.FileInfo
		size     int64
		trash    bool
	}
	var candidates []candidate
	found := map[string]bool{}
	for _, entry := range entries {
		name := entry.Name()
		if name == "state.json" || name == "gc-status.json" || name == ".gc-lock" {
			info, e := root.Lstat(name)
			if e != nil || !info.Mode().IsRegular() {
				return usage, errors.New("GC_FILE_INVALID")
			}
			continue
		}
		if strings.HasPrefix(name, ".reader-") {
			return usage, errors.New("GC_READER_BUSY")
		}
		id := strings.TrimPrefix(name, ".gc-")
		trash := id != name
		if !versionDirectory.MatchString(id) {
			return usage, errors.New("GC_UNKNOWN_FILE")
		}
		info, e := root.Lstat(name)
		if e != nil || !info.IsDir() {
			return usage, errors.New("GC_FILE_INVALID")
		}
		if trash && retained[id] {
			return usage, errors.New("GC_REFERENCE_INVALID")
		}
		size, pending, e := inspectGCDirectory(root, name, trash)
		if e != nil {
			return usage, e
		}
		if pending && !retained[id] {
			return usage, errors.New("GC_CANDIDATE_BUSY")
		}
		found[id] = true
		usage.Versions++
		usage.Bytes += size
		if !retained[id] {
			candidates = append(candidates, candidate{name, id, info, size, trash})
		}
	}
	for id := range retained {
		if !found[id] {
			return usage, errors.New("GC_REFERENCE_INVALID")
		}
	}
	fence := func() error {
		if ctx.Err() != nil {
			return errors.New("GC_CANCELLED")
		}
		latest, e := root.ReadFile("state.json")
		if e != nil || !bytes.Equal(raw, latest) {
			return errors.New("GC_STALE")
		}
		// The marker is shared with ArkTS's runtime uncertainty gate.
		if _, e = os.Lstat(filepath.Join(filepath.Dir(s.Root), "profiles", "apply-uncertain.txt")); !os.IsNotExist(e) {
			return errors.New("GC_APPLY_UNKNOWN")
		}
		if _, e = os.Lstat(filepath.Join(filepath.Dir(s.Root), "profiles", "backup-restore.json")); !os.IsNotExist(e) {
			return errors.New("GC_RESTORE_BUSY")
		}
		return nil
	}
	if err = fence(); err != nil {
		return usage, err
	}
	for _, candidate := range candidates {
		if err = fence(); err != nil {
			return usage, err
		}
		current, e := root.Lstat(candidate.name)
		if e != nil || !os.SameFile(candidate.info, current) {
			return usage, errors.New("GC_IDENTITY_CHANGED")
		}
		name := candidate.name
		if !candidate.trash {
			name = ".gc-" + candidate.id
			if _, e = root.Lstat(name); !os.IsNotExist(e) {
				return usage, errors.New("GC_IDENTITY_CHANGED")
			}
			if e = root.Rename(candidate.name, name); e != nil {
				return usage, errors.New("GC_REMOVE_FAILED")
			}
		}
		// Quarantine resumes safely after interruption. Source metadata is removed
		// last, and an empty quarantined directory only needs rmdir.
		if _, _, e = inspectGCDirectory(root, name, true); e != nil {
			return usage, e
		}
		if err = fence(); err != nil {
			return usage, err
		}
		for _, file := range []string{"config.yaml", "original.yaml", "overlay.yaml", ".pending", "source.json"} {
			e = root.Remove(filepath.Join(name, file))
			if e != nil && !os.IsNotExist(e) {
				return usage, errors.New("GC_REMOVE_FAILED")
			}
		}
		if e = root.Remove(name); e != nil {
			return usage, errors.New("GC_REMOVE_FAILED")
		}
		usage.RemovedVersions++
		usage.RemovedBytes += candidate.size
	}
	usage.Versions -= usage.RemovedVersions
	usage.Bytes -= usage.RemovedBytes
	return usage, nil
}

func inspectGCDirectory(root *os.Root, name string, trash bool) (int64, bool, error) {
	dir, err := root.OpenRoot(name)
	if err != nil {
		return 0, false, errors.New("GC_FILE_INVALID")
	}
	defer dir.Close()
	entries, err := fs.ReadDir(dir.FS(), ".")
	if err != nil {
		return 0, false, errors.New("GC_READ_FAILED")
	}
	if trash && len(entries) == 0 {
		return 0, false, nil
	}
	files := map[string][]byte{}
	var size int64
	pending := false
	for _, entry := range entries {
		n := entry.Name()
		if n != "config.yaml" && n != "original.yaml" && n != "source.json" && n != "overlay.yaml" && n != ".pending" {
			return 0, false, errors.New("GC_UNKNOWN_FILE")
		}
		info, e := dir.Lstat(n)
		if e != nil || !info.Mode().IsRegular() || info.Size() > 64*1024*1024 {
			return 0, false, errors.New("GC_FILE_INVALID")
		}
		b, e := dir.ReadFile(n)
		if e != nil {
			return 0, false, errors.New("GC_READ_FAILED")
		}
		files[n] = b
		size += info.Size()
		if n == ".pending" {
			pending = true
		}
	}
	var source gcSource
	if strictJSON(files["source.json"], &source) != nil || !profileFile.MatchString(source.ProfileID) || len(source.Digest) != 64 || CheckEditIntent(source.EditIntent) != nil || CheckRegionChoice(source.RegionChoice) != nil {
		return 0, false, errors.New("GC_SOURCE_INVALID")
	}
	for _, n := range []string{"original.yaml", "config.yaml"} {
		if _, ok := files[n]; !trash && !ok {
			return 0, false, errors.New("GC_SOURCE_INVALID")
		}
	}
	if b, ok := files["original.yaml"]; ok && !bytes.Equal(b, source.Original) {
		return 0, false, errors.New("GC_SOURCE_INVALID")
	}
	if b, ok := files["config.yaml"]; ok {
		digest := sha256.Sum256(b)
		if hex.EncodeToString(digest[:]) != source.Digest {
			return 0, false, errors.New("GC_SOURCE_INVALID")
		}
	}
	if b, ok := files["overlay.yaml"]; ok && (len(source.Overlays) != 1 || !bytes.Equal(b, source.Overlays[0])) {
		return 0, false, errors.New("GC_SOURCE_INVALID")
	}
	return size, pending, nil
}

// Successful publication is already committed. Marker cleanup failure must not
// turn it into an apparent failed commit; it conservatively blocks later GC.
func (s FileStore) finishPublished(state Snapshot) {
	root, err := os.OpenRoot(s.Root)
	if err != nil {
		return
	}
	defer root.Close()
	ids := map[string]bool{}
	if state.Current != nil {
		ids[state.Current.ID] = true
	}
	if state.Previous != nil {
		ids[state.Previous.ID] = true
	}
	for _, v := range state.Profiles {
		ids[v.ID] = true
	}
	for id := range ids {
		info, e := root.Lstat(id)
		if e != nil || !info.IsDir() {
			continue
		}
		dir, e := root.OpenRoot(id)
		if e != nil {
			continue
		}
		actual, e := dir.Stat(".")
		if e == nil && os.SameFile(info, actual) {
			_ = dir.Remove(".pending")
		}
		_ = dir.Close()
	}
}

// Readers and collection coordinate across processes; a process crash releases
// the advisory lock. Mutation serialization remains the host worker's contract.
func lockGC(root *os.Root, mode int) (*os.File, error) {
	file, err := root.OpenFile(".gc-lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	info, err := root.Lstat(".gc-lock")
	actual, e := file.Stat()
	if err != nil || e != nil || !info.Mode().IsRegular() || info.Size() != 0 || !os.SameFile(info, actual) {
		file.Close()
		return nil, errors.New("invalid lock")
	}
	if err = syscall.Flock(int(file.Fd()), mode|syscall.LOCK_NB); err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}

// AcquireReadLease is required for a version held across asynchronous work.
// Failure means the caller retries without reading an unpinned stale version.
func (s FileStore) AcquireReadLease() (func(), error) {
	root, err := os.OpenRoot(s.Root)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	file, err := lockGC(root, syscall.LOCK_SH)
	if err != nil {
		return nil, err
	}
	return func() { _ = file.Close() }, nil
}
