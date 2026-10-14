package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"

	"core/aiprobe"
	"core/configpipeline"
	"github.com/metacubex/chi"
	MHTTP "github.com/metacubex/http"
	G "github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/tunnel"
)

var aiProbeManager aiprobe.Manager

// Accessed under the existing runLock. Set only by native start/authenticated
// reload immediately after executor.ApplyConfig, never from a probe request.
var aiAppliedDigest string

func observeAIProbeConfig(text string) {
	sum := sha256.Sum256([]byte(text))
	aiAppliedDigest = hex.EncodeToString(sum[:])
}

func init() {
	// Register remains within the existing authenticated Controller router; no
	// Controller address, auth policy or lifecycle implementation is replaced.
	route.Register(func(r chi.Router) { r.Post("/ohos/ai-probe", checkAIReachability) })
}

type aiProbeInput struct {
	Revision string `json:"revision"`
	Retry    bool   `json:"retry"`
}

func checkAIReachability(w MHTTP.ResponseWriter, req *MHTTP.Request) {
	var input aiProbeInput
	decoder := json.NewDecoder(io.LimitReader(req.Body, 1025))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || decoder.Decode(new(any)) != io.EOF || len(input.Revision) > 128 {
		controllerError(w, 400, "PROBE_INVALID")
		return
	}
	epoch := controllerEpoch.Load()
	runLock.Lock()
	id, err := activeAIProbeIdentity(input.Revision)
	appliedDigest := aiAppliedDigest
	runLock.Unlock()
	if err != nil || !controllerRunning.Load() {
		controllerError(w, 409, "PROBE_NOT_APPLIED")
		return
	}
	current := func() bool {
		runLock.Lock()
		defer runLock.Unlock()
		if !controllerRunning.Load() || epoch != controllerEpoch.Load() || tunListener == nil || aiAppliedDigest != appliedDigest {
			return false
		}
		state, err := (configpipeline.FileStore{Root: filepath.Join(homeDir, "profile-versions")}).Load(context.Background())
		if err != nil || state.Current == nil || state.Current.ID != id.Revision || state.Current.ProfileID != id.Profile {
			return false
		}
		selected, err := probeSelection(id.Group)
		return err == nil && selected == id.Selection
	}
	results, err := aiProbeManager.Check(req.Context(), id, tunnel.Tunnel, current, input.Retry)
	if err != nil || req.Context().Err() != nil || !current() {
		controllerError(w, 409, "PROBE_NOT_CURRENT")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(struct {
		Revision string           `json:"revision"`
		Results  []aiprobe.Result `json:"results"`
	}{id.Revision, results})
}

// Only an AI template in the successful Current version can authorize probes.
// Caller input never supplies an endpoint, group, subscription URL or credential.
func activeAIProbeIdentity(expected string) (aiprobe.Identity, error) {
	fail := errors.New("PROBE_NOT_APPLIED")
	if !initialized || tunListener == nil || expected == "" {
		return aiprobe.Identity{}, fail
	}
	state, err := (configpipeline.FileStore{Root: filepath.Join(homeDir, "profile-versions")}).Load(context.Background())
	if err != nil || state.Current == nil || state.Current.ID != expected {
		return aiprobe.Identity{}, fail
	}
	f, err := os.Open(filepath.Join(homeDir, "profile-versions", state.Current.ID, "source.json"))
	if err != nil {
		return aiprobe.Identity{}, fail
	}
	defer f.Close()
	var source struct {
		EditIntent *struct {
			SchemaVersion int  `json:"schemaVersion"`
			Disabled      bool `json:"disabled"`
			Template      *struct {
				TemplateID  string `json:"templateId"`
				Version     int    `json:"version"`
				TargetGroup string `json:"targetGroup"`
			} `json:"template"`
		}
	}
	decoder := json.NewDecoder(io.LimitReader(f, maxConfigBytes*4))
	if decoder.Decode(&source) != nil || decoder.Decode(new(any)) != io.EOF || source.EditIntent == nil || source.EditIntent.SchemaVersion != 1 || source.EditIntent.Disabled || source.EditIntent.Template == nil {
		return aiprobe.Identity{}, fail
	}
	candidate, err := os.ReadFile(state.Current.Path)
	if err != nil || len(candidate) > maxConfigBytes || aiAppliedDigest == "" {
		return aiprobe.Identity{}, fail
	}
	digest := sha256.Sum256(candidate)
	if hex.EncodeToString(digest[:]) != aiAppliedDigest {
		return aiprobe.Identity{}, fail
	}
	plan := source.EditIntent.Template
	if plan.TemplateID != "ai" || plan.Version != 1 || plan.TargetGroup == "" {
		return aiprobe.Identity{}, fail
	}
	selected, err := probeSelection(plan.TargetGroup)
	if err != nil {
		return aiprobe.Identity{}, err
	}
	return aiprobe.Identity{Profile: state.Current.ProfileID, Revision: expected, Group: plan.TargetGroup, Selection: selected}, nil
}

// Snapshot only user-controlled Selector choices in the selected group's graph.
// Smart/url-test decisions remain per request; results describe the group, not
// a permanently attributed node. No names/fingerprints are returned or logged.
func probeSelection(group string) (string, error) {
	proxies := tunnel.Proxies()
	root, ok := proxies[group]
	if !ok {
		return "", errors.New("PROBE_GROUP_MISSING")
	}
	if _, ok := root.Adapter().(interface{ GetProxies(bool) []C.Proxy }); !ok {
		return "", errors.New("PROBE_NOT_A_GROUP")
	}
	choices := map[string]string{}
	visited := map[string]bool{}
	var visit func(C.Proxy) error
	visit = func(p C.Proxy) error {
		if p == nil {
			return errors.New("PROBE_GROUP_MISSING")
		}
		if visited[p.Name()] {
			return nil
		}
		visited[p.Name()] = true
		if len(visited) > 512 {
			return errors.New("PROBE_GROUP_LIMIT")
		}

		if group, ok := p.Adapter().(interface {
			GetProxies(bool) []C.Proxy
			EmptyFallback() C.Proxy
		}); ok {
			members := group.GetProxies(false)
			// GetProxies injects a fallback even when filters/providers are empty. A
			// sole fallback cannot prove availability; conservatively leave unchecked.
			if len(members) == 0 || (len(members) == 1 && members[0] == group.EmptyFallback()) {
				return errors.New("PROBE_GROUP_EMPTY")
			}
		}
		if selector, ok := p.Adapter().(*G.Selector); ok {
			name := selector.Now()
			choices[p.Name()] = name
			if name == "" || name == "REJECT" || name == "REJECT-DROP" {
				return errors.New("PROBE_GROUP_EMPTY")
			}
			next := selector.Unwrap(nil, false)
			return visit(next)
		}
		if members, ok := p.Adapter().(interface{ GetProxies(bool) []C.Proxy }); ok {
			all := members.GetProxies(false)
			if len(all) == 0 {
				return errors.New("PROBE_GROUP_EMPTY")
			}
			for _, member := range all {
				if err := visit(member); err != nil {
					return err
				}
			}
		}
		return nil
	}
	if err := visit(root); err != nil {
		return "", err
	}
	encoded, _ := json.Marshal(choices)
	digest := sha256.Sum256(encoded)
	return hex.EncodeToString(digest[:]), nil
}
