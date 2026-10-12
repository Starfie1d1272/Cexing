package configpipeline

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// FileStore publishes a single atomic state.json pointer after core activation.
// Root must be an application-private directory. Failed transactions leave the
// prior pointer intact. No subscription/secret bytes appear in public paths.
type FileStore struct{ Root string }

func (s FileStore) valid(v *Version) bool {
	return v == nil || (strings.HasPrefix(v.ID, "version-") && filepath.Base(v.ID) == v.ID && v.Path == filepath.Join(s.Root, v.ID, "config.yaml"))
}
func (s FileStore) Load(ctx context.Context) (Snapshot, error) {
	if err := ctx.Err(); err != nil {
		return Snapshot{}, err
	}
	data, err := os.ReadFile(filepath.Join(s.Root, "state.json"))
	if os.IsNotExist(err) {
		return Snapshot{}, nil
	}
	if err != nil {
		return Snapshot{}, err
	}
	var state Snapshot
	if err := json.Unmarshal(data, &state); err != nil {
		return Snapshot{}, err
	}
	if !s.valid(state.Current) || !s.valid(state.Previous) {
		return Snapshot{}, errors.New("invalid version path")
	}
	for _, v := range []*Version{state.Current, state.Previous} {
		if v != nil {
			if _, err := os.Stat(v.Path); err != nil {
				return Snapshot{}, err
			}
		}
	}
	return state, nil
}
func (s FileStore) Stage(ctx context.Context, r Result) (Version, error) {
	if err := ctx.Err(); err != nil {
		return Version{}, err
	}
	if err := os.MkdirAll(s.Root, 0700); err != nil {
		return Version{}, err
	}
	dir, err := os.MkdirTemp(s.Root, "version-")
	if err != nil {
		return Version{}, err
	}
	complete := false
	defer func() {
		if !complete {
			_ = os.RemoveAll(dir)
		}
	}()
	provenance, err := json.Marshal(struct {
		Original []byte
		Overlays [][]byte
		Digest   string
	}{r.Original, r.Overlays, r.Digest})
	if err != nil {
		return Version{}, err
	}
	for _, file := range []struct {
		name string
		data []byte
	}{{"source.json", provenance}, {"config.yaml", r.YAML}} {
		if err := writeSync(filepath.Join(dir, file.name), file.data); err != nil {
			return Version{}, err
		}
	}
	if err := syncDir(dir); err != nil {
		return Version{}, err
	}
	if err := syncDir(s.Root); err != nil {
		return Version{}, err
	}
	complete = true
	return Version{ID: filepath.Base(dir), Path: filepath.Join(dir, "config.yaml")}, nil
}
func (s FileStore) Commit(ctx context.Context, state Snapshot) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if state.Current == nil || !s.valid(state.Current) || !s.valid(state.Previous) {
		return errors.New("invalid version")
	}
	for _, v := range []*Version{state.Current, state.Previous} {
		if v != nil {
			if info, err := os.Stat(v.Path); err != nil || !info.Mode().IsRegular() {
				return errors.New("missing staged version")
			}
		}
	}
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(s.Root, ".state-")
	if err != nil {
		return err
	}
	name := f.Name()
	_ = f.Close()
	defer os.Remove(name)
	if err := writeSync(name, data); err != nil {
		return err
	}
	// All fallible durability work happens before the atomic publication. A
	// post-rename fsync failure must not be reported as an uncommitted transaction.
	if err := syncDir(s.Root); err != nil {
		return err
	}
	if err := os.Rename(name, filepath.Join(s.Root, "state.json")); err != nil {
		return err
	}
	_ = syncDir(s.Root) // power-loss durability is filesystem/platform dependent
	return nil
}
func (s FileStore) Discard(ctx context.Context, v Version) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if !s.valid(&v) {
		return errors.New("invalid version")
	}
	state, err := s.Load(ctx)
	if err != nil {
		return err
	}
	for _, active := range []*Version{state.Current, state.Previous} {
		if active != nil && active.ID == v.ID {
			return errors.New("cannot discard successful version")
		}
	}
	return os.RemoveAll(filepath.Dir(v.Path))
}
func writeSync(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	return closeErr
}
func syncDir(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}
