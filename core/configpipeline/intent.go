package configpipeline

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	RC "github.com/metacubex/mihomo/rules/common"
	"gopkg.in/yaml.v3"
)

const IntentSchemaVersion = 1
const MaxIntentBytes = 1024 * 1024
const MaxIntentOperations = 512
const MaxEditableSourceBytes = 16 * 1024 * 1024
const MaxEditableItems = 16384

// EditIntent is private per-profile provenance. Field preconditions permit
// rebasing onto newer subscriptions without freezing unrelated source fields.
type EditIntent struct {
	SchemaVersion    int                     `json:"schemaVersion"`
	Revision         string                  `json:"revision"`
	SourceRevision   string                  `json:"sourceRevision"`
	Disabled         bool                    `json:"disabled,omitempty"`
	Operations       []EditOperation         `json:"operations"`
	SmartGroups      map[string]bool         `json:"smartGroups,omitempty"`
	Template         *TemplatePlan           `json:"template,omitempty"`
	TemplateArchives map[string]TemplatePlan `json:"templateArchives,omitempty"`
}
type EditOperation struct {
	TemplateID    string            `json:"templateId,omitempty"`
	ID            string            `json:"id"`
	Kind          string            `json:"kind"` // add, update, delete, move, rename
	Section       string            `json:"section"`
	Target        string            `json:"target,omitempty"`
	Expected      string            `json:"expected,omitempty"`
	Preconditions map[string]string `json:"preconditions,omitempty"`
	Value         json.RawMessage   `json:"value,omitempty"`
	Patch         json.RawMessage   `json:"patch,omitempty"`
	Remove        []string          `json:"remove,omitempty"`
	Before        string            `json:"before,omitempty"` // empty: append
	Name          string            `json:"name,omitempty"`
}

// IntentError deliberately excludes user names, values, IDs and fingerprints.
type IntentError struct {
	Code      string `json:"code"`
	Operation int    `json:"operation"`
}

func (e *IntentError) Error() string           { return "edit intent " + e.Code }
func intentError(code string, index int) error { return &IntentError{Code: code, Operation: index} }

type EditableItem struct {
	PreferredInsertion bool                `json:"preferredInsertion,omitempty"`
	ID                 string              `json:"id"`
	Name               string              `json:"name,omitempty"`
	Disabled           bool                `json:"disabled,omitempty"`
	SourceName         string              `json:"sourceName,omitempty"`
	Providers          []EditorProviderRef `json:"providers,omitempty"`
	Revision           string              `json:"revision"`
	Type               string              `json:"type,omitempty"`
	Fields             map[string]string   `json:"fields,omitempty"`
}
type EditableSection struct {
	Section string         `json:"section"`
	Items   []EditableItem `json:"items"`
}
type EditableSnapshot struct {
	SourceRevision       string            `json:"sourceRevision"`
	MissingFieldRevision string            `json:"missingFieldRevision"`
	Sections             []EditableSection `json:"sections"`
}

// EditTarget contains sensitive values and is returned only on explicit edit.
type EditTarget struct {
	Item                 EditableItem    `json:"item"`
	MissingFieldRevision string          `json:"missingFieldRevision"`
	Value                json.RawMessage `json:"value"`
	Name                 string          `json:"name,omitempty"`
}

var editableSections = []string{"proxies", "proxy-providers", "proxy-groups", "rules", "rule-providers", "dns", "hosts"}

func editSectionAllowed(section string) bool {
	for _, s := range editableSections {
		if s == section {
			return true
		}
	}
	return false
}
func fingerprint(n *yaml.Node) string {
	var v any
	if n != nil {
		_ = n.Decode(&v)
	}
	b, err := json.Marshal(v)
	if err != nil {
		return ""
	}
	// These DNS maps are consumed in insertion order by the locked parser.
	dns := field(n, "dns")
	if dns == nil {
		dns = n
	}
	orders := [][]string{}
	for _, key := range []string{"nameserver-policy", "proxy-server-nameserver-policy"} {
		if policy := field(dns, key); policy != nil && policy.Kind == yaml.MappingNode {
			orders = append(orders, mappingEditorNames(policy))
		}
	}
	if len(orders) > 0 {
		b, err = json.Marshal(struct {
			Value any
			Order [][]string
		}{v, orders})
		if err != nil {
			return ""
		}
	}
	if n == nil {
		b = []byte("missing field")
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
func targetID(section, name string) string {
	sum := sha256.Sum256([]byte(section + "\x00" + name))
	return hex.EncodeToString(sum[:])
}
func editNodes(root *yaml.Node, section string) ([]*yaml.Node, []string, error) {
	n := field(root, section)
	if n == nil {
		if section == "dns" {
			return []*yaml.Node{{Kind: yaml.MappingNode, Tag: "!!map"}}, []string{"dns"}, nil
		}
		return nil, nil, nil
	}
	switch section {
	case "dns":
		if n.Kind != yaml.MappingNode {
			return nil, nil, errors.New("mapping required")
		}
		return []*yaml.Node{n}, []string{"dns"}, nil
	case "proxy-providers", "rule-providers", "hosts":
		if n.Kind != yaml.MappingNode {
			return nil, nil, errors.New("mapping required")
		}
		nodes, names := []*yaml.Node{}, []string{}
		for i := 0; i < len(n.Content); i += 2 {
			nodes = append(nodes, n.Content[i+1])
			names = append(names, n.Content[i].Value)
		}
		return nodes, names, nil
	default:
		if n.Kind != yaml.SequenceNode {
			return nil, nil, errors.New("sequence required")
		}
		names := []string{}
		counts := map[string]int{}
		for _, entry := range n.Content {
			if section == "rules" {
				key := fingerprint(entry)
				counts[key]++
				names = append(names, fmt.Sprintf("%s:%d", key, counts[key]))
			} else {
				name := field(entry, "name")
				if name == nil || name.Tag != "!!str" {
					return nil, nil, errors.New("name required")
				}
				names = append(names, name.Value)
			}
		}
		// A changed duplicate count must not silently redirect a positional edit.
		if section == "rules" {
			for i, entry := range n.Content {
				names[i] += fmt.Sprintf(":%d", counts[fingerprint(entry)])
			}
		}
		return n.Content, names, nil
	}
}
func editableItem(section, name string, n *yaml.Node, explicit bool) EditableItem {
	item := EditableItem{ID: targetID(section, name), Revision: fingerprint(n)}
	if section == "rules" && n.Kind == yaml.ScalarNode {
		tp, _, _, _ := RC.ParseRulePayload(n.Value, true)
		for _, allowed := range strings.Fields("DOMAIN DOMAIN-SUFFIX DOMAIN-KEYWORD IP-CIDR IP-CIDR6 GEOIP GEOSITE RULE-SET MATCH AND OR NOT SUB-RULE") {
			if tp == allowed {
				item.Type = allowed
				break
			}
		}
	}
	if kind := field(n, "type"); kind != nil {
		for _, allowed := range strings.Fields("direct reject select url-test fallback load-balance smart relay http file inline ss ssr vmess vless trojan socks5 hysteria2 tuic wireguard") {
			if kind.Value == allowed {
				item.Type = allowed
			}
		}
	}
	// Arbitrary mapping keys may be private domains; summaries contain no keys.
	if explicit && n.Kind == yaml.MappingNode {
		item.Fields = map[string]string{}
		for i := 0; i < len(n.Content); i += 2 {
			item.Fields[n.Content[i].Value] = fieldFingerprint(section, n.Content[i].Value, n.Content[i+1])
		}
	}
	return item
}

// ReadEditable uses the same merged view as Compile, without I/O/publication.
func ReadEditable(original, global, local []byte) (EditableSnapshot, error) {
	if len(original) > MaxEditableSourceBytes || len(global) > MaxEditableSourceBytes || len(local) > MaxEditableSourceBytes {
		return EditableSnapshot{}, intentError("limit", -1)
	}
	root, err := LayeredMergeSource(original, global, local)
	if err != nil {
		return EditableSnapshot{}, intentError("invalid_source", -1)
	}
	return snapshotEditable(root)
}

func snapshotEditable(root *yaml.Node) (EditableSnapshot, error) {
	s := EditableSnapshot{SourceRevision: fingerprint(root), MissingFieldRevision: MissingFieldRevision(), Sections: []EditableSection{}}
	if s.SourceRevision == "" {
		return EditableSnapshot{}, intentError("invalid_source", -1)
	}
	total := 0
	for _, section := range editableSections {
		nodes, names, err := editNodes(root, section)
		if err != nil {
			return EditableSnapshot{}, intentError("invalid_source", -1)
		}
		total += len(nodes)
		if total > MaxEditableItems {
			return EditableSnapshot{}, intentError("limit", -1)
		}
		out := EditableSection{Section: section, Items: []EditableItem{}}
		for i, n := range nodes {
			out.Items = append(out.Items, editableItem(section, names[i], n, false))
		}
		s.Sections = append(s.Sections, out)
	}
	return s, nil
}

// ReadEditTarget must not be used by logs, support exports or default previews.
func ReadEditTarget(original, global, local []byte, section, id string) (EditTarget, error) {
	if len(original) > MaxEditableSourceBytes || len(global) > MaxEditableSourceBytes || len(local) > MaxEditableSourceBytes {
		return EditTarget{}, intentError("limit", -1)
	}
	if !editSectionAllowed(section) {
		return EditTarget{}, intentError("protected_section", -1)
	}
	root, err := LayeredMergeSource(original, global, local)
	if err != nil {
		return EditTarget{}, intentError("invalid_source", -1)
	}
	return editTargetFromRoot(root, section, id)
}

func editTargetFromRoot(root *yaml.Node, section, id string) (EditTarget, error) {
	if !editSectionAllowed(section) {
		return EditTarget{}, intentError("protected_section", -1)
	}
	nodes, names, err := editNodes(root, section)
	if err != nil {
		return EditTarget{}, intentError("invalid_source", -1)
	}
	if len(nodes) > MaxEditableItems {
		return EditTarget{}, intentError("limit", -1)
	}
	for i, n := range nodes {
		if targetID(section, names[i]) == id {
			var v any
			if err := n.Decode(&v); err != nil {
				return EditTarget{}, intentError("invalid_source", -1)
			}
			b, err := json.Marshal(v)
			if err != nil {
				return EditTarget{}, intentError("invalid_source", -1)
			}
			return EditTarget{Item: editableItem(section, names[i], n, true), MissingFieldRevision: MissingFieldRevision(), Value: b, Name: names[i]}, nil
		}
	}
	return EditTarget{}, intentError("missing_target", -1)
}

// MissingFieldRevision is the precondition for adding a previously absent field.
func MissingFieldRevision() string { return fingerprint(nil) }
func DecodeEditIntent(data []byte) (*EditIntent, error) {
	if len(data) > MaxIntentBytes {
		return nil, intentError("limit", -1)
	}
	var intent EditIntent
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&intent); err != nil {
		return nil, intentError("invalid_schema", -1)
	}
	if dec.Decode(new(any)) != io.EOF {
		return nil, intentError("invalid_schema", -1)
	}
	if err := CheckEditIntent(&intent); err != nil {
		return nil, err
	}
	return &intent, nil
}
func CheckEditIntent(intent *EditIntent) error {
	if intent == nil {
		return nil
	}
	data, err := json.Marshal(intent)
	if err != nil || len(data) > MaxIntentBytes || len(intent.Operations) > MaxIntentOperations || len(intent.SmartGroups) > 512 || len(intent.TemplateArchives) > 4 {
		return intentError("limit", -1)
	}
	if intent.SchemaVersion != 1 || intent.Revision == "" || intent.SourceRevision == "" || intent.Operations == nil {
		return intentError("invalid_schema", -1)
	}
	if intent.Template != nil {
		if err := intent.Template.Validate(); err != nil {
			return intentError("invalid_template", -1)
		}
	}
	for id, plan := range intent.TemplateArchives {
		if !validTemplateOwner(id) || plan.TemplateID != id || plan.Validate() != nil {
			return intentError("invalid_template", -1)
		}
	}
	ids := map[string]bool{}
	for i, op := range intent.Operations {
		if op.ID == "" || ids[op.ID] || (op.TemplateID != "" && !validTemplateOwner(op.TemplateID)) {
			return intentError("invalid_operation", i)
		}
		if op.TemplateID != "" && (intent.Template == nil || intent.Template.TemplateID != op.TemplateID) {
			if _, exists := intent.TemplateArchives[op.TemplateID]; !exists {
				return intentError("invalid_template", i)
			}
		}
		ids[op.ID] = true
		if !editSectionAllowed(op.Section) {
			return intentError("protected_section", i)
		}
		switch op.Kind {
		case "add", "update", "delete", "move", "rename", "disable":
		default:
			return intentError("invalid_operation", i)
		}

	}
	return nil
}
func jsonNode(data json.RawMessage) (*yaml.Node, error) {
	if len(data) == 0 || !json.Valid(data) {
		return nil, errors.New("value required")
	}
	// Decode JSON through YAML's integer-aware decoder, avoiding float64 port loss.
	wrapped := append([]byte("value: "), data...)
	root, err := parse(wrapped)
	if err != nil {
		return nil, err
	}
	return field(root, "value"), nil
}

// ApplyEditIntent mutates Compile's private post-Merge view. Undo means removing
// an operation or disabling the intent and recompiling the latest input.
func ApplyEditIntent(ctx context.Context, root *yaml.Node, intent *EditIntent) error {
	return applyBoundEditIntent(ctx, root, intent, nil, nil)
}
func applyBoundEditIntent(ctx context.Context, root *yaml.Node, intent *EditIntent, bindings map[string]*yaml.Node, disabled map[*yaml.Node]bool) error {
	return applyEditIntentPhase(ctx, root, intent, bindings, disabled, nil, 0)
}

// phase 0: normal batch; 1: provider resources; 2: remaining personal edits.
func applyEditIntentPhase(ctx context.Context, root *yaml.Node, intent *EditIntent, bindings map[string]*yaml.Node, disabled map[*yaml.Node]bool, state *editPhaseState, phase int) error {
	if err := CheckEditIntent(intent); err != nil {
		return err
	}
	if intent == nil || intent.Disabled || len(intent.Operations) == 0 {
		return nil
	}
	sections := map[string]string{}
	if intent.Template != nil && intent.Template.Mine != nil {
		for _, e := range intent.Template.Mine.Entries {
			sections[TemplateTarget(intent.Template.TemplateID, e.ID)] = e.Section
		}
	}
	if state == nil {
		base, err := snapshotEditBaselines(ctx, root)
		if err != nil {
			return err
		}
		state = &editPhaseState{baselines: base}
	}
	baselines := state.baselines
	var aliases map[string]*yaml.Node
	if phase == 2 {
		aliases = state.aliases
	}
	for i, op := range intent.Operations {
		if !activeTemplateOperation(intent, op) {
			continue
		}
		resource := op.Section == "proxy-providers" || op.Section == "rule-providers"
		if (phase == 1 && !resource) || (phase == 2 && resource) {
			continue
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		oldName := ""
		if phase == 1 && resource && op.Kind == "rename" {
			nodes, names, _ := editNodes(root, op.Section)
			for j, n := range nodes {
				if boundID(bindings, n, targetID(op.Section, names[j])) == op.Target {
					oldName = names[j]
					break
				}
			}
		}
		var before []*yaml.Node
		var touched *yaml.Node
		if phase == 2 && (op.Kind == "add" || op.Kind == "update") {
			var names []string
			before, names, _ = editNodes(root, op.Section)
			before = append([]*yaml.Node(nil), before...)
			for j, n := range before {
				if boundID(bindings, n, targetID(op.Section, names[j])) == op.Target || aliases[op.Target] == n {
					touched = n
					break
				}
			}
		}
		op = routingDisplayRevision(op, intent, bindings)
		if err := applyEditOperation(root, op, baselines, bindings, sections, disabled, aliases); err != nil {
			var typed *IntentError
			if errors.As(err, &typed) {
				return intentError(typed.Code, i)
			}
			return intentError("invalid_operation", i)
		}
		if oldName != "" {
			state.renames = append(state.renames, resourceRename{index: i, section: op.Section, old: oldName, next: op.Name})
		}
		if phase == 2 && (op.Kind == "add" || op.Kind == "update") {
			if err := projectDeferredReferences(root, op, i, before, touched, state); err != nil {
				return intentError("invalid_operation", i)
			}
		}
	}
	return nil
}
func applyEditOperation(root *yaml.Node, op EditOperation, baselines map[*yaml.Node]*yaml.Node, bindings map[string]*yaml.Node, sections map[string]string, disabled map[*yaml.Node]bool, aliases map[string]*yaml.Node) error {
	fail := func(code string) error { return intentError(code, -1) }
	nodes, names, err := editNodes(root, op.Section)
	if err != nil {
		return fail("invalid_source")
	}
	position := -1
	for i, name := range names {
		if boundID(bindings, nodes[i], targetID(op.Section, name)) == op.Target || aliases[op.Target] == nodes[i] {
			position = i
			break
		}
	}
	container := field(root, op.Section)
	if op.Kind == "add" {
		if op.Target != "" {
			n, known := bindings[op.Target]
			if !known || n != nil || sections[op.Target] != op.Section {
				return fail("invalid_target")
			}
		}
		value, err := jsonNode(op.Value)
		if err != nil {
			return fail("invalid_value")
		}
		switch op.Section {
		case "dns":
			return fail("invalid_operation")
		case "proxies", "proxy-groups":
			name := field(value, "name")
			if name == nil || name.Tag != "!!str" || name.Value == "" {
				return fail("invalid_value")
			}
			for _, old := range names {
				if old == name.Value {
					return fail("conflict")
				}
			}
		case "rules":
			if value.Tag != "!!str" {
				return fail("invalid_value")
			}
		default:
			if op.Name == "" || field(container, op.Name) != nil {
				return fail("conflict")
			}
		}
		if container == nil {
			kind, tag := yaml.SequenceNode, "!!seq"
			if op.Section == "hosts" || strings.HasSuffix(op.Section, "providers") {
				kind, tag = yaml.MappingNode, "!!map"
			}
			container = &yaml.Node{Kind: kind, Tag: tag}
			set(root, op.Section, container)
		}
		if container.Kind == yaml.MappingNode {
			set(container, op.Name, value)
			if op.Target != "" {
				bindings[op.Target] = value
			}
			return nil
		}
		at, err := boundEditAnchor(op.Section, nodes, names, op.Before, bindings, aliases)
		if err != nil {
			return err
		}
		container.Content = append(container.Content, nil)
		copy(container.Content[at+1:], container.Content[at:])
		container.Content[at] = value
		if op.Target != "" {
			bindings[op.Target] = value
		}
		return nil
	}
	if position < 0 {
		if op.Kind == "delete" {
			if op.Section == "rules" {
				for _, n := range nodes {
					if fingerprint(n) == op.Expected {
						return fail("conflict")
					}
				}
			}
			return nil
		}
		return fail("missing_target")
	}
	node := nodes[position]
	baseline := baselines[node]
	if baseline == nil {
		baseline, err = normalize(node, map[*yaml.Node]bool{})
		if err != nil {
			return fail("invalid_source")
		}
		baselines[node] = baseline
	}
	matchesRevision := func(expected string) bool {
		return expected != "" && (fingerprint(node) == expected || fingerprint(baseline) == expected)
	}
	if op.Section == "dns" && container == nil {
		set(root, "dns", node)
	}
	switch op.Kind {
	case "disable":
		if op.Section != "proxies" {
			return fail("invalid_operation")
		}
		if !matchesRevision(op.Expected) {
			return fail("conflict")
		}
		name := field(node, "name")
		if name == nil || name.Tag != "!!str" {
			return fail("invalid_source")
		}
		// Fail closed under the same name: references and rule priority stay intact.
		replacement := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
		set(replacement, "name", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: name.Value})
		set(replacement, "type", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: "reject"})
		*node = *replacement
		if disabled != nil {
			disabled[node] = true
		}
	case "update":
		if node.Kind != yaml.MappingNode {
			if !matchesRevision(op.Expected) {
				return fail("conflict")
			}
			value, err := jsonNode(op.Value)
			if err != nil {
				return fail("invalid_value")
			}
			if op.Section == "rules" && value.Tag != "!!str" {
				return fail("invalid_value")
			}
			baselines[value] = baseline
			rebind(bindings, node, value)
			rebind(aliases, node, value)
			if container.Kind == yaml.MappingNode {
				set(container, names[position], value)
			} else {
				container.Content[position] = value
			}
			return nil
		}
		patch, err := jsonNode(op.Patch)
		if err != nil || patch.Kind != yaml.MappingNode {
			return fail("invalid_value")
		}
		keys := append([]string(nil), op.Remove...)
		for i := 0; i < len(patch.Content); i += 2 {
			keys = append(keys, patch.Content[i].Value)
		}
		seen := map[string]bool{}
		for _, key := range keys {
			if seen[key] || key == "name" || (op.Section == "dns" && key == "listen") {
				return fail("protected_field")
			}
			seen[key] = true
			expected, ok := op.Preconditions[key]
			if !ok || (fieldFingerprint(op.Section, key, field(node, key)) != expected && fieldFingerprint(op.Section, key, field(baseline, key)) != expected) {
				return fail("conflict")
			}
		}
		for i := 0; i < len(patch.Content); i += 2 {
			set(node, patch.Content[i].Value, patch.Content[i+1])
		}
		for _, key := range op.Remove {
			set(node, key, nil)
		}
	case "delete":
		if !matchesRevision(op.Expected) {
			return fail("conflict")
		}
		if op.Section == "dns" {
			return fail("protected_field")
		}
		rebind(bindings, node, nil)
		rebind(aliases, node, nil)
		if container.Kind == yaml.MappingNode {
			set(container, names[position], nil)
		} else {
			container.Content = append(container.Content[:position], container.Content[position+1:]...)
		}
	case "move":
		if container.Kind != yaml.SequenceNode {
			return fail("invalid_operation")
		}
		if op.Before == op.Target {
			return nil
		}
		at, err := boundEditAnchor(op.Section, nodes, names, op.Before, bindings, aliases)
		if err != nil {
			return err
		}
		container.Content = append(container.Content[:position], container.Content[position+1:]...)
		if position < at {
			at--
		}
		container.Content = append(container.Content, nil)
		copy(container.Content[at+1:], container.Content[at:])
		container.Content[at] = node
	case "rename":
		if op.Section == "rules" || op.Section == "dns" || op.Section == "hosts" || op.Name == "" || strings.ContainsAny(op.Name, ",\r\n") {
			return fail("invalid_operation")
		}
		if !matchesRevision(op.Expected) {
			return fail("conflict")
		}
		for _, name := range names {
			if name == op.Name {
				return fail("conflict")
			}
		}
		old := names[position]
		if container.Kind == yaml.MappingNode {
			container.Content[position*2].Value = op.Name
		} else {
			set(node, "name", scalar(op.Name))
		}
		renameReferences(root, op.Section, old, op.Name)
	default:
		return fail("invalid_operation")
	}
	return nil
}
func renameReferences(root *yaml.Node, section, old, name string) {
	for _, key := range []string{"proxies", "proxy-groups", "listeners"} {
		if list := field(root, key); list != nil {
			for _, n := range list.Content {
				if section == "proxies" || section == "proxy-groups" {
					for _, refKey := range []string{"dialer-proxy", "proxy"} {
						if ref := field(n, refKey); ref != nil && ref.Value == old {
							ref.Value = name
						}
					}
				}
				memberKey := "proxies"
				if section == "proxy-providers" {
					memberKey = "use"
				}
				if section != "rule-providers" {
					if list := field(n, memberKey); list != nil {
						for _, ref := range list.Content {
							if ref.Value == old {
								ref.Value = name
							}
						}
					}
				}
			}
		}
	}
	lists := []*yaml.Node{field(root, "rules")}
	if sub := field(root, "sub-rules"); sub != nil {
		for i := 1; i < len(sub.Content); i += 2 {
			lists = append(lists, sub.Content[i])
		}
	}
	for _, list := range lists {
		if list != nil {
			for _, rule := range list.Content {
				tp, payload, target, params := RC.ParseRulePayload(rule.Value, true)
				if (section == "proxies" || section == "proxy-groups") && tp != "SUB-RULE" && target == old {
					// The locked parser reports trailing params separately. Complex
					// payloads may contain commas, but their target is the last token;
					// ordinary rules place it before those params. MATCH uses token 1.
					index := len(strings.Split(rule.Value, ",")) - len(params) - 1
					if tp == "MATCH" {
						index = 1
					}
					rule.Value = replaceRuleToken(rule.Value, index, old, name)
				}
				if section == "rule-providers" && tp == "RULE-SET" && payload == old {
					rule.Value = replaceRuleToken(rule.Value, 1, old, name)
				}
			}
		}
	}
}

// replaceRuleToken preserves payloads, parameter text and spaces exactly. It
// never interprets a token prefix as a reference (e.g. no versus no-resolve).
func replaceRuleToken(raw string, index int, old, name string) string {
	parts := strings.Split(raw, ",")
	if index < 0 || index >= len(parts) || strings.Trim(parts[index], " ") != old {
		return raw
	}
	token := parts[index]
	start := len(token) - len(strings.TrimLeft(token, " "))
	parts[index] = token[:start] + name + token[start+len(old):]
	return strings.Join(parts, ",")
}

// Editable and EditTarget project saved/draft intent for the host editor using
// the same template/region/edit order as Compile, but no full validation or I/O.
func (c Compiler) Editable(ctx context.Context, r Request) (EditableSnapshot, error) {
	root, session, err := c.boundEditSource(ctx, r)
	if err != nil {
		return EditableSnapshot{}, err
	}
	out, err := snapshotEditable(root)
	aliasSnapshot(root, &out, sessionTargets(session))
	markRoutingInsertion(&out, session)
	return out, err
}
func (c Compiler) EditTarget(ctx context.Context, r Request, section, id string) (EditTarget, error) {
	if !editSectionAllowed(section) {
		return EditTarget{}, intentError("protected_section", -1)
	}
	root, session, err := c.boundEditSource(ctx, r)
	if err != nil {
		return EditTarget{}, err
	}
	bindings := sessionTargets(session)
	nodes, names, err := editNodes(root, section)
	if err != nil {
		return EditTarget{}, intentError("invalid_source", -1)
	}
	if len(nodes) > MaxEditableItems {
		return EditTarget{}, intentError("limit", -1)
	}
	for i, node := range nodes {
		if boundID(bindings, node, targetID(section, names[i])) == id {
			out, err := editTargetFromRoot(root, section, targetID(section, names[i]))
			out.Item.ID = id
			out.Item.Disabled = session.DisabledNodes[node] && field(node, "type") != nil && field(node, "type").Value == "reject"
			if section == "proxy-groups" || section == "proxies" {
				out.Item.SourceName = session.SourceGroups[node]
			}
			return out, err
		}
	}
	return EditTarget{}, intentError("missing_target", -1)
}
func (c Compiler) editSource(ctx context.Context, r Request) (*yaml.Node, error) {
	root, _, err := c.boundEditSource(ctx, r)
	return root, err
}
func (c Compiler) boundEditSource(ctx context.Context, r Request) (*yaml.Node, *TemplateSession, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	if len(r.Original) > MaxEditableSourceBytes {
		return nil, nil, intentError("limit", -1)
	}
	for _, layer := range r.Overlays {
		if len(layer) > MaxEditableSourceBytes {
			return nil, nil, intentError("limit", -1)
		}
	}
	root, err := parse(r.Original)
	if err != nil {
		return nil, nil, intentError("invalid_source", -1)
	}
	if err := rejectRuntimeCredential(root); err != nil {
		return nil, nil, intentError("invalid_source", -1)
	}
	for _, layer := range r.Overlays {
		patch, err := parse(layer)
		if err != nil {
			return nil, nil, intentError("invalid_source", -1)
		}
		if err := rejectRuntimeCredential(patch); err != nil {
			return nil, nil, intentError("invalid_source", -1)
		}
		merge(root, patch)
	}
	sourceGroups := map[*yaml.Node]string{}
	for _, sourceSection := range []string{"proxy-groups", "proxies"} {
		nodes, names, err := editNodes(root, sourceSection)
		if err != nil {
			return nil, nil, intentError("invalid_source", -1)
		}
		for i, n := range nodes {
			sourceGroups[n] = names[i]
		}
	}
	baselines, phase, err := prepareRegionResources(ctx, root, r)
	if err != nil {
		return nil, nil, err
	}
	if r.Region != nil && !r.Region.Disabled && (r.Intent == nil || r.Intent.Disabled || r.Intent.Template == nil) {
		if err := ApplyRegion(ctx, root, *r.Region); err != nil {
			return nil, nil, intentError("region_failed", -1)
		}
	}
	session, err := c.prepareIntentTemplate(ctx, root, r.Intent)
	if err != nil {
		return nil, nil, err
	}
	if session == nil {
		session = &TemplateSession{}
	}
	session.SourceGroups = sourceGroups
	session.DisabledNodes = map[*yaml.Node]bool{}
	if err := supportedTags(root, false, map[*yaml.Node]bool{}); err != nil {
		return nil, nil, intentError("invalid_source", -1)
	}
	if err := rejectRuntimeCredential(root); err != nil {
		return nil, nil, intentError("invalid_source", -1)
	}
	// Validate callback output without replacing nodes and orphaning bindings.
	encoded, err := yaml.Marshal(root)
	if err != nil {
		return nil, nil, intentError("invalid_source", -1)
	}
	if _, err := parse(encoded); err != nil {
		return nil, nil, intentError("invalid_source", -1)
	}
	if err := applyEditIntentPhase(ctx, root, r.Intent, sessionTargets(session), session.DisabledNodes, baselines, phase); err != nil {
		return nil, nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	return root, session, nil
}

// EditorProviderRef describes local declarations only. These states never claim
// loaded resources, healthy nodes or successful forwarding.
type EditorProviderRef struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Type  string `json:"type,omitempty"`
	State string `json:"state"` // declared, inline, missing
	Count int    `json:"count,omitempty"`
}

func providerEditorRef(root *yaml.Node, section, name string) EditorProviderRef {
	ref := EditorProviderRef{ID: targetID(section, name), Name: name, State: "missing"}
	n := field(field(root, section), name)
	if n == nil {
		return ref
	}
	ref.State = "declared"
	if kind := field(n, "type"); kind != nil {
		for _, allowed := range []string{"file", "http", "inline"} {
			if kind.Value == allowed {
				ref.Type = allowed
			}
		}
	}
	if ref.Type == "inline" {
		ref.State = "inline"
		ref.Count = size(field(n, "payload"))
	}
	return ref
}

// EditorList is a sensitive editing action, distinct from the default summary.
// Names are needed for selecting targets; passwords/addresses/URLs/raw rules and
// arbitrary YAML values remain available only through explicit EditTarget.
func (c Compiler) EditorList(ctx context.Context, r Request) (EditableSnapshot, error) {
	root, session, err := c.boundEditSource(ctx, r)
	if err != nil {
		return EditableSnapshot{}, err
	}
	out, err := snapshotEditable(root)
	if err != nil {
		return EditableSnapshot{}, err
	}
	aliasSnapshot(root, &out, sessionTargets(session))
	markRoutingInsertion(&out, session)
	for si := range out.Sections {
		section := out.Sections[si].Section
		nodes, names, err := editNodes(root, section)
		if err != nil {
			return EditableSnapshot{}, intentError("invalid_source", -1)
		}
		for i, n := range nodes {
			item := &out.Sections[si].Items[i]
			item.Disabled = session.DisabledNodes[n] && field(n, "type") != nil && field(n, "type").Value == "reject"
			item.Name = names[i]
			if section == "proxy-groups" || section == "proxies" {
				item.SourceName = session.SourceGroups[n]
			}
			if section == "rules" {
				item.Name = fmt.Sprintf("规则 %d", i+1)
			}
			if section == "dns" {
				item.Name = "DNS"
			}
			if section == "proxy-providers" || section == "rule-providers" {
				item.Providers = []EditorProviderRef{providerEditorRef(root, section, names[i])}
			}
			if section == "proxy-groups" {
				used := map[string]bool{}
				if list := field(n, "use"); list != nil && list.Kind == yaml.SequenceNode {
					for _, v := range list.Content {
						if v.Tag == "!!str" && !used[v.Value] {
							item.Providers = append(item.Providers, providerEditorRef(root, "proxy-providers", v.Value))
							used[v.Value] = true
						}
					}
				}
				all, providers := field(n, "include-all"), field(n, "include-all-providers")
				if (all != nil && all.Value == "true") || (providers != nil && providers.Value == "true") {
					for _, name := range mappingEditorNames(field(root, "proxy-providers")) {
						if !used[name] {
							item.Providers = append(item.Providers, providerEditorRef(root, "proxy-providers", name))
							used[name] = true
						}
					}
				}
			}
		}
	}
	return out, nil
}
func mappingEditorNames(n *yaml.Node) []string {
	names := []string{}
	if n != nil && n.Kind == yaml.MappingNode {
		for i := 0; i < len(n.Content); i += 2 {
			names = append(names, n.Content[i].Value)
		}
	}
	return names
}

func fieldFingerprint(section, key string, n *yaml.Node) string {
	if n == nil {
		return MissingFieldRevision()
	}
	if section != "dns" || (key != "nameserver-policy" && key != "proxy-server-nameserver-policy") {
		return fingerprint(n)
	}
	var value any
	if err := n.Decode(&value); err != nil {
		return ""
	}
	data, err := json.Marshal(struct {
		Value any
		Order []string
	}{value, mappingEditorNames(n)})
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func snapshotEditBaselines(ctx context.Context, root *yaml.Node) (map[*yaml.Node]*yaml.Node, error) {
	baselines := map[*yaml.Node]*yaml.Node{}
	// Snapshot every original target before any reference rewrite touches it.
	for _, section := range editableSections {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		nodes, _, err := editNodes(root, section)
		if err != nil {
			return nil, intentError("invalid_source", -1)
		}
		for _, node := range nodes {
			base, err := normalize(node, map[*yaml.Node]bool{})
			if err != nil {
				return nil, intentError("invalid_source", -1)
			}
			baselines[node] = base
		}
	}
	return baselines, nil
}
