// Compare every category, matching type, value, and attribute in two GeoSite files.
// Run from core: go run ../scripts/ci/compare-geosite.go OLD.dat NEW.dat
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"

	"github.com/metacubex/mihomo/component/geodata/router"
	"google.golang.org/protobuf/proto"
)

type entry struct {
	Type       string   `json:"type"`
	Value      string   `json:"value"`
	Attributes []string `json:"attributes"`
}

func read(path string) (map[string]map[string]int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var list router.GeoSiteList
	if err = proto.Unmarshal(data, &list); err != nil {
		return nil, err
	}
	result := make(map[string]map[string]int)
	for _, site := range list.Entry {
		if _, ok := result[site.CountryCode]; ok {
			return nil, fmt.Errorf("duplicate category %q", site.CountryCode)
		}
		rows := make(map[string]int)
		for _, domain := range site.Domain {
			row := entry{Type: domain.Type.String(), Value: domain.Value, Attributes: []string{}}
			for _, attr := range domain.Attribute {
				value, err := json.Marshal(attr)
				if err != nil {
					return nil, err
				}
				row.Attributes = append(row.Attributes, string(value))
			}
			sort.Strings(row.Attributes)
			value, err := json.Marshal(row)
			if err != nil {
				return nil, err
			}
			rows[string(value)]++
		}
		result[site.CountryCode] = rows
	}
	return result, nil
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: compare-geosite OLD.dat NEW.dat")
		os.Exit(2)
	}
	old, err := read(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	next, err := read(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	categories := make(map[string]bool)
	for k := range old {
		categories[k] = true
	}
	for k := range next {
		categories[k] = true
	}
	names := make([]string, 0, len(categories))
	for k := range categories {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, name := range names {
		_, before := old[name]
		_, after := next[name]
		if !before {
			fmt.Printf("+ category %s\n", name)
		}
		if !after {
			fmt.Printf("- category %s\n", name)
		}
		keys := make(map[string]bool)
		for k := range old[name] {
			keys[k] = true
		}
		for k := range next[name] {
			keys[k] = true
		}
		rows := make([]string, 0, len(keys))
		for k := range keys {
			rows = append(rows, k)
		}
		sort.Strings(rows)
		for _, row := range rows {
			difference := next[name][row] - old[name][row]
			if difference != 0 {
				fmt.Printf("%+d %s %s\n", difference, name, row)
			}
		}
	}
}
