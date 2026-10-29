// Produce the fixed baseline with every locally replaced category cleared.
package main

import (
	"os"
	"strings"

	"github.com/metacubex/mihomo/component/geodata/router"
	"google.golang.org/protobuf/proto"
)

func main() {
	if len(os.Args) != 3 {
		panic("usage: sanitize-geosite INPUT OUTPUT")
	}
	b, e := os.ReadFile(os.Args[1])
	if e != nil {
		panic(e)
	}
	var list router.GeoSiteList
	if e = proto.Unmarshal(b, &list); e != nil {
		panic(e)
	}
	wanted := map[string]bool{}
	for _, n := range strings.Fields("BILIINTL SHAREPOINT HTTPDNS CN STEAM ONEDRIVE MICROSOFT CATEGORY-NETDISK-!CN CATEGORY-GAMES-!CN CATEGORY-GAMES CATEGORY-ENTERTAINMENT CATEGORY-COMPANIES CATEGORY-ADS CATEGORY-ADS-ALL CATEGORY-ADS-AND-TELEMETRY CATEGORY-TELEMETRY GEOLOCATION-!CN TRACKER GFW GOOGLE-CN APPLE-CN") {
		wanted[n] = false
	}
	for _, x := range list.Entry {
		if found, ok := wanted[x.CountryCode]; ok {
			if found {
				panic("duplicate category " + x.CountryCode)
			}
			x.Domain = nil
			wanted[x.CountryCode] = true
		}
	}
	for n, found := range wanted {
		if !found {
			panic(n)
		}
	}
	b, e = (proto.MarshalOptions{Deterministic: true}).Marshal(&list)
	if e != nil {
		panic(e)
	}
	if e = os.WriteFile(os.Args[2], b, 0600); e != nil {
		panic(e)
	}
}
