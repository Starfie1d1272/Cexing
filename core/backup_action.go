package main

import (
	"bytes"
	"context"
	"core/configpipeline"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"
)

type backupSubValidity struct {
	Upload    bool    `json:"upload"`
	Download  bool    `json:"download"`
	Total     bool    `json:"total"`
	Expire    bool    `json:"expire"`
	Header    string  `json:"header"`
	FetchedAt float64 `json:"fetchedAt"`
}

const maxBackupBytes = 64 * 1024 * 1024

var backupFilePattern = regexp.MustCompile(`^backup-(import|export)-[A-Za-z0-9_-]+\.json$`)
var backupTokenPattern = regexp.MustCompile(`^restore-[A-Za-z0-9_-]+$`)

type portableSettings struct {
	KeepAlive               bool     `json:"keepAlive"`
	IPv6                    bool     `json:"ipv6"`
	LogLevel                string   `json:"logLevel"`
	MixedPort               int      `json:"mixedPort"`
	AccessMode              string   `json:"accessMode"`
	AccessList              []string `json:"accessList"`
	MainGroup               string   `json:"mainGroup"`
	Mode                    string   `json:"mode"`
	AutoUpdate              bool     `json:"autoUpdate"`
	AutoUpdateIntervalHours float64  `json:"autoUpdateIntervalHours"`
	AutoRestore             bool     `json:"autoRestore"`
	LogToFile               bool     `json:"logToFile"`
	SmartAutoConvert        bool     `json:"smartAutoConvert"`
}
type backupProfile struct {
	Name       string                     `json:"name"`
	Original   string                     `json:"original"`
	Overlay    string                     `json:"overlay"`
	Metadata   json.RawMessage            `json:"metadata"`
	RegionPlan *configpipeline.RegionPlan `json:"regionPlan,omitempty"`
	EditIntent *configpipeline.EditIntent `json:"editIntent,omitempty"`
}
type backupManifest struct {
	SchemaVersion int              `json:"schemaVersion"`
	Preferences   portableSettings `json:"preferences"`
	GlobalMerge   string           `json:"globalMerge"`
	Active        string           `json:"active"`
	Profiles      []backupProfile  `json:"profiles"`
}
type backupName struct {
	From string `json:"from"`
	To   string `json:"to"`
}
type backupFingerprint struct{ Config, Original, Source, Overlay string }

type backupPlan struct {
	SchemaVersion int
	Prior         configpipeline.Snapshot
	Target        configpipeline.Snapshot
	Preferences   portableSettings
	AllowLan      bool
	Versions      []configpipeline.Version
	Fingerprints  []backupFingerprint
	Receipts      []string
	Names         []backupName
}
type backupJournal struct {
	SchemaVersion int              `json:"schemaVersion"`
	Committed     bool             `json:"committed,omitempty"`
	Owner         string           `json:"owner"`
	Token         string           `json:"token"`
	PriorJSON     string           `json:"priorJSON"`
	TargetJSON    string           `json:"targetJSON"`
	Old           portableSettings `json:"old"`
	New           portableSettings `json:"new"`
}
type backupResponse struct {
	File          string            `json:"file,omitempty"`
	Token         string            `json:"token,omitempty"`
	Profiles      int               `json:"profiles"`
	Names         []backupName      `json:"names"`
	GlobalChanged bool              `json:"globalChanged,omitempty"`
	Preferences   *portableSettings `json:"preferences,omitempty"`
	Outcome       string            `json:"outcome,omitempty"`
}

func decodeBackupJSON(data []byte, target any) error {
	if !utf8.Valid(data) {
		return errors.New("BACKUP_INVALID")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(target) != nil || decoder.Decode(new(any)) != io.EOF {
		return errors.New("BACKUP_INVALID")
	}
	return nil
}
func validPortable(p portableSettings) bool {
	if p.AccessList == nil || strings.ContainsAny(p.MainGroup, "\r\n\x00") || p.MixedPort < 1 || p.MixedPort > 65535 || math.IsNaN(p.AutoUpdateIntervalHours) || math.IsInf(p.AutoUpdateIntervalHours, 0) || p.AutoUpdateIntervalHours < 1 || p.AutoUpdateIntervalHours > 8760 || len(p.AccessList) > 64 || len(p.MainGroup) > 1024 {
		return false
	}
	if p.AccessMode != "all" && p.AccessMode != "white" && p.AccessMode != "black" {
		return false
	}
	if p.Mode != "" && p.Mode != "rule" && p.Mode != "global" && p.Mode != "direct" {
		return false
	}
	if p.LogLevel != "silent" && p.LogLevel != "error" && p.LogLevel != "warning" && p.LogLevel != "info" && p.LogLevel != "debug" {
		return false
	}
	for _, name := range p.AccessList {
		if len(name) == 0 || len(name) > 255 || strings.ContainsAny(name, "\r\n\x00") {
			return false
		}
	}
	return true
}
func backupOverrides(p portableSettings, lan bool) string {
	data, _ := json.Marshal(map[string]any{"mixedPort": p.MixedPort, "logLevel": p.LogLevel, "allowLan": lan, "ipv6": p.IPv6, "mode": p.Mode, "logToFile": p.LogToFile})
	return string(data)
}
func backupRoot(home string) (*os.Root, error) {
	path := filepath.Join(home, "backups")
	if err := os.MkdirAll(path, 0700); err != nil {
		return nil, errors.New("BACKUP_IO")
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() {
		return nil, errors.New("BACKUP_IO")
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		return nil, errors.New("BACKUP_IO")
	}
	actual, err := root.Stat(".")
	if err != nil || !os.SameFile(info, actual) {
		root.Close()
		return nil, errors.New("BACKUP_IO")
	}
	return root, nil
}
func backupRead(root *os.Root, name string, limit int64) ([]byte, error) {
	if directory := filepath.Dir(name); directory != "." {
		info, e := root.Lstat(directory)
		if e != nil || !info.IsDir() {
			return nil, errors.New("BACKUP_INVALID")
		}
	}
	info, err := root.Lstat(name)
	if err != nil || !info.Mode().IsRegular() || info.Size() > limit {
		return nil, errors.New("BACKUP_INVALID")
	}
	file, err := root.Open(name)
	if err != nil {
		return nil, errors.New("BACKUP_IO")
	}
	defer file.Close()
	actual, e := file.Stat()
	if e != nil || !os.SameFile(info, actual) {
		return nil, errors.New("BACKUP_INVALID")
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || int64(len(data)) > limit {
		return nil, errors.New("BACKUP_LIMIT")
	}
	return data, nil
}
func syncBackupDirectory(path string) error {
	directory, e := os.Open(path)
	if e != nil {
		return errors.New("BACKUP_IO")
	}
	defer directory.Close()
	if directory.Sync() != nil {
		return errors.New("BACKUP_IO")
	}
	return nil
}
func writeBackupJSON(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil || len(data) > maxBackupBytes {
		return errors.New("BACKUP_LIMIT")
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".backup-")
	if err != nil {
		return errors.New("BACKUP_IO")
	}
	name := file.Name()
	defer os.Remove(name)
	n, err := file.Write(data)
	if err == nil && n != len(data) {
		err = io.ErrShortWrite
	}
	if err == nil {
		err = file.Sync()
	}
	closed := file.Close()
	if err != nil || closed != nil {
		return errors.New("BACKUP_IO")
	}
	if os.Rename(name, path) != nil {
		return errors.New("BACKUP_IO")
	}
	return syncBackupDirectory(filepath.Dir(path))
}
func validBackupProfile(p backupProfile) bool {
	if !profileIDPattern.MatchString(p.Name) || len(p.Original) > 15*1024*1024 || len(p.Overlay) > maxConfigBytes || len(p.Metadata) > 64*1024 || configpipeline.CheckEditIntent(p.EditIntent) != nil {
		return false
	}
	if _, err := configpipeline.LayeredMergeSource([]byte(p.Original), nil, []byte(p.Overlay)); err != nil {
		return false
	}
	var meta struct {
		Origin string `json:"origin"`
		Sub    struct {
			Upload, Download, Total, Expire float64
			Validity                        *backupSubValidity `json:"validity,omitempty"`
		} `json:"sub"`
		UpdatedAt float64 `json:"updatedAt"`
	}
	if decodeBackupJSON(p.Metadata, &meta) != nil {
		return false
	}
	for _, v := range []float64{meta.Sub.Upload, meta.Sub.Download, meta.Sub.Total, meta.Sub.Expire, meta.UpdatedAt} {
		if math.IsNaN(v) || math.IsInf(v, 0) || v < 0 {
			return false
		}
	}
	if v := meta.Sub.Validity; v != nil {
		if math.IsNaN(v.FetchedAt) || math.IsInf(v.FetchedAt, 0) || v.FetchedAt < 0 || v.FetchedAt > 8640000000000 || math.Trunc(v.FetchedAt) != v.FetchedAt {
			return false
		}
		any := v.Upload || v.Download || v.Total || v.Expire
		switch v.Header {
		case "present":
			if !any {
				return false
			}
		case "missing", "invalid":
			if any || v.FetchedAt != 0 {
				return false
			}
		default:
			return false
		}
		for _, field := range []struct {
			value float64
			known bool
			limit float64
		}{
			{meta.Sub.Upload, v.Upload, 9007199254740991}, {meta.Sub.Download, v.Download, 9007199254740991},
			{meta.Sub.Total, v.Total, 9007199254740991}, {meta.Sub.Expire, v.Expire, 8640000000000},
		} {
			if field.known && (field.value > field.limit || math.Trunc(field.value) != field.value) {
				return false
			}
		}
	}
	return true
}
func backupManifestFromStore(home string, prior configpipeline.Snapshot, prefs portableSettings) (backupManifest, error) {
	result := backupManifest{SchemaVersion: 1, Preferences: prefs, GlobalMerge: prior.GlobalMerge, Profiles: []backupProfile{}}
	if prior.Current != nil {
		result.Active = prior.Current.ProfileID
	}
	names := map[string]bool{}
	for name := range prior.Profiles {
		names[name] = true
	}
	profileDir := filepath.Join(home, "profiles")
	if info, e := os.Lstat(profileDir); e == nil && !info.IsDir() {
		return result, errors.New("BACKUP_SOURCE_INVALID")
	}
	var legacyMeta map[string]json.RawMessage
	if entries, err := os.ReadDir(profileDir); err == nil {
		for _, entry := range entries {
			if profileIDPattern.MatchString(entry.Name()) {
				if !entry.Type().IsRegular() {
					return result, errors.New("BACKUP_SOURCE_INVALID")
				}
				names[entry.Name()] = true
			}
		}
		metaRoot, rootErr := os.OpenRoot(profileDir)
		if rootErr != nil {
			return result, errors.New("BACKUP_IO")
		}
		defer metaRoot.Close()
		if raw, err := backupRead(metaRoot, "meta.json", 2*1024*1024); err == nil {
			if decodeBackupJSON(raw, &legacyMeta) != nil {
				return result, errors.New("BACKUP_SOURCE_INVALID")
			}
		} else if fileExists(filepath.Join(profileDir, "meta.json")) {
			return result, errors.New("BACKUP_IO")
		}
	} else if !os.IsNotExist(err) {
		return result, errors.New("BACKUP_IO")
	}
	if len(names) > 128 {
		return result, errors.New("BACKUP_LIMIT")
	}
	ordered := make([]string, 0, len(names))
	for name := range names {
		ordered = append(ordered, name)
	}
	sort.Strings(ordered)
	used := 0
	for _, name := range ordered {
		p := backupProfile{Name: name, Metadata: json.RawMessage(`{"origin":"","sub":{"upload":0,"download":0,"total":0,"expire":0},"updatedAt":0}`)}
		if v, ok := prior.Profiles[name]; ok {
			info, e := os.Lstat(filepath.Dir(v.Path))
			if e != nil || !info.IsDir() {
				return result, errors.New("BACKUP_SOURCE_INVALID")
			}
			root, err := os.OpenRoot(filepath.Dir(v.Path))
			if err != nil {
				return result, errors.New("BACKUP_SOURCE_INVALID")
			}
			raw, e := backupRead(root, "source.json", 64*1024*1024)
			if e != nil {
				root.Close()
				return result, e
			}
			original, oe := backupRead(root, "original.yaml", 15*1024*1024)
			generated, ge := backupRead(root, "config.yaml", maxConfigBytes)
			root.Close()
			if oe != nil || ge != nil {
				return result, errors.New("BACKUP_SOURCE_INVALID")
			}
			if e != nil {
				return result, e
			}
			var source struct {
				Original                    []byte
				Overlays                    [][]byte
				Digest, ProfileID, Metadata string
				SmartConversion             bool
				RegionPlan                  *configpipeline.RegionPlan
				GlobalMerge                 string
				EditIntent                  *configpipeline.EditIntent
				RegionChoice                *configpipeline.RegionChoice
			}
			if decodeBackupJSON(raw, &source) != nil || !profileIDPattern.MatchString(source.ProfileID) || len(source.Overlays) > 1 || configpipeline.CheckRegionChoice(source.RegionChoice) != nil {
				return result, errors.New("BACKUP_SOURCE_INVALID")
			}
			sum := sha256.Sum256(generated)
			if !bytes.Equal(original, source.Original) || hex.EncodeToString(sum[:]) != source.Digest {
				return result, errors.New("BACKUP_SOURCE_INVALID")
			}
			p.Original = string(source.Original)
			if len(source.Overlays) > 0 {
				p.Overlay = string(source.Overlays[0])
			}
			p.Metadata = json.RawMessage(source.Metadata)
			p.RegionPlan = source.RegionPlan
			p.EditIntent = source.EditIntent
		} else {
			root, err := os.OpenRoot(profileDir)
			if err != nil {
				return result, errors.New("BACKUP_IO")
			}
			raw, e := backupRead(root, name, 15*1024*1024)
			if e != nil {
				root.Close()
				return result, e
			}
			p.Original = string(raw)
			if meta, ok := legacyMeta[name]; ok {
				p.Metadata = meta
			} else if raw, e = backupRead(root, name+".url", 64*1024); e == nil {
				m := map[string]any{"origin": strings.TrimSpace(string(raw)), "sub": map[string]int{"upload": 0, "download": 0, "total": 0, "expire": 0}, "updatedAt": 0}
				p.Metadata, _ = json.Marshal(m)
			} else if fileExists(filepath.Join(profileDir, name+".url")) {
				root.Close()
				return result, errors.New("BACKUP_SOURCE_INVALID")
			}
			if raw, e = backupRead(root, name+".merge.json", maxConfigBytes+1024); e == nil {
				var merge struct {
					Dialect, SourceVersion, Content string
					Enabled                         bool
				}
				if decodeBackupJSON(raw, &merge) != nil || merge.Dialect != "clash-verge-merge-2.5.8" {
					root.Close()
					return result, errors.New("BACKUP_SOURCE_INVALID")
				}
				if merge.Enabled {
					p.Overlay = merge.Content
				}
			} else if fileExists(filepath.Join(profileDir, name+".merge.json")) {
				root.Close()
				return result, errors.New("BACKUP_SOURCE_INVALID")
			}
			root.Close()
		}
		if !validBackupProfile(p) {
			return result, errors.New("BACKUP_SOURCE_INVALID")
		}
		used += len(p.Original) + len(p.Overlay) + len(p.Metadata)
		if used > maxBackupBytes/2 {
			return result, errors.New("BACKUP_LIMIT")
		}
		result.Profiles = append(result.Profiles, p)
	}
	return result, nil
}
func fingerprintBackupVersion(v configpipeline.Version) (backupFingerprint, error) {
	var out backupFingerprint
	info, e := os.Lstat(filepath.Dir(v.Path))
	if e != nil || !info.IsDir() {
		return out, errors.New("BACKUP_VERIFY_FAILED")
	}
	root, e := os.OpenRoot(filepath.Dir(v.Path))
	if e != nil {
		return out, errors.New("BACKUP_VERIFY_FAILED")
	}
	defer root.Close()
	for _, item := range []struct {
		name  string
		limit int64
		value *string
	}{{"config.yaml", maxConfigBytes, &out.Config}, {"original.yaml", 15 * 1024 * 1024, &out.Original}, {"source.json", maxBackupBytes, &out.Source}, {"overlay.yaml", maxConfigBytes, &out.Overlay}} {
		if item.name == "overlay.yaml" {
			if _, e := root.Lstat(item.name); os.IsNotExist(e) {
				*item.value = "absent"
				continue
			}
		}
		data, e := backupRead(root, item.name, item.limit)
		if e != nil {
			return out, errors.New("BACKUP_VERIFY_FAILED")
		}
		sum := sha256.Sum256(data)
		*item.value = hex.EncodeToString(sum[:])
	}
	return out, nil
}
func backupSnapshotOutcome(actual, prior, target string, committed bool) string {
	if actual == target && (actual != prior || committed) {
		return "committed"
	}
	if actual == prior {
		return "prior"
	}
	return "unknown"
}
func loadBackupPlan(root *os.Root, token string) (backupPlan, error) {
	var plan backupPlan
	if !backupTokenPattern.MatchString(token) {
		return plan, errors.New("BACKUP_INVALID")
	}
	raw, err := backupRead(root, token+"/plan.json", 2*1024*1024)
	if err != nil || decodeBackupJSON(raw, &plan) != nil || plan.SchemaVersion != 1 || !validPortable(plan.Preferences) || len(plan.Versions) != len(plan.Fingerprints) || len(plan.Versions) != len(plan.Receipts) || len(plan.Versions) > 128 {
		return plan, errors.New("BACKUP_INVALID")
	}
	for _, v := range plan.Versions {
		if !strings.HasPrefix(v.ID, "version-") || filepath.Base(v.ID) != v.ID || !profileIDPattern.MatchString(v.ProfileID) ||
			v.Path != filepath.Join(filepath.Dir(root.Name()), "profile-versions", v.ID, "config.yaml") || plan.Target.Profiles[v.ProfileID].ID != v.ID {
			return backupPlan{}, errors.New("BACKUP_INVALID")
		}
	}
	return plan, nil
}
func executeBackupAction(home string, store configpipeline.FileStore, prior configpipeline.Snapshot, a versionAction) (versionResponse, error) {
	if err := os.MkdirAll(store.Root, 0700); err != nil {
		return versionResponse{}, errors.New("BACKUP_IO")
	}
	release, err := store.AcquireReadLease()
	if err != nil {
		return versionResponse{}, errors.New("BACKUP_IO")
	}
	defer release()
	root, err := backupRoot(home)
	if err != nil {
		return versionResponse{}, err
	}
	defer root.Close()
	response := func(b backupResponse) (versionResponse, error) { return versionResponse{Backup: &b}, nil }
	ctx := context.Background()
	journalPath := filepath.Join(home, "profiles", "backup-restore.json")
	if a.Op == "backup-recover" || a.Op == "backup-ack" {
		profiles, e := os.OpenRoot(filepath.Join(home, "profiles"))
		if e != nil {
			return versionResponse{}, errors.New("BACKUP_RECOVERY_REQUIRED")
		}
		defer profiles.Close()
		raw, e := backupRead(profiles, "backup-restore.json", 2*1024*1024)
		var journal backupJournal
		if e != nil || decodeBackupJSON(raw, &journal) != nil || journal.SchemaVersion != 1 || !backupTokenPattern.MatchString(journal.Token) || !validPortable(journal.Old) || !validPortable(journal.New) {
			return versionResponse{}, errors.New("BACKUP_RECOVERY_REQUIRED")
		}
		actual, _ := json.Marshal(prior)
		outcome := backupSnapshotOutcome(string(actual), journal.PriorJSON, journal.TargetJSON, journal.Committed)
		prefs := journal.Old
		if outcome == "committed" {
			prefs = journal.New
		}
		if outcome == "unknown" {
			return versionResponse{}, errors.New("BACKUP_RECOVERY_REQUIRED")
		}
		if a.Op == "backup-ack" {
			if a.BackupToken != journal.Token {
				return versionResponse{}, errors.New("BACKUP_RECOVERY_REQUIRED")
			}
			// Persist the matching state and journal removal before later
			// preference writers may proceed, including settings-only restores.
			if e = syncBackupDirectory(store.Root); e != nil {
				return versionResponse{}, e
			}
			if e = profiles.Remove("backup-restore.json"); e != nil {
				return versionResponse{}, errors.New("BACKUP_IO")
			}
			if e = syncBackupDirectory(filepath.Dir(journalPath)); e != nil {
				return versionResponse{}, e
			}
		}
		return response(backupResponse{Token: journal.Token, Outcome: outcome, Preferences: &prefs})
	}
	if a.Op == "backup-clean" {
		if fileExists(journalPath) {
			return versionResponse{}, errors.New("BACKUP_RECOVERY_REQUIRED")
		}
		directory, e := root.Open(".")
		if e != nil {
			return versionResponse{}, errors.New("BACKUP_IO")
		}
		defer directory.Close()
		entries, e := directory.ReadDir(513)
		if e != nil || len(entries) > 512 {
			return versionResponse{}, errors.New("BACKUP_IO")
		}
		for _, entry := range entries {
			if backupFilePattern.MatchString(entry.Name()) {
				info, e := root.Lstat(entry.Name())
				if e != nil || !info.Mode().IsRegular() {
					return versionResponse{}, errors.New("BACKUP_INVALID")
				}
				if e = root.Remove(entry.Name()); e != nil {
					return versionResponse{}, errors.New("BACKUP_IO")
				}
			}
			if backupTokenPattern.MatchString(entry.Name()) {
				if !entry.IsDir() {
					return versionResponse{}, errors.New("BACKUP_INVALID")
				}
				_, e = executeBackupAction(home, store, prior, versionAction{Op: "backup-finish", BackupToken: entry.Name()})
				if e != nil {
					return versionResponse{}, e
				}
			}
		}
		return response(backupResponse{Outcome: "clean"})
	}
	if (a.Op == "backup-export" || a.Op == "backup-prepare") && fileExists(journalPath) {
		return versionResponse{}, errors.New("BACKUP_RECOVERY_REQUIRED")
	}
	if a.Op == "backup-export" {
		current := ""
		if prior.Current != nil {
			current = prior.Current.ID
		}
		if current != a.Expected {
			return versionResponse{}, errors.New("BACKUP_STALE")
		}
		var prefs portableSettings
		if decodeBackupJSON(a.BackupPreferences, &prefs) != nil || !validPortable(prefs) {
			return versionResponse{}, errors.New("BACKUP_INVALID")
		}
		manifest, err := backupManifestFromStore(home, prior, prefs)
		if err != nil {
			return versionResponse{}, err
		}
		file, err := os.CreateTemp(filepath.Join(home, "backups"), "backup-export-*.json")
		if err != nil {
			return versionResponse{}, errors.New("BACKUP_IO")
		}
		name := filepath.Base(file.Name())
		file.Close()
		if err = writeBackupJSON(filepath.Join(home, "backups", name), manifest); err != nil {
			root.Remove(name)
			return versionResponse{}, err
		}
		return response(backupResponse{File: name, Profiles: len(manifest.Profiles)})
	}
	if a.Op == "backup-prepare" {
		current := ""
		if prior.Current != nil {
			current = prior.Current.ID
		}
		if current != a.Expected || !backupFilePattern.MatchString(a.BackupFile) {
			return versionResponse{}, errors.New("BACKUP_STALE")
		}
		raw, err := backupRead(root, a.BackupFile, maxBackupBytes)
		if err != nil {
			return versionResponse{}, err
		}
		var manifest backupManifest
		if decodeBackupJSON(raw, &manifest) != nil || manifest.SchemaVersion != 1 || !validPortable(manifest.Preferences) || len(manifest.Profiles) > 128 || len(manifest.GlobalMerge) > maxConfigBytes {
			return versionResponse{}, errors.New("BACKUP_INVALID")
		}
		if _, e := configpipeline.LayeredMergeSource([]byte("{}"), []byte(manifest.GlobalMerge), nil); e != nil {
			return versionResponse{}, errors.New("BACKUP_INVALID")
		}
		directory, err := os.MkdirTemp(filepath.Join(home, "backups"), "restore-")
		if err != nil {
			return versionResponse{}, errors.New("BACKUP_IO")
		}
		token := filepath.Base(directory)
		plan := backupPlan{SchemaVersion: 1, Names: []backupName{}, Prior: prior, Preferences: manifest.Preferences, AllowLan: a.BackupAllowLan, Target: configpipeline.Snapshot{Profiles: map[string]configpipeline.Version{}, Previous: prior.Current, GlobalMerge: manifest.GlobalMerge}}
		for name, v := range prior.Profiles {
			plan.Target.Profiles[name] = v
		}
		complete := false
		defer func() {
			if !complete {
				for _, v := range plan.Versions {
					_ = store.Discard(ctx, v)
				}
				os.RemoveAll(directory)
			}
		}()
		originals := map[string]bool{}
		used := map[string]bool{}
		for name := range prior.Profiles {
			used[name] = true
		}
		for _, p := range manifest.Profiles {
			if originals[p.Name] || !validBackupProfile(p) {
				return versionResponse{}, errors.New("BACKUP_INVALID")
			}
			originals[p.Name] = true
			name := p.Name
			stem := strings.TrimSuffix(name, filepath.Ext(name))
			for suffix := 2; used[name] || fileExists(filepath.Join(home, "profiles", name)); suffix++ {
				name = fmt.Sprintf("%s (%d).yaml", stem, suffix)
			}
			if !profileIDPattern.MatchString(name) {
				return versionResponse{}, errors.New("BACKUP_NAME_LIMIT")
			}
			used[name] = true
			result, receipt, err := compileLayeredMerge(home, p.Original, manifest.GlobalMerge, p.Overlay, backupOverrides(manifest.Preferences, a.BackupAllowLan), manifest.Preferences.SmartAutoConvert, p.RegionPlan, p.EditIntent)
			if err != nil || len(result.YAML) > maxConfigBytes {
				return versionResponse{}, errors.New("BACKUP_VALIDATION_FAILED")
			}
			result.GlobalMerge = manifest.GlobalMerge
			result.ProfileID = name
			result.Metadata = string(p.Metadata)
			result.RegionPlan = p.RegionPlan
			result.SmartConversion = manifest.Preferences.SmartAutoConvert
			result.Overlays = nil
			if p.Overlay != "" {
				result.Overlays = [][]byte{[]byte(p.Overlay)}
			}
			// A restore queues a fresh explicit region selection. Runtime manual
			// choices/observations are neither exported nor replayed from backup.
			selector := ""
			if p.EditIntent != nil && !p.EditIntent.Disabled && p.EditIntent.Template != nil {
				plan := p.EditIntent.Template
				if plan.TemplateID == "region" && plan.Region != nil && plan.Region.Enable && !plan.Region.Disabled {
					selector = plan.Region.Selector
				}
			} else if p.RegionPlan != nil && p.RegionPlan.Enable && !p.RegionPlan.Disabled {
				selector = p.RegionPlan.Selector
			}
			version, err := store.StageWithRegionChoice(ctx, result, &configpipeline.RegionChoice{Pending: selector})
			if err != nil {
				return versionResponse{}, errors.New("BACKUP_STAGE_FAILED")
			}
			plan.Versions = append(plan.Versions, version)
			fingerprint, e := fingerprintBackupVersion(version)
			if e != nil {
				return versionResponse{}, e
			}
			plan.Fingerprints = append(plan.Fingerprints, fingerprint)
			plan.Receipts = append(plan.Receipts, receipt)
			plan.Target.Profiles[name] = version
			plan.Names = append(plan.Names, backupName{p.Name, name})
			if p.Name == manifest.Active {
				v := version
				plan.Target.Current = &v
			}
		}
		if manifest.Active != "" && plan.Target.Current == nil {
			return versionResponse{}, errors.New("BACKUP_INVALID")
		}
		if err = writeBackupJSON(filepath.Join(directory, "plan.json"), plan); err != nil {
			return versionResponse{}, err
		}
		complete = true
		return response(backupResponse{Token: token, Profiles: len(manifest.Profiles), Names: plan.Names, GlobalChanged: prior.GlobalMerge != manifest.GlobalMerge, Preferences: &manifest.Preferences})
	}
	plan, err := loadBackupPlan(root, a.BackupToken)
	if err != nil {
		return versionResponse{}, err
	}
	priorJSON, _ := json.Marshal(plan.Prior)
	targetJSON, _ := json.Marshal(plan.Target)
	actualJSON, _ := json.Marshal(prior)
	committed := false
	if fileExists(journalPath) {
		raw, e := os.ReadFile(journalPath)
		var journal backupJournal
		if e != nil || decodeBackupJSON(raw, &journal) != nil || journal.Token != a.BackupToken || journal.PriorJSON != string(priorJSON) || journal.TargetJSON != string(targetJSON) {
			return versionResponse{}, errors.New("BACKUP_RECOVERY_REQUIRED")
		}
		committed = journal.Committed
	}
	outcome := backupSnapshotOutcome(string(actualJSON), string(priorJSON), string(targetJSON), committed)

	switch a.Op {
	case "backup-status":
		return response(backupResponse{Token: a.BackupToken, Outcome: outcome, Preferences: &plan.Preferences})
	case "backup-arm":
		if outcome != "prior" || a.BackupAllowLan != plan.AllowLan || a.BackupOwner == "" {
			return versionResponse{}, errors.New("BACKUP_STALE")
		}
		if fileExists(journalPath) {
			return versionResponse{}, errors.New("BACKUP_RECOVERY_REQUIRED")
		}
		for _, v := range plan.Versions {
			if fileExists(filepath.Join(home, "profiles", v.ProfileID)) {
				return versionResponse{}, errors.New("BACKUP_STALE")
			}
		}
		for i, v := range plan.Versions {
			fingerprint, e := fingerprintBackupVersion(v)
			if e != nil || fingerprint != plan.Fingerprints[i] {
				return versionResponse{}, errors.New("BACKUP_VERIFY_FAILED")
			}
			raw, err := os.ReadFile(v.Path)
			if err != nil {
				return versionResponse{}, errors.New("BACKUP_VERIFY_FAILED")
			}
			receipt, err := validateCandidateWithReceipt(home, string(raw), backupOverrides(plan.Preferences, plan.AllowLan))
			if err != nil || receipt != plan.Receipts[i] {
				return versionResponse{}, errors.New("BACKUP_VERIFY_FAILED")
			}
		}
		var old portableSettings
		if decodeBackupJSON(a.BackupPreferences, &old) != nil || !validPortable(old) {
			return versionResponse{}, errors.New("BACKUP_INVALID")
		}
		if err = os.MkdirAll(filepath.Dir(journalPath), 0700); err != nil {
			return versionResponse{}, errors.New("BACKUP_IO")
		}
		journal := backupJournal{SchemaVersion: 1, Owner: a.BackupOwner, Token: a.BackupToken, PriorJSON: string(priorJSON), TargetJSON: string(targetJSON), Old: old, New: plan.Preferences}
		if err = writeBackupJSON(journalPath, journal); err != nil {
			return versionResponse{}, err
		}
		return response(backupResponse{Token: a.BackupToken, Outcome: "armed"})
	case "backup-commit":
		if outcome != "prior" {
			return versionResponse{}, errors.New("BACKUP_STALE")
		}
		raw, err := os.ReadFile(journalPath)
		var journal backupJournal
		if err != nil || decodeBackupJSON(raw, &journal) != nil || journal.Token != a.BackupToken || journal.TargetJSON != string(targetJSON) {
			return versionResponse{}, errors.New("BACKUP_RECOVERY_REQUIRED")
		}
		for i, v := range plan.Versions {
			fingerprint, e := fingerprintBackupVersion(v)
			if e != nil || fingerprint != plan.Fingerprints[i] {
				return versionResponse{}, errors.New("BACKUP_VERIFY_FAILED")
			}
			generated, e := os.ReadFile(v.Path)
			if e != nil {
				return versionResponse{}, errors.New("BACKUP_VERIFY_FAILED")
			}
			receipt, e := validateCandidateWithReceipt(home, string(generated), backupOverrides(plan.Preferences, plan.AllowLan))
			if e != nil || receipt != plan.Receipts[i] {
				return versionResponse{}, errors.New("BACKUP_VERIFY_FAILED")
			}
		}
		if err = store.Publish(ctx, plan.Target); err != nil {
			return versionResponse{}, errors.New("BACKUP_COMMIT_FAILED")
		}
		journal.Committed = true
		if err = writeBackupJSON(journalPath, journal); err != nil {
			return versionResponse{}, err
		}
		return response(backupResponse{Token: a.BackupToken, Outcome: "committed", Preferences: &plan.Preferences})
	case "backup-finish":
		// ArkTS first reconciles and durably flushes preferences, then removes the journal.
		if fileExists(journalPath) {
			return versionResponse{}, errors.New("BACKUP_RECOVERY_REQUIRED")
		}
		referenced := map[string]bool{}
		if prior.Current != nil {
			referenced[prior.Current.ID] = true
		}
		if prior.Previous != nil {
			referenced[prior.Previous.ID] = true
		}
		for _, v := range prior.Profiles {
			referenced[v.ID] = true
		}
		for _, v := range plan.Versions {
			if !referenced[v.ID] {
				if _, e := os.Lstat(v.Path); os.IsNotExist(e) {
					continue
				}
				if err = store.Discard(ctx, v); err != nil {
					return versionResponse{}, errors.New("BACKUP_CLEANUP_FAILED")
				}
			}
		}
		if err = os.RemoveAll(filepath.Join(home, "backups", a.BackupToken)); err != nil {
			return versionResponse{}, errors.New("BACKUP_CLEANUP_FAILED")
		}
		return response(backupResponse{Outcome: outcome})
	default:
		return versionResponse{}, errors.New("BACKUP_INVALID")
	}
}
func fileExists(path string) bool { _, err := os.Lstat(path); return !os.IsNotExist(err) }
