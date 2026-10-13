package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"core/configpipeline"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"gopkg.in/yaml.v3"
)

// coreValidateOffline parses a candidate without applying config or creating
// listeners. Unresolved provider resources are a separate outcome; validation
// never fetches them. The single C++ worker owns all calls into this process.
func coreValidateOffline(home, text, overrides string) error {
	_, err := coreValidateOfflineWithReceipt(home, text, overrides)
	return err
}

func coreValidateOfflineWithReceipt(home, text, overrides string) (string, error) {
	runLock.Lock()
	defer runLock.Unlock()
	if tunListener != nil {
		return "", errors.New("VALIDATOR_BUSY")
	}
	if home == "" || !filepath.IsAbs(home) {
		return "", errors.New("VALIDATOR_HOME")
	}
	hasProviders, needsGeosite, err := configpipeline.InspectOffline([]byte(text))
	if err != nil {
		return "", errors.New("CONFIG_INVALID")
	}
	if _, err := os.Stat(filepath.Join(home, "geoip.metadb")); err != nil {
		return "", errors.New("RESOURCE_MISSING")
	}
	if needsGeosite {
		if _, err := os.Stat(filepath.Join(home, "geosite.dat")); err != nil {
			return "", errors.New("RESOURCE_MISSING")
		}
	}
	constant.SetHomeDir(home)
	homeDir = home
	prior := log.Level()
	log.SetLevel(log.SILENT)
	defer log.SetLevel(prior)
	receipt := ""
	if hasProviders {
		receipt, err = localProviderSnapshot(text)
		if err != nil {
			return "", errors.New("PROVIDER_UNRESOLVED")
		}
	}
	if _, err := parsePlatformConfig(text, overrides, false); err != nil {
		return "", errors.New("CORE_VALIDATION_FAILED")
	}
	return receipt, nil
}

// Read only app-private provider cache files after the existing protected-path
// check. No provider Initial/Read method is called, so HTTP vehicles cannot fetch.
func localProviderSnapshot(text string) (string, error) {
	raw := config.DefaultRawConfig()
	if err := yaml.Unmarshal([]byte(sanitizeConfigJson(text)), raw); err != nil {
		return "", err
	}
	if err := validateProviderPaths(raw); err != nil {
		return "", err
	}
	hash := sha256.New()
	for _, section := range []struct {
		prefix  string
		entries map[string]map[string]any
	}{
		{"proxies", raw.ProxyProvider}, {"rules", raw.RuleProvider},
	} {
		names := make([]string, 0, len(section.entries))
		for name := range section.entries {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			provider := section.entries[name]
			kind, err := providerStringField(provider, "type")
			if err != nil {
				return "", err
			}
			if kind == "inline" {
				continue
			} // Inline payload is in candidate YAML.
			if kind != "file" && kind != "http" {
				return "", errors.New("unsupported provider")
			}
			path, err := providerStringField(provider, "path")
			if err != nil {
				return "", err
			}
			url, err := providerStringField(provider, "url")
			if err != nil {
				return "", err
			}
			if kind == "http" {
				// A custom cache path has no proof that its bytes came from this
				// candidate URL. Only the URL-derived default path is source-bound.
				expected := constant.Path.GetPathByHash(section.prefix, url)
				if path != "" && filepath.Clean(constant.Path.Resolve(path)) != filepath.Clean(constant.Path.Resolve(expected)) {
					return "", errors.New("unbound provider cache")
				}
				path = expected
			}
			if err := validateProviderPath(path); err != nil {
				return "", err
			}
			absolute := constant.Path.Resolve(path)
			stat, err := os.Lstat(absolute)
			if err != nil || !stat.Mode().IsRegular() || stat.Size() == 0 || stat.Size() > maxConfigBytes {
				return "", errors.New("provider cache unavailable")
			}
			content, err := os.ReadFile(absolute)
			if err != nil {
				return "", err
			}
			var payload map[string]any
			if err := yaml.Unmarshal(content, &payload); err != nil {
				return "", err
			}
			key := "proxies"
			if section.prefix == "rules" {
				key = "payload"
			}
			items, ok := payload[key].([]any)
			if !ok || len(items) == 0 {
				return "", errors.New("empty provider cache")
			}
			for _, item := range items {
				if section.prefix == "proxies" {
					mapping, ok := item.(map[string]any)
					if !ok {
						return "", errors.New("invalid proxy cache")
					}
					if _, err := adapter.ParseProxy(mapping); err != nil {
						return "", errors.New("invalid proxy cache")
					}
				} else if rule, ok := item.(string); !ok || rule == "" {
					return "", errors.New("invalid rule cache")
				}
			}
			_, _ = io.WriteString(hash, section.prefix+"/"+name+"/"+kind+"/"+url+"/"+path+"\x00")
			_, _ = hash.Write(content)
		}
	}
	return strings.ToLower(hex.EncodeToString(hash.Sum(nil))), nil
}
