package profiletemplates

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"reflect"
	"regexp"
	"sort"

	"core/configpipeline"
)

// Entity is a template-owned logical item, not an entire upstream section. IDs
// are authored stable IDs (e.g. ai/chatgpt), independent of names/list position.
// Values are private compiler snapshots. Never log/export them in diagnostics.
type Entity = configpipeline.TemplateEntity
type TemplateSnapshot = configpipeline.TemplateSnapshot
type UpdateRequest struct {
	Kind      string            `json:"kind"` // template upgrade or subscription rebase, never provider refresh
	Base      TemplateSnapshot  `json:"base"`
	Mine      TemplateSnapshot  `json:"mine"`
	Next      TemplateSnapshot  `json:"next"`
	Decisions map[string]string `json:"decisions,omitempty"` // opaque conflict ID -> mine/template
}
type TemplateConflict struct {
	ID      string   `json:"id"`
	Entity  string   `json:"entity"`
	Section string   `json:"section"`
	Path    []string `json:"path,omitempty"` // private field identity, details only
	Kind    string   `json:"kind"`
}
type UpdatePreview struct {
	Ready     bool               `json:"ready"`
	Candidate *TemplateSnapshot  `json:"candidate,omitempty"`
	Conflicts []TemplateConflict `json:"conflicts"`
}

var entityID = regexp.MustCompile(`^[a-z][a-z0-9_./-]{0,127}$`)
var templateSections = []string{"proxies", "proxy-providers", "proxy-groups", "rules", "rule-providers", "dns", "hosts"}

type entityValue struct {
	section string
	value   any
}
type updateMerge struct {
	ctx       context.Context
	request   UpdateRequest
	conflicts []TemplateConflict
	seen      map[string]bool
}

func snapshot(s TemplateSnapshot) (map[string]entityValue, error) {
	fail := errors.New("TEMPLATE_BASELINE_INVALID")
	if !entityID.MatchString(s.TemplateID) || s.Version < 1 || len(s.Entries) > 512 {
		return nil, fail
	}
	out := map[string]entityValue{}
	total := 0
	for _, e := range s.Entries {
		if !entityID.MatchString(e.ID) || !validSection(e.Section) || !json.Valid(e.Value) || len(e.Value) > 64*1024 {
			return nil, fail
		}
		if _, ok := out[e.ID]; ok {
			return nil, fail
		}
		total += len(e.Value)
		if total > 1024*1024 {
			return nil, fail
		}
		// Use the existing normalized YAML parser, including duplicate-key/tag
		// rejection. JSON values arrive from the common compiler, not another parser.
		wrapped := append([]byte(`{"item":`), e.Value...)
		wrapped = append(wrapped, '}')
		root, err := configpipeline.LayeredMergeSource(wrapped, nil, nil)
		if err != nil {
			return nil, fail
		}
		var value any
		if field(root, "item").Decode(&value) != nil {
			return nil, fail
		}
		out[e.ID] = entityValue{e.Section, value}
	}
	deletedIDs := map[string]bool{}
	for _, id := range s.Deleted {
		if !entityID.MatchString(id) || deletedIDs[id] {
			return nil, fail
		}
		if _, ok := out[id]; ok {
			return nil, fail
		}
		deletedIDs[id] = true
	}
	if len(s.Deleted) > 512 {
		return nil, fail
	}
	return out, nil
}
func validSection(section string) bool {
	for _, s := range templateSections {
		if section == s {
			return true
		}
	}
	return false
}
func same(a any, ae bool, b any, be bool) bool { return ae == be && (!ae || reflect.DeepEqual(a, b)) }

// PreviewUpdate is pure: no config files, version pointers, network or global
// state. A ready result is a candidate only; it must be translated to the common
// EditIntent and validated/published by the existing transaction gate. The caller
// retains Base/Mine until that publication succeeds; cancellation is reversible.
func PreviewUpdate(ctx context.Context, r UpdateRequest) (UpdatePreview, error) {
	if err := ctx.Err(); err != nil {
		return UpdatePreview{}, err
	}
	if r.Kind != "template" && r.Kind != "subscription" {
		return UpdatePreview{}, errors.New("TEMPLATE_UPDATE_KIND_INVALID")
	}
	if r.Base.TemplateID != r.Mine.TemplateID || r.Base.TemplateID != r.Next.TemplateID || r.Mine.Version != r.Base.Version ||
		(r.Kind == "template" && r.Next.Version <= r.Base.Version) || (r.Kind == "subscription" && r.Next.Version != r.Base.Version) {
		return UpdatePreview{}, errors.New("TEMPLATE_BASELINE_MISMATCH")
	}
	if len(r.Decisions) > 1024 {
		return UpdatePreview{}, errors.New("TEMPLATE_DECISION_INVALID")
	}
	for _, choice := range r.Decisions {
		if choice != "mine" && choice != "template" {
			return UpdatePreview{}, errors.New("TEMPLATE_DECISION_INVALID")
		}
	}
	if len(r.Base.Deleted) != 0 || len(r.Next.Deleted) != 0 {
		return UpdatePreview{}, errors.New("TEMPLATE_BASELINE_INVALID")
	}
	base, err := snapshot(r.Base)
	if err != nil {
		return UpdatePreview{}, err
	}
	mine, err := snapshot(r.Mine)
	if err != nil {
		return UpdatePreview{}, err
	}
	next, err := snapshot(r.Next)
	if err != nil {
		return UpdatePreview{}, err
	}
	merger := &updateMerge{ctx: ctx, request: r, conflicts: []TemplateConflict{}, seen: map[string]bool{}}
	all := map[string]bool{}
	for k := range base {
		all[k] = true
	}
	for k := range mine {
		all[k] = true
	}
	for k := range next {
		all[k] = true
	}
	ids := make([]string, 0, len(all))
	for id := range all {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	deleted := map[string]bool{}
	for _, id := range r.Mine.Deleted {
		deleted[id] = true
	}
	for id := range base {
		if _, ok := mine[id]; !ok {
			deleted[id] = true
		}
	}
	merged := map[string]entityValue{}
	for _, id := range ids {
		if err := ctx.Err(); err != nil {
			return UpdatePreview{}, err
		}
		a, ae := base[id]
		b, be := mine[id]
		c, ce := next[id]
		section := ""
		for _, v := range []entityValue{a, b, c} {
			if v.section != "" {
				if section != "" && v.section != section {
					return UpdatePreview{}, errors.New("TEMPLATE_SECTION_CHANGED")
				}
				section = v.section
			}
		}
		// A personal tombstone survives an upstream deletion and later re-add.
		// An explicit restore removes the tombstone from Mine.
		if deleted[id] && !ae && !be {
			continue
		}
		value, present := merger.merge(id, section, nil, a.value, ae, b.value, be, c.value, ce)
		if present {
			merged[id] = entityValue{section, value}
		}
	}
	candidate := TemplateSnapshot{TemplateID: r.Next.TemplateID, Version: r.Next.Version, Entries: []Entity{}}
	for id := range deleted {
		if _, present := merged[id]; !present {
			candidate.Deleted = append(candidate.Deleted, id)
		}
	}
	sort.Strings(candidate.Deleted)
	for _, section := range templateSections {
		order := merger.order(section, merged)
		for _, id := range order {
			value := merged[id]
			encoded, err := json.Marshal(value.value)
			if err != nil {
				return UpdatePreview{}, errors.New("TEMPLATE_VALUE_INVALID")
			}
			candidate.Entries = append(candidate.Entries, Entity{id, section, encoded})
		}
	}
	if err := ctx.Err(); err != nil {
		return UpdatePreview{}, err
	}
	for id := range r.Decisions {
		if !merger.seen[id] {
			return UpdatePreview{}, errors.New("TEMPLATE_DECISION_STALE")
		}
	}
	if len(merger.conflicts) > 0 {
		return UpdatePreview{Conflicts: merger.conflicts}, nil
	}
	// Bound the candidate too: independently valid inputs may produce a larger union.
	if _, err := snapshot(candidate); err != nil {
		return UpdatePreview{}, err
	}
	return UpdatePreview{Ready: true, Candidate: &candidate, Conflicts: []TemplateConflict{}}, nil
}

func (m *updateMerge) merge(id, section string, path []string, a any, ae bool, b any, be bool, c any, ce bool) (any, bool) {
	if same(b, be, c, ce) {
		return b, be
	}
	if same(a, ae, b, be) {
		return c, ce
	}
	if same(a, ae, c, ce) {
		return b, be
	}
	am, aok := a.(map[string]any)
	bm, bok := b.(map[string]any)
	cm, cok := c.(map[string]any)
	if ae && be && ce && aok && bok && cok {
		keys := map[string]bool{}
		for k := range am {
			keys[k] = true
		}
		for k := range bm {
			keys[k] = true
		}
		for k := range cm {
			keys[k] = true
		}
		sorted := make([]string, 0, len(keys))
		for k := range keys {
			sorted = append(sorted, k)
		}
		sort.Strings(sorted)
		out := map[string]any{}
		for _, key := range sorted {
			av, avp := am[key]
			bv, bvp := bm[key]
			cv, cvp := cm[key]
			child := append(append([]string(nil), path...), key)
			value, present := m.merge(id, section, child, av, avp, bv, bvp, cv, cvp)
			if present {
				out[key] = value
			}
		}
		return out, true
	}
	kind := "edit"
	if !be || !ce {
		kind = "delete/edit"
	} else if !ae {
		kind = "add/add"
	}
	choice := m.choice(id, section, path, kind, []any{ae, a, be, b, ce, c})
	if choice == "mine" {
		return b, be
	}
	return c, ce
}
func (m *updateMerge) choice(id, section string, path []string, kind string, values any) string {
	// Bind decisions to all three exact semantic inputs, not merely a field name.
	bytes, _ := json.Marshal([]any{m.request.Base.TemplateID, m.request.Base.Version, m.request.Next.Version, id, section, path, kind, values})
	hash := sha256.Sum256(bytes)
	key := hex.EncodeToString(hash[:])
	m.seen[key] = true
	if choice, ok := m.request.Decisions[key]; ok {
		return choice
	}
	m.conflicts = append(m.conflicts, TemplateConflict{key, id, section, append([]string(nil), path...), kind})
	return ""
}
func filterOrder(s TemplateSnapshot, section string, allowed map[string]bool) []string {
	out := []string{}
	for _, e := range s.Entries {
		if e.Section == section && allowed[e.ID] {
			out = append(out, e.ID)
		}
	}
	return out
}
func (m *updateMerge) order(section string, merged map[string]entityValue) []string {
	allowed := map[string]bool{}
	for id, v := range merged {
		if v.section == section {
			allowed[id] = true
		}
	}
	a, b, c := filterOrder(m.request.Base, section, allowed), filterOrder(m.request.Mine, section, allowed), filterOrder(m.request.Next, section, allowed)
	if section != "rules" && section != "proxies" && section != "proxy-groups" {
		out := make([]string, 0, len(allowed))
		for id := range allowed {
			out = append(out, id)
		}
		sort.Strings(out)
		return out
	}
	common := map[string]bool{}
	for _, id := range a {
		common[id] = true
	}
	for id := range common {
		if !contains(b, id) || !contains(c, id) {
			delete(common, id)
		}
	}
	project := func(in []string) []string {
		out := []string{}
		for _, id := range in {
			if common[id] {
				out = append(out, id)
			}
		}
		return out
	}
	pa, pb, pc := project(a), project(b), project(c)
	commonOrder := pc
	if reflect.DeepEqual(pa, pb) || reflect.DeepEqual(pb, pc) {
	} else if reflect.DeepEqual(pa, pc) {
		commonOrder = pb
	} else if combined, ok := combineOrder(pa, pb, pc); ok {
		commonOrder = combined
	} else if m.choice("order", section, nil, "order", []any{a, b, c}) == "mine" {
		commonOrder = pb
	}
	out := append([]string(nil), commonOrder...)
	// Independent insertions follow their next surviving anchor. Common-item
	// moves merge by pair constraints; incompatible cycles require a decision.
	for _, secondary := range [][]string{c, b} {
		for i, id := range secondary {
			if contains(out, id) {
				continue
			}
			position := len(out)
			for _, anchor := range secondary[i+1:] {
				for j, current := range out {
					if current == anchor {
						position = j
						break
					}
				}
				if position < len(out) {
					break
				}
			}
			out = append(out, "")
			copy(out[position+1:], out[position:])
			out[position] = id
		}
	}
	return out
}
func contains(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}

// Merge independent reorder operations. A reversed pair is an intentional
// change from Base; untouched pairs retain their baseline order. A cycle means
// both move sets cannot hold at once and must be resolved explicitly.
func combineOrder(base, mine, next []string) ([]string, bool) {
	mp, np := map[string]int{}, map[string]int{}
	for i, id := range mine {
		mp[id] = i
	}
	for i, id := range next {
		np[id] = i
	}
	edges := map[string][]string{}
	degree := map[string]int{}
	for _, id := range base {
		degree[id] = 0
	}
	for i, left := range base {
		for _, right := range base[i+1:] {
			before := mp[left] < mp[right]
			if before {
				before = np[left] < np[right]
			}
			from, to := left, right
			if !before {
				from, to = right, left
			}
			edges[from] = append(edges[from], to)
			degree[to]++
		}
	}
	out := []string{}
	used := map[string]bool{}
	for len(out) < len(base) {
		found := ""
		for _, id := range base {
			if !used[id] && degree[id] == 0 {
				found = id
				break
			}
		}
		if found == "" {
			return nil, false
		}
		used[found] = true
		out = append(out, found)
		for _, id := range edges[found] {
			degree[id]--
		}
	}
	return out, true
}
