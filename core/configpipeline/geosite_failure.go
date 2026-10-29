package configpipeline

import (
	"regexp"
	"strings"
)

// Only names independently identified in public GeoSite data are eligible for
// display. A subscription can put secrets in an arbitrary category name.
var publicMissingGeoSites = map[string]bool{
	"apple-cn": true, "biliintl": true, "gfw": true, "google-cn": true,
	"httpdns": true, "sharepoint": true, "tracker": true,
	"win-extra": true, "win-spy": true, "win-update": true,
}
var missingGeoSite = regexp.MustCompile(`(?:^|: )(?:list|country code) ([a-zA-Z0-9_!.\-]{1,64}) not found in geosite\.dat$`)

// MissingGeoSiteCode never returns the upstream message or an untrusted name.
func MissingGeoSiteCode(err error) string {
	if err == nil {
		return ""
	}
	match := missingGeoSite.FindStringSubmatch(err.Error())
	if match == nil {
		return ""
	}
	name := strings.ToLower(match[1])
	if publicMissingGeoSites[name] {
		return "GEOSITE_MISSING:" + name
	}
	return "GEOSITE_MISSING"
}

func safeGeoSiteCode(code string) bool {
	return strings.HasPrefix(code, "GEOSITE_MISSING:") && publicMissingGeoSites[strings.TrimPrefix(code, "GEOSITE_MISSING:")]
}
