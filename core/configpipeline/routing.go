package configpipeline

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/metacubex/mihomo/common/utils"
	"math"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"core/rulecatalog"
	"gopkg.in/yaml.v3"
)

// RoutingPlan is independent of the legacy mutually exclusive product templates.
// The existing TemplatePlan envelope supplies bindings/archives/transactions.
type RoutingPlan struct {
	Version            int                 `json:"version"`
	Mode               string              `json:"mode"`
	DefaultOutlet      string              `json:"defaultOutlet,omitempty"`
	Outlets            []RoutingOutlet     `json:"outlets"`
	Routes             []RoutingRoute      `json:"routes"`
	Assignments        map[string]string   `json:"assignments,omitempty"`
	OverlayRulesDigest string              `json:"overlayRulesDigest"`
	ResolvedProviders  map[string][]string `json:"-"`
}
type RoutingScope struct {
	Regions        []string `json:"regions"`
	ExcludeRegions []string `json:"excludeRegions"`
	Nodes          []string `json:"nodes"`
	ExcludeNodes   []string `json:"excludeNodes"`
	Providers      []string `json:"providers"`
	Unknown        string   `json:"unknown"` // include or exclude, never inferred as non-HK
}
type RoutingOutlet struct {
	ID        string                     `json:"id"`
	Algorithm string                     `json:"algorithm"`
	Scope     RoutingScope               `json:"scope"`
	Order     []string                   `json:"order,omitempty"`
	Options   map[string]json.RawMessage `json:"options,omitempty"`
}
type RoutingRoute struct {
	ID       string   `json:"id"`
	Services []string `json:"services"`
	Outlet   string   `json:"outlet"`
}
type RoutingCatalogue struct {
	ProviderNodes      map[string][]string   `json:"providerNodes"`
	DirectNodes        []string              `json:"directNodes"`
	Nodes              map[string]string     `json:"nodes"`
	Providers          []string              `json:"providers"`
	Regions            []string              `json:"regions"`
	Unknown            int                   `json:"unknown"`
	Pending            bool                  `json:"pending"`
	Services           []rulecatalog.Service `json:"services"`
	OverlayRulesDigest string                `json:"overlayRulesDigest"`
}

var routingDigest = regexp.MustCompile(`^[0-9a-f]{64}$`)
var routingID = regexp.MustCompile(`^[a-z][a-z0-9-]{0,47}$`)

func routingFailure() error { return errors.New("ROUTING_INVALID") }
func (p RoutingPlan) Validate() error {
	if p.Version != 1 || (p.Mode != "managed" && p.Mode != "subscription") || len(p.Outlets) > 32 || len(p.Routes) > 32 || len(p.Assignments) > 16384 || !routingDigest.MatchString(p.OverlayRulesDigest) {
		return routingFailure()
	}
	if p.Mode == "subscription" {
		if len(p.Outlets) != 0 || len(p.Routes) != 0 || p.DefaultOutlet != "" {
			return routingFailure()
		}
		return nil
	}
	outlets := map[string]bool{}
	for _, o := range p.Outlets {
		if !routingID.MatchString(o.ID) || outlets[o.ID] || !stringIn(o.Algorithm, []string{"smart", "url-test", "fallback", "select"}) {
			return routingFailure()
		}
		outlets[o.ID] = true
		if o.Scope.Unknown != "include" && o.Scope.Unknown != "exclude" {
			return routingFailure()
		}
		for _, codes := range [][]string{o.Scope.Regions, o.Scope.ExcludeRegions} {
			for _, code := range codes {
				if !validRegion(code) || code == "未知" {
					return routingFailure()
				}
			}
		}
		for _, values := range [][]string{o.Scope.Regions, o.Scope.ExcludeRegions, o.Scope.Nodes, o.Scope.ExcludeNodes, o.Scope.Providers, o.Order} {
			if len(values) > 16384 {
				return routingFailure()
			}
			seen := map[string]bool{}
			for _, value := range values {
				if value == "" || len(value) > 256 || strings.ContainsAny(value, "\r\n\x00") || seen[value] {
					return routingFailure()
				}
				seen[value] = true
			}
		}
		if o.Algorithm != "fallback" && len(o.Order) > 0 {
			return routingFailure()
		}
		if err := validateRoutingOptions(o); err != nil {
			return err
		}
	}
	if !outlets[p.DefaultOutlet] {
		return routingFailure()
	}
	ids, services := map[string]bool{}, map[string]bool{}
	for _, r := range p.Routes {
		if !routingID.MatchString(r.ID) || ids[r.ID] || !outlets[r.Outlet] || len(r.Services) == 0 || len(r.Services) > 32 {
			return routingFailure()
		}
		ids[r.ID] = true
		for _, service := range r.Services {
			if !rulecatalog.Known(service) || services[service] {
				return routingFailure()
			}
			services[service] = true
		}
	}
	for name, code := range p.Assignments {
		if name == "" || len(name) > 256 || !validRegion(code) {
			return routingFailure()
		}
	}
	return nil
}
func stringIn(s string, values []string) bool {
	for _, value := range values {
		if s == value {
			return true
		}
	}
	return false
}

// Unknown group options remain intact; owned structural fields cannot bypass
// scope exclusions, fallback order or fail-closed behavior through raw options.
func validateRoutingOptions(o RoutingOutlet) error {
	for key, raw := range o.Options {
		if stringIn(key, []string{"name", "type", "proxies", "use", "include-all", "include-all-proxies", "include-all-providers", "filter", "exclude-filter", "exclude-type", "empty-fallback"}) {
			return routingFailure()
		}
		var value any
		if json.Unmarshal(raw, &value) != nil {
			return routingFailure()
		}
		switch key {
		case "interval", "timeout", "max-failed-times", "tolerance":
			n, ok := value.(float64)
			limit := float64(86400)
			if key == "timeout" {
				limit = 300000
			}
			if key == "tolerance" {
				limit = 65535
			}
			if !ok || n < 0 || n > limit || n != float64(int64(n)) {
				return routingFailure()
			}
		case "sample-rate":
			n, ok := value.(float64)
			if !ok || n <= 0 || n > 1 {
				return routingFailure()
			}
		case "lazy", "uselightgbm", "collectdata", "prefer-asn":
			if _, ok := value.(bool); !ok {
				return routingFailure()
			}
		case "url":
			s, ok := value.(string)
			u, err := url.Parse(s)
			if !ok || err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil {
				return routingFailure()
			}
		case "expected-status":
			status, ok := value.(string)
			if !ok {
				return routingFailure()
			}
			if _, err := utils.NewUnsignedRanges[uint16](status); err != nil {
				return routingFailure()
			}
		case "policy-priority":
			priority, ok := value.(string)
			if !ok {
				return routingFailure()
			}
			for _, rule := range strings.Split(priority, ";") {
				rule = strings.TrimSpace(rule)
				if rule == "" {
					continue
				}
				index := strings.LastIndex(rule, ":")
				if index < 1 {
					return routingFailure()
				}
				factor, err := strconv.ParseFloat(strings.TrimSpace(rule[index+1:]), 64)
				if err != nil || factor <= 0 || math.IsNaN(factor) || math.IsInf(factor, 0) {
					return routingFailure()
				}
			}
		}
		if o.Algorithm != "smart" && stringIn(key, []string{"policy-priority", "uselightgbm", "collectdata", "sample-rate", "prefer-asn"}) {
			return routingFailure()
		}
	}
	return nil
}

// Only the rules sections of explicit Merge layers are fenced. Upstream rule
// changes do not invalidate a managed plan; a changed Merge must be acknowledged.
func RoutingOverlayDigest(overlays [][]byte) (string, error) {
	values := []string{}
	for _, data := range overlays {
		root, err := parse(data)
		if err != nil {
			return "", err
		}
		if rules := field(root, "rules"); rules != nil {
			values = append(values, fingerprint(rules))
		}
	}
	raw, _ := json.Marshal(values)
	return fingerprint(scalar(string(raw))), nil
}
func CheckRoutingOverlay(r Request) error {
	if r.Intent == nil || r.Intent.Disabled || r.Intent.Template == nil || r.Intent.Template.Routing == nil {
		return nil
	}
	p := r.Intent.Template.Routing
	if p.Mode != "managed" {
		return nil
	}
	digest, err := RoutingOverlayDigest(r.Overlays)
	if err != nil || digest != p.OverlayRulesDigest {
		return intentError("routing_overlay_conflict", -1)
	}
	return nil
}

func PreviewRouting(root *yaml.Node, resolved map[string][]string, assignments map[string]string) (RoutingCatalogue, error) {
	p := RoutingCatalogue{ProviderNodes: resolved, DirectNodes: []string{}, Nodes: map[string]string{}, Providers: []string{}, Regions: regionNames(), Services: rulecatalog.Services}
	add := func(name string) error {
		code := guessRegion(name)
		if v, ok := assignments[name]; ok {
			if !validRegion(v) {
				return routingFailure()
			}
			code = v
		}
		if _, ok := p.Nodes[name]; ok {
			return errors.New("ROUTING_NODE_AMBIGUOUS")
		}
		p.Nodes[name] = code
		return nil
	}
	if proxies := field(root, "proxies"); proxies != nil {
		if proxies.Kind != yaml.SequenceNode {
			return p, routingFailure()
		}
		for _, n := range proxies.Content {
			name := field(n, "name")
			kind := field(n, "type")
			if name == nil || kind == nil {
				return p, routingFailure()
			}
			if kind.Value == "direct" || kind.Value == "reject" || kind.Value == "dns" {
				continue
			}
			p.DirectNodes = append(p.DirectNodes, name.Value)
			if err := add(name.Value); err != nil {
				return p, err
			}
		}
	}
	if providers := field(root, "proxy-providers"); providers != nil {
		if providers.Kind != yaml.MappingNode {
			return p, routingFailure()
		}
		for i := 0; i < len(providers.Content); i += 2 {
			name := providers.Content[i].Value
			p.Providers = append(p.Providers, name)
			names, ok := resolved[name]
			if !ok {
				p.Pending = true
				continue
			}
			for _, node := range names {
				if err := add(node); err != nil {
					return p, err
				}
			}
		}
	}
	for _, code := range p.Nodes {
		if code == "未知" {
			p.Unknown++
		}
	}
	sort.Strings(p.Providers)
	return p, nil
}

func RoutingOutletEntityID(name string) string {
	sum := sha256.Sum256([]byte(name))
	return "outlet/" + hex.EncodeToString(sum[:16])
}
func RoutingGroupName(id string) string { return "Cexing / " + id }

// ApplyRouting receives a fresh merged root. All mutations remain private until
// the existing compiler's complete reference/resource validation and publication.
func ApplyRouting(ctx context.Context, root *yaml.Node, p RoutingPlan) error {
	if err := p.Validate(); err != nil {
		return err
	}
	if p.Mode == "subscription" {
		return nil
	}
	catalog, err := PreviewRouting(root, p.ResolvedProviders, p.Assignments)
	if err != nil {
		return err
	}
	used := map[string]bool{}
	direct := map[string]bool{}
	for _, section := range []string{"proxies", "proxy-groups"} {
		if nodes := field(root, section); nodes != nil {
			for _, n := range nodes.Content {
				name := field(n, "name")
				if name == nil {
					return routingFailure()
				}
				used[name.Value] = true
				if section == "proxies" {
					direct[name.Value] = true
				}
			}
		}
	}
	groups := field(root, "proxy-groups")
	if groups == nil {
		groups = sequence()
		set(root, "proxy-groups", groups)
	}
	if groups.Kind != yaml.SequenceNode {
		return routingFailure()
	}
	appendGroup := func(g *yaml.Node) error {
		name := field(g, "name").Value
		if used[name] {
			return routingFailure()
		}
		used[name] = true
		groups.Content = append(groups.Content, g)
		return nil
	}
	activeOutlets := map[string]bool{p.DefaultOutlet: true}
	for _, route := range p.Routes {
		activeOutlets[route.Outlet] = true
	}
	for _, o := range p.Outlets {
		if !activeOutlets[o.ID] {
			continue
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		selected := []string{}
		member := map[string]bool{}
		providerSet := map[string]bool{}
		for _, name := range o.Scope.Providers {
			providerSet[name] = true
			if !stringIn(name, catalog.Providers) {
				return routingFailure()
			}
		}
		// Empty provider list means every declared provider; none may be unresolved.
		for _, name := range catalog.Providers {
			if len(providerSet) == 0 || providerSet[name] {
				if _, ok := p.ResolvedProviders[name]; !ok {
					return errors.New("ROUTING_PROVIDER_PENDING")
				}
			}
		}
		for name, region := range catalog.Nodes {
			allowedSource := direct[name] && len(providerSet) == 0
			for provider, names := range p.ResolvedProviders {
				if (len(providerSet) == 0 || providerSet[provider]) && stringIn(name, names) {
					allowedSource = true
				}
			}
			if !allowedSource || stringIn(name, o.Scope.ExcludeNodes) || stringIn(region, o.Scope.ExcludeRegions) || region == "未知" && o.Scope.Unknown == "exclude" || len(o.Scope.Regions) > 0 && !stringIn(region, o.Scope.Regions) || len(o.Scope.Nodes) > 0 && !stringIn(name, o.Scope.Nodes) {
				continue
			}
			selected = append(selected, name)
			member[name] = true
		}
		sort.Strings(selected)
		if len(selected) == 0 || len(selected) > 16384 {
			return errors.New("ROUTING_SCOPE_EMPTY")
		}
		if o.Algorithm == "fallback" {
			if len(o.Order) != len(selected) {
				return errors.New("ROUTING_ORDER_REQUIRED")
			}
			for _, name := range o.Order {
				if !member[name] {
					return errors.New("ROUTING_ORDER_STALE")
				}
			}
			selected = append([]string(nil), o.Order...)
		}
		directMembers := []string{}
		uses := map[string][]string{}
		for _, name := range selected {
			if direct[name] && len(providerSet) == 0 {
				directMembers = append(directMembers, name)
				continue
			}
			for _, provider := range catalog.Providers {
				if len(providerSet) > 0 && !providerSet[provider] {
					continue
				}
				if stringIn(name, p.ResolvedProviders[provider]) {
					uses[provider] = append(uses[provider], name)
					break
				}
			}
		}
		g := smartGroup(RoutingGroupName(o.ID), directMembers, uses)
		set(g, "type", scalar(o.Algorithm))
		if o.Algorithm != "smart" {
			for _, key := range []string{"uselightgbm", "collectdata"} {
				set(g, key, nil)
			}
		}
		set(g, "url", scalar("https://www.gstatic.com/generate_204"))
		set(g, "interval", intScalar(300))
		set(g, "timeout", intScalar(5000))
		set(g, "lazy", boolScalar(true))
		set(g, "expected-status", scalar("204"))
		set(g, "max-failed-times", intScalar(5))
		if o.Algorithm == "smart" {
			set(g, "prefer-asn", boolScalar(false))
		}
		if o.Algorithm == "fallback" {
			// Provider nodes are represented by one-member fail-closed leaves so the
			// visible ordered candidate list is the actual cross-provider fallback order.
			ordered := []string{}
			for _, name := range selected {
				if direct[name] && len(providerSet) == 0 {
					ordered = append(ordered, name)
					continue
				}
				providers := map[string][]string{}
				for provider, names := range uses {
					if stringIn(name, names) {
						providers[provider] = []string{name}
					}
				}
				sum := sha256.Sum256([]byte(name))
				leafName := RoutingGroupName(o.ID) + " / node-" + hex.EncodeToString(sum[:8])
				leaf := smartGroup(leafName, nil, providers)
				set(leaf, "type", scalar("select"))
				set(leaf, "uselightgbm", nil)
				set(leaf, "collectdata", nil)
				if err := appendGroup(leaf); err != nil {
					return err
				}
				ordered = append(ordered, leafName)
			}
			set(g, "proxies", sequence(ordered...))
			set(g, "use", nil)
			set(g, "filter", nil)
		}
		for key, raw := range o.Options {
			n, err := jsonNode(raw)
			if err != nil {
				return err
			}
			set(g, key, n)
		}
		if err := appendGroup(g); err != nil {
			return err
		}
	}
	rules := sequence("IP-CIDR,127.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve", "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve", "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve", "IP-CIDR6,::1/128,DIRECT,no-resolve", "IP-CIDR6,fc00::/7,DIRECT,no-resolve", "IP-CIDR6,fe80::/10,DIRECT,no-resolve")
	providers := field(root, "rule-providers")
	if providers == nil {
		providers = &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
		set(root, "rule-providers", providers)
	}
	if providers.Kind != yaml.MappingNode {
		return routingFailure()
	}
	emit := func(category, target string) error {
		payload := rulecatalog.Rules(category)
		if len(payload) == 0 {
			return errors.New("ROUTING_RULES_UNAVAILABLE")
		}
		for start := 0; start < len(payload); start += 400 {
			end := start + 400
			if end > len(payload) {
				end = len(payload)
			}
			name := fmt.Sprintf("cexing-%s-%d", strings.ReplaceAll(category, "!", "not-"), start/400)
			if field(providers, name) == nil {
				n := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
				set(n, "type", scalar("inline"))
				set(n, "behavior", scalar("classical"))
				set(n, "payload", sequence(payload[start:end]...))
				set(providers, name, n)
			} else {
				return errors.New("ROUTING_PROVIDER_COLLISION")
			}
			rules.Content = append(rules.Content, scalar("RULE-SET,"+name+","+target))
		}
		return nil
	}
	// Stable two-pass specificity. The aggregate AI never shadows child presets.
	for _, aggregate := range []bool{false, true} {
		for _, r := range p.Routes {
			for _, service := range r.Services {
				if (service == "category-ai-!cn") != aggregate {
					continue
				}
				if err := emit(service, RoutingGroupName(r.Outlet)); err != nil {
					return err
				}
			}
		}
	}
	if err := emit("geolocation-cn", "DIRECT"); err != nil {
		return err
	}
	rules.Content = append(rules.Content, scalar("GEOIP,CN,DIRECT"), scalar("MATCH,"+RoutingGroupName(p.DefaultOutlet)))
	set(root, "rules", rules)
	return nil
}
func intScalar(value int) *yaml.Node {
	return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!int", Value: fmt.Sprint(value)}
}
func boolScalar(value bool) *yaml.Node {
	return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: fmt.Sprint(value)}
}

// A private editor hint keeps new custom rules after LAN and before services.
// It refers to real stable bindings, so personal deletions/reordering do not
// turn a positional guess into an unrelated rule target.
func markRoutingInsertion(out *EditableSnapshot, session *TemplateSession) {
	if session == nil || session.Baseline == nil || session.Baseline.TemplateID != "routing" {
		return
	}
	anchors := map[string]bool{}
	for _, e := range session.Baseline.Entries {
		if e.Section == "rules" && strings.HasPrefix(e.ID, "rule/cexing-") {
			anchors[TemplateTarget("routing", e.ID)] = true
		}
	}
	for si := range out.Sections {
		if out.Sections[si].Section != "rules" {
			continue
		}
		for i := range out.Sections[si].Items {
			if anchors[out.Sections[si].Items[i].ID] {
				out.Sections[si].Items[i].PreferredInsertion = true
				return
			}
		}
	}
}
