package main

import (
	"context"
	"core/configpipeline"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"gopkg.in/yaml.v3"
	"io"
	"os"
	"sort"
)

// Private compare token for editor inputs and the local resources they refer to.
// Missing/invalid cache bytes are still identifiable; no validation or fetch occurs.
func editorIdentity(home string, a versionAction, global string) (string, error) {
	request, e := editorReadRequest(home, a, global)
	if e != nil {
		return "", errors.New("EDIT_READ_FAILED")
	}
	root, e := (configpipeline.Compiler{Template: editorTemplate(home), PrepareTemplate: editorTemplatePrepare(home)}).EditorResourceSource(context.Background(), request)
	if e != nil {
		return "", errors.New("EDIT_READ_FAILED")
	}
	text, e := yaml.Marshal(root)
	if e != nil {
		return "", errors.New("EDIT_READ_FAILED")
	}
	raw := config.DefaultRawConfig()
	if e = yaml.Unmarshal(text, raw); e != nil {
		return "", errors.New("EDIT_READ_FAILED")
	}
	// Authoring may resolve region providers under runLock itself. Hold the
	// lock only for the following shared home/path snapshot, never recursively.
	runLock.Lock()
	defer runLock.Unlock()
	constant.SetHomeDir(home)
	homeDir = home
	h := sha256.New()
	// Bind the exact authoring projection as well as the cache bytes below.
	h.Write(text)
	// Compiler-generated provenance changes on a successful publication; user
	// changes still receive a new host draft revision and profile/source ticket.
	identityIntent := a.EditIntent
	if identityIntent != nil && identityIntent.Template != nil {
		copied := *identityIntent
		plan := *copied.Template
		plan.Baseline = nil
		plan.Mine = nil
		copied.Template = &plan
		identityIntent = &copied
	}
	input, _ := json.Marshal(struct {
		Original, Global, Overlay, Settings, Metadata string
		Intent                                        *configpipeline.EditIntent
		Region                                        *configpipeline.RegionPlan
	}{a.Original, global, a.Overlay, a.Overrides, a.Metadata, identityIntent, a.RegionPlan})
	h.Write(input)
	for _, section := range []struct {
		prefix string
		values map[string]map[string]any
	}{{"proxies", raw.ProxyProvider}, {"rules", raw.RuleProvider}} {
		names := make([]string, 0, len(section.values))
		for name := range section.values {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			p := section.values[name]
			kind, e := providerStringField(p, "type")
			if e != nil {
				return "", errors.New("EDIT_RESOURCE_INVALID")
			}
			if kind != "http" && kind != "file" {
				continue
			}
			path, e := providerStringField(p, "path")
			if e != nil {
				return "", errors.New("EDIT_RESOURCE_INVALID")
			}
			url, e := providerStringField(p, "url")
			if e != nil {
				return "", errors.New("EDIT_RESOURCE_INVALID")
			}
			if path == "" && kind == "http" {
				path = constant.Path.GetPathByHash(section.prefix, url)
			}
			descriptor, _ := json.Marshal([]string{section.prefix, name, path})
			h.Write(descriptor)
			if _, e := os.Lstat(constant.Path.Resolve(path)); os.IsNotExist(e) {
				h.Write([]byte("missing"))
				continue
			}
			if validateProviderPath(path) != nil {
				return "", errors.New("EDIT_RESOURCE_INVALID")
			}
			f, e := os.Open(constant.Path.Resolve(path))
			if os.IsNotExist(e) {
				h.Write([]byte("missing"))
				continue
			}
			if e != nil {
				return "", errors.New("EDIT_RESOURCE_INVALID")
			}
			info, e := f.Stat()
			if e != nil || !info.Mode().IsRegular() || info.Size() > maxConfigBytes {
				f.Close()
				return "", errors.New("EDIT_RESOURCE_INVALID")
			}
			h.Write([]byte("present"))
			n, e := io.Copy(h, io.LimitReader(f, maxConfigBytes+1))
			f.Close()
			if e != nil || n > maxConfigBytes {
				return "", errors.New("EDIT_RESOURCE_INVALID")
			}
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
