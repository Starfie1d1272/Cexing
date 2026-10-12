package configpipeline

import (
	"context"
	"errors"
	"sync"
)

// Version stores provenance separately from generated YAML, in private storage.
// Path is immutable after staging and is the only path passed to the activator.
type Version struct{ ID, Path string }
type Snapshot struct{ Current, Previous *Version }

// Store must leave its last successful snapshot untouched on any error.
// Commit is one atomic switch. Stage does not change the current version.
// One coordinator must own a store; cross-process locking belongs to the host.
type Store interface {
	Load(context.Context) (Snapshot, error)
	Stage(context.Context, Result) (Version, error)
	Commit(context.Context, Snapshot) error
	Discard(context.Context, Version) error
}

// Activate may fail after partially changing the core. Restore must reapply the
// previous immutable version, or stop the candidate when previous is nil.
// Success must mean configuration application completed, not merely queued.
type Activator interface {
	Activate(context.Context, Version) error
	Restore(context.Context, *Version) error
}

var ErrStaleRevision = errors.New("stale active revision")

type Transaction struct {
	mu        sync.Mutex
	Compiler  Compiler
	Store     Store
	Activator Activator
}

// Failure exposes stage and rollback status only, never callback error strings.
type Failure struct {
	Stage          string
	RollbackFailed bool
}

func (e *Failure) Error() string {
	if e.RollbackFailed {
		return e.Stage + " failed; rollback failed (host recovery required)"
	}
	return e.Stage + " failed"
}

func (t *Transaction) Apply(ctx context.Context, r Request) (Result, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.Store == nil || t.Activator == nil {
		return Result{}, errors.New("store and activator are required")
	}
	prior, err := t.Store.Load(ctx)
	if err != nil {
		return Result{}, &Failure{Stage: "load"}
	}
	activeRevision := ""
	if prior.Current != nil {
		activeRevision = prior.Current.ID
	}
	if r.ExpectedActiveRevision != activeRevision {
		return Result{}, ErrStaleRevision
	}
	result, err := t.Compiler.Compile(ctx, r)
	if err != nil {
		return Result{}, err
	}
	candidate, err := t.Store.Stage(ctx, result)
	if err != nil {
		return Result{}, &Failure{Stage: "save"}
	}
	cleanup := context.WithoutCancel(ctx)
	if err := ctx.Err(); err != nil {
		_ = t.Store.Discard(cleanup, candidate)
		return Result{}, err
	}
	if err = t.Activator.Activate(ctx, candidate); err != nil {
		failed := t.Activator.Restore(cleanup, prior.Current) != nil
		// Keep a candidate needed for host recovery when rollback failed.
		if !failed {
			_ = t.Store.Discard(cleanup, candidate)
		}
		return Result{}, &Failure{Stage: "activate", RollbackFailed: failed}
	}
	if err = ctx.Err(); err == nil {
		err = t.Store.Commit(ctx, Snapshot{Current: &candidate, Previous: prior.Current})
	}
	if err != nil {
		failed := t.Activator.Restore(cleanup, prior.Current) != nil
		if !failed {
			_ = t.Store.Discard(cleanup, candidate)
		}
		return Result{}, &Failure{Stage: "commit", RollbackFailed: failed}
	}
	return result, nil
}
