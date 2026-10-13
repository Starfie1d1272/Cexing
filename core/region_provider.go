package main

import (
	"errors"
	"os"
	"sort"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"gopkg.in/yaml.v3"
)

// regionProviderNames reads the same validated app-private cache as the normal
// offline candidate check. It never calls a provider Initial/Read method or
// fetches an HTTP URL. Missing cache is a pending preview, not an empty group.
func regionProviderNames(home string, root *yaml.Node) (map[string][]string, error) {
	content, err := yaml.Marshal(root)
	if err != nil {
		return nil, err
	}
	runLock.Lock()
	defer runLock.Unlock()
	constant.SetHomeDir(home)
	homeDir = home
	before, err := localProviderSnapshot(string(content))
	if err != nil {
		return nil, err
	}
	raw := config.DefaultRawConfig()
	if err := yaml.Unmarshal(content, raw); err != nil {
		return nil, err
	}
	result := map[string][]string{}
	for name, provider := range raw.ProxyProvider {
		kind, err := providerStringField(provider, "type")
		if err != nil {
			return nil, err
		}
		var items []any
		if kind == "inline" {
			var ok bool
			items, ok = provider["payload"].([]any)
			if !ok {
				return nil, errors.New("invalid inline provider")
			}
		} else {
			path, err := providerStringField(provider, "path")
			if err != nil {
				return nil, err
			}
			url, err := providerStringField(provider, "url")
			if err != nil {
				return nil, err
			}
			if kind == "http" && path == "" {
				path = constant.Path.GetPathByHash("proxies", url)
			}
			if err := validateProviderPath(path); err != nil {
				return nil, err
			}
			bytes, err := os.ReadFile(constant.Path.Resolve(path))
			if err != nil {
				return nil, err
			}
			var payload struct {
				Proxies []any `yaml:"proxies"`
			}
			if err := yaml.Unmarshal(bytes, &payload); err != nil {
				return nil, err
			}
			items = payload.Proxies
		}
		seen := map[string]bool{}
		for _, item := range items {
			proxy, ok := item.(map[string]any)
			if !ok {
				return nil, errors.New("invalid provider node")
			}
			node, ok := proxy["name"].(string)
			if !ok || node == "" || seen[node] {
				return nil, errors.New("invalid provider node name")
			}
			seen[node] = true
			result[name] = append(result[name], node)
		}
		sort.Strings(result[name])
	}
	after, err := localProviderSnapshot(string(content))
	if err != nil || before != after {
		return nil, errors.New("provider snapshot changed")
	}
	return result, nil
}
