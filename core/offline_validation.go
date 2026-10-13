package main

import (
	"errors"
	"os"
	"path/filepath"

	"core/configpipeline"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

// coreValidateOffline parses a candidate without applying config or creating
// listeners. Unresolved provider resources are a separate outcome; validation
// never fetches them. The single C++ worker owns all calls into this process.
func coreValidateOffline(home, text, overrides string) error {
	runLock.Lock()
	defer runLock.Unlock()
	if initialized || tunListener != nil {
		return errors.New("VALIDATOR_BUSY")
	}
	if home == "" || !filepath.IsAbs(home) {
		return errors.New("VALIDATOR_HOME")
	}
	hasProviders, needsGeosite, err := configpipeline.InspectOffline([]byte(text))
	if err != nil {
		return errors.New("CONFIG_INVALID")
	}
	if hasProviders {
		return errors.New("PROVIDER_UNRESOLVED")
	}
	if _, err := os.Stat(filepath.Join(home, "geoip.metadb")); err != nil {
		return errors.New("RESOURCE_MISSING")
	}
	if needsGeosite {
		if _, err := os.Stat(filepath.Join(home, "geosite.dat")); err != nil {
			return errors.New("RESOURCE_MISSING")
		}
	}
	constant.SetHomeDir(home)
	prior := log.Level()
	log.SetLevel(log.SILENT)
	defer log.SetLevel(prior)
	if _, err := parsePlatformConfig(text, overrides, false); err != nil {
		return errors.New("CORE_VALIDATION_FAILED")
	}
	return nil
}
