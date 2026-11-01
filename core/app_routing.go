package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"strings"
	"time"

	MHTTP "github.com/metacubex/http"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

// shortcut: UID policies expire with this TUN session; persistence needs verified app identity.
const appRouteIdentityTimeout = 1200 * time.Millisecond

type appRouteContext struct {
	session *appTrafficSession
	uid     int64
	target  string
}

func (s *appTrafficSession) rowLocked(uid int64) *appTrafficRow {
	key := strconv.FormatInt(uid, 10)
	if row := s.rows[key]; row != nil {
		return row
	}
	if len(s.rows) >= 129 {
		s.failures["overflow"]++
		return s.rows[""]
	}
	row := &appTrafficRow{IdentityStatus: "uid", UID: uid, Recent: []appTrafficReason{}}
	s.rows[key] = row
	return row
}

func appTrafficTarget(metadata *C.Metadata) string {
	target := metadata.Host
	if target == "" {
		if remote, ok := rawIdentityAddress(metadata.RawDstAddr); ok {
			target = remote.Address
		}
	}
	if len(target) > 253 || strings.ContainsAny(target, "\r\n\x00") {
		return ""
	}
	return target
}

// This runs on Mihomo's connection goroutine, before selecting or dialing an outbound.
func resolveAppRoute(metadata *C.Metadata) (string, error) {
	if metadata.Type != C.TUN {
		return "", nil
	}
	if resolved, ok := metadata.TrackerContext.(*appRouteContext); ok {
		resolved.session.mu.Lock()
		defer resolved.session.mu.Unlock()
		if resolved.session.stopped || resolved.session != appTrafficCurrent.Load() {
			return "", errors.New("source session ended")
		}
		return resolved.target, nil
	}
	s, ok := metadata.TrackerContext.(*appTrafficSession)
	if !ok || s == nil {
		return "", nil
	}
	resolved := &appRouteContext{session: s, uid: -1}
	metadata.TrackerContext = resolved
	local, localOK := rawIdentityAddress(metadata.RawSrcAddr)
	remote, remoteOK := rawIdentityAddress(metadata.RawDstAddr)
	protocol := metadata.NetWork.String()
	s.mu.Lock()
	if s.stopped || s != appTrafficCurrent.Load() {
		s.mu.Unlock()
		return "", errors.New("source session ended")
	}
	s.expireLocked()
	status := ""
	switch {
	case !localOK || !remoteOK:
		status = "missingTuple"
	case protocol != "tcp" && protocol != "udp":
		status = "unsupported"
	case !s.identityAvailableLocked():
		status = "consumerUnavailable"
	case len(s.pending) >= identityLimit:
		status = "overflow"
	}
	if status != "" {
		s.failures[status]++
		target, err := s.routeLocked(-1)
		s.mu.Unlock()
		return target, err
	}
	s.sequence++
	id := "route-" + strconv.FormatUint(s.sequence, 10)
	result := make(chan int64, 1)
	s.pending[id] = &appIdentityPending{request: appIdentityRequest{ID: id, Protocol: protocol, Local: local, Remote: remote},
		deadline: time.Now().Add(appRouteIdentityTimeout), result: result}
	s.mu.Unlock()
	s.wakeIdentity()
	timer := time.NewTimer(appRouteIdentityTimeout)
	defer timer.Stop()
	select {
	case uid := <-result:
		resolved.uid = uid
	case <-timer.C:
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.pending[id]; exists {
		delete(s.pending, id)
		s.failures["timeout"]++
		s.wakeIdentity()
	}
	if s.stopped || s != appTrafficCurrent.Load() {
		return "", errors.New("source session ended")
	}
	target, err := s.routeLocked(resolved.uid)
	resolved.target = target
	return target, err
}

func (s *appTrafficSession) routeLocked(uid int64) (string, error) {
	if uid < 0 && len(s.policies) > 0 {
		s.failures["routeIdentityRequired"]++
		return "", errors.New("source identity unavailable for routing")
	}
	return s.policies[uid], nil
}

func putAppRoute(w MHTTP.ResponseWriter, req *MHTTP.Request) {
	var body struct {
		Session string `json:"session"`
		UID     *int64 `json:"uid"`
		Target  string `json:"target"`
	}
	decoder := json.NewDecoder(io.LimitReader(req.Body, 4097))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || decoder.Decode(new(any)) != io.EOF || body.UID == nil || *body.UID < 0 || *body.UID > 2147483647 || len(body.Target) > 256 {
		controllerError(w, 400, "invalid source route")
		return
	}
	valid := body.Target == ""
	for _, target := range tunnel.HostRouteTargets() {
		if target == body.Target {
			valid = true
			break
		}
	}
	if !valid {
		controllerError(w, 400, "source route unavailable")
		return
	}
	s := appTrafficCurrent.Load()
	if s == nil {
		controllerError(w, 409, "traffic session unavailable")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopped || s.id != body.Session || s != appTrafficCurrent.Load() {
		controllerError(w, 409, "traffic session ended")
		return
	}
	if s.rows[strconv.FormatInt(*body.UID, 10)] == nil {
		controllerError(w, 400, "source not observed")
		return
	}
	if body.Target == "" {
		delete(s.policies, *body.UID)
	} else {
		s.policies[*body.UID] = body.Target
	}
	w.WriteHeader(MHTTP.StatusNoContent)
}

// Every UDP packet is queried before NAT lookup; no socket or UID cache is used.
func appUDPKey(metadata *C.Metadata) (string, error) {
	target, err := resolveAppRoute(metadata)
	if err != nil {
		return "", err
	}
	resolved, ok := metadata.TrackerContext.(*appRouteContext)
	if !ok {
		return "", errors.New("source session unavailable")
	}
	local, localOK := rawIdentityAddress(metadata.RawSrcAddr)
	remote, remoteOK := rawIdentityAddress(metadata.RawDstAddr)
	if !localOK || !remoteOK {
		return "", errors.New("source tuple unavailable")
	}
	data, _ := json.Marshal(struct {
		Session       string
		UID           int64
		Local, Remote appIdentityAddress
		Target        string
	}{resolved.session.id, resolved.uid, local, remote, target})
	// Keep addresses and policy names out of NAT keys, which upstream may log.
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}
