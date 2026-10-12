package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Match the panel's private versioned deployment contract. This verifies disk
// consistency, not provenance: pinned bundle approval still belongs to assets.
var uiVersionPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
var uiAssetPathPattern = regexp.MustCompile(`^[A-Za-z0-9_./-]+$`)

type uiSelection struct {
	Current  string `json:"current"`
	Previous string `json:"previous"`
}
type uiAssetEntry struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}
type uiAssetManifest struct {
	Schema    int            `json:"schema"`
	Version   string         `json:"version"`
	SourceSHA string         `json:"sourceSha"`
	Files     []uiAssetEntry `json:"files"`
}

func uiSelectionEntry(selection uiSelection) []byte {
	data, _ := json.Marshal(selection)
	return []byte(`<!doctype html><!--ZASHBOARD_SELECTION:` + string(data) + `--><meta charset="utf-8"><title>Zashboard</title><script>location.replace('./versions/` + selection.Current + `/' + location.hash)</script>`)
}

func readUIFile(path string, limit int64) ([]byte, error) {
	st, err := os.Lstat(path)
	if err != nil || !st.Mode().IsRegular() || st.Size() > limit {
		return nil, errors.New("invalid UI file")
	}
	return os.ReadFile(path)
}

func validateSelectedUI(root string) error {
	entry, err := readUIFile(filepath.Join(root, "index.html"), 1024)
	if err != nil {
		return err
	}
	prefix := []byte("<!doctype html><!--ZASHBOARD_SELECTION:")
	if !bytes.HasPrefix(entry, prefix) {
		return errors.New("invalid UI selector")
	}
	end := bytes.Index(entry[len(prefix):], []byte("-->"))
	if end < 0 {
		return errors.New("invalid UI selector")
	}
	var selection uiSelection
	if json.Unmarshal(entry[len(prefix):len(prefix)+end], &selection) != nil || !uiVersionPattern.MatchString(selection.Current) || (selection.Previous != "" && !uiVersionPattern.MatchString(selection.Previous)) || !bytes.Equal(entry, uiSelectionEntry(selection)) {
		return errors.New("invalid UI selector")
	}
	directory := filepath.Join(root, "versions", selection.Current)
	data, err := readUIFile(filepath.Join(directory, "manifest.json"), 512*1024)
	if err != nil {
		return err
	}
	var manifest uiAssetManifest
	if json.Unmarshal(data, &manifest) != nil || manifest.Schema != 1 || manifest.Version != selection.Current || len(manifest.Files) == 0 || len(manifest.Files) > 1024 {
		return errors.New("invalid UI manifest")
	}
	// Zashboard hashes compact JSON with path,size,sha256 field order. Paths are
	// ASCII and numeric sizes bounded, so Go's representation matches that form.
	identity, err := json.Marshal(manifest.Files)
	if err != nil || uiSHA256(identity) != manifest.Version {
		return errors.New("UI manifest identity mismatch")
	}
	expected := map[string]bool{"manifest.json": true}
	total := int64(0)
	for _, asset := range manifest.Files {
		path := asset.Path
		if len(path) == 0 || len(path) >= 240 || !uiAssetPathPattern.MatchString(path) || expected[path] || asset.Size < 0 || asset.Size > 16*1024*1024 || !uiVersionPattern.MatchString(asset.SHA256) {
			return errors.New("invalid UI manifest entry")
		}
		for _, part := range strings.Split(path, "/") {
			if part == "" || part == "." || part == ".." {
				return errors.New("invalid UI asset path")
			}
		}
		expected[path] = true
		total += asset.Size
		if total > 64*1024*1024 {
			return errors.New("UI exceeds size limit")
		}
		content, err := readUIFile(filepath.Join(directory, filepath.FromSlash(path)), asset.Size)
		if err != nil || int64(len(content)) != asset.Size || uiSHA256(content) != asset.SHA256 {
			return errors.New("UI asset checksum mismatch")
		}
	}
	if !expected["index.html"] {
		return errors.New("UI index is absent from manifest")
	}
	return filepath.WalkDir(directory, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		relative, err := filepath.Rel(directory, path)
		if err != nil || !expected[filepath.ToSlash(relative)] {
			return errors.New("unexpected UI asset")
		}
		return nil
	})
}

func uiSHA256(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }
