package main

import (
	"context"
	"core/configpipeline"
	"encoding/json"
	"os"
	"path/filepath"
)

type storageReport struct {
	configpipeline.StorageUsage
	Complete bool   `json:"complete"`
	Code     string `json:"code,omitempty"`
}

func collectProfileVersions(ctx context.Context, store configpipeline.FileStore, prior configpipeline.Snapshot) storageReport {
	usage, err := store.Collect(ctx, prior, nil)
	report := storageReport{StorageUsage: usage, Complete: err == nil}
	if err != nil {
		report.Code = err.Error()
	}
	// Status contains only counts and fixed codes; it is never a configuration backup.
	if info, e := os.Lstat(store.Root); e == nil && info.IsDir() {
		if file, e := os.CreateTemp(store.Root, ".gc-status-"); e == nil {
			name := file.Name()
			defer os.Remove(name)
			data, _ := json.Marshal(report)
			_, e = file.Write(data)
			if e == nil {
				e = file.Sync()
			}
			closeErr := file.Close()
			if e == nil && closeErr == nil {
				e = os.Rename(name, filepath.Join(store.Root, "gc-status.json"))
			}
			if e != nil || closeErr != nil {
				report.Complete = false
				report.Code = "GC_STATUS_WRITE_FAILED"
			}
		} else {
			report.Complete = false
			report.Code = "GC_STATUS_WRITE_FAILED"
		}
	}
	return report
}
