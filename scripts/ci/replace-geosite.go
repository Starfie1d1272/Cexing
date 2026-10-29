// Replace the documented categories while preserving all other protobuf data.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/metacubex/mihomo/component/geodata/router"
	"google.golang.org/protobuf/proto"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: replace-geosite INPUT CATEGORIES OUTPUT")
		os.Exit(2)
	}
	if err := run(os.Args[1], os.Args[2], os.Args[3]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(input, categories, output string) error {
	data, err := os.ReadFile(input)
	if err != nil {
		return err
	}
	var list router.GeoSiteList
	if err := proto.Unmarshal(data, &list); err != nil {
		return err
	}
	data, err = os.ReadFile(categories)
	if err != nil {
		return err
	}
	var replacements map[string][]string
	if err := json.Unmarshal(data, &replacements); err != nil {
		return err
	}
	if len(replacements) != 3 || len(replacements["BILIINTL"]) == 0 || len(replacements["SHAREPOINT"]) == 0 || len(replacements["HTTPDNS"]) != 22 {
		return fmt.Errorf("unexpected category manifest")
	}
	source, err := os.ReadFile(filepath.Join(filepath.Dir(categories), "sources", "HTTPDNS.Block.list"))
	if err != nil {
		return err
	}
	upstream := make(map[string]string)
	for _, line := range strings.Split(string(source), "\n") {
		kind, name, ok := strings.Cut(strings.TrimSpace(line), ",")
		if ok && (kind == "DOMAIN" || kind == "DOMAIN-SUFFIX") {
			upstream[name] = kind
		}
	}
	found := make(map[string]bool)
	for _, site := range list.Entry {
		names, ok := replacements[site.CountryCode]
		if !ok {
			continue
		}
		if found[site.CountryCode] {
			return fmt.Errorf("duplicate category %s", site.CountryCode)
		}
		found[site.CountryCode] = true
		sort.Strings(names)
		site.Domain = nil
		for i, name := range names {
			if name == "" || (i > 0 && names[i-1] == name) {
				return fmt.Errorf("empty or duplicate domain in %s", site.CountryCode)
			}
			kind := router.Domain_Domain
			if site.CountryCode == "HTTPDNS" {
				prefix, value, ok := strings.Cut(name, ":")
				if !ok {
					return fmt.Errorf("invalid HTTPDNS entry")
				}
				sourceKind, present := upstream[value]
				if !present {
					return fmt.Errorf("HTTPDNS domain absent from upstream: %s", value)
				}
				switch prefix {
				case "full":
					if sourceKind != "DOMAIN" {
						return fmt.Errorf("unexpected source type for %s", value)
					}
					kind = router.Domain_Full
				case "domain":
					baidu := value == "httpdns.baidu.com" || value == "httpdns.baidubce.com" || value == "httpsdns.baidu.com"
					if sourceKind != "DOMAIN-SUFFIX" && !baidu {
						return fmt.Errorf("unexpected suffix for %s", value)
					}
				default:
					return fmt.Errorf("invalid HTTPDNS type")
				}
				name = value
			}
			site.Domain = append(site.Domain, &router.Domain{Type: kind, Value: name})
		}
	}
	if len(found) != len(replacements) {
		return fmt.Errorf("missing replacement category")
	}
	data, err = (proto.MarshalOptions{Deterministic: true}).Marshal(&list)
	if err != nil {
		return err
	}
	return os.WriteFile(output, data, 0600)
}
