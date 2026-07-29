package operations

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"sync"
	"time"
)

type AuditRecord struct {
	UnixMilli int64  `json:"unix_milli"`
	Action    string `json:"action"`
	GameID    string `json:"game_id"`
	PackageID string `json:"package_id,omitempty"`
	Digest    string `json:"digest,omitempty"`
	Detail    string `json:"detail,omitempty"`
}

type PackageTelemetry struct {
	Starts              uint64
	Crashes             uint64
	ResourceExhaustions uint64
	HealthFailures      uint64
	Calls               uint64
	LatencyMillis       uint64
}

type rollout struct {
	stable        string
	candidate     string
	canaryPercent int
	previous      string
	draining      map[string]bool
}

type Registry struct {
	mu sync.Mutex

	now       func() time.Time
	packages  map[string]*VerifiedPackage
	byGame    map[string]map[string]bool
	rollouts  map[string]*rollout
	pins      map[string]string
	audit     []AuditRecord
	telemetry map[string]PackageTelemetry
}

func NewRegistry(now func() time.Time) *Registry {
	if now == nil {
		now = time.Now
	}
	return &Registry{
		now: now, packages: make(map[string]*VerifiedPackage),
		byGame: make(map[string]map[string]bool), rollouts: make(map[string]*rollout),
		pins: make(map[string]string), telemetry: make(map[string]PackageTelemetry),
	}
}

func (r *Registry) Install(value *VerifiedPackage) error {
	if value == nil || value.Digest == "" {
		return fmt.Errorf("verified package is required")
	}
	if err := value.LaunchPlan().Validate(); err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if existing := r.packages[value.Digest]; existing != nil {
		if existing.Manifest.PackageID != value.Manifest.PackageID {
			return fmt.Errorf("immutable digest is already owned by another package")
		}
		return nil
	}
	for installedDigest := range r.byGame[value.Manifest.GameID] {
		installed := r.packages[installedDigest]
		if installed.Manifest.PackageID == value.Manifest.PackageID &&
			installed.Manifest.AdapterVersion == value.Manifest.AdapterVersion {
			return fmt.Errorf("adapter version is already bound to another immutable digest")
		}
	}
	r.packages[value.Digest] = value
	if r.byGame[value.Manifest.GameID] == nil {
		r.byGame[value.Manifest.GameID] = make(map[string]bool)
	}
	r.byGame[value.Manifest.GameID][value.Digest] = true
	r.recordLocked("install", value.Manifest.GameID, value, "")
	return nil
}

func (r *Registry) Activate(gameID, digest string, canaryPercent int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	value := r.packages[digest]
	if value == nil || value.Manifest.GameID != gameID {
		return fmt.Errorf("package digest is not installed for game")
	}
	if canaryPercent < 1 || canaryPercent > 100 {
		return fmt.Errorf("canary percent must be within 1..100")
	}
	state := r.rolloutLocked(gameID)
	if state.stable == "" || canaryPercent == 100 {
		if state.stable != "" && state.stable != digest {
			state.previous = state.stable
		}
		state.stable, state.candidate, state.canaryPercent = digest, "", 0
	} else {
		if digest == state.stable {
			return fmt.Errorf("stable package cannot be its own canary")
		}
		state.candidate, state.canaryPercent = digest, canaryPercent
	}
	delete(state.draining, digest)
	r.recordLocked("activate", gameID, value,
		fmt.Sprintf("canary_percent=%d", canaryPercent))
	return nil
}

func (r *Registry) Resolve(gameID, matchID string) (*VerifiedPackage, error) {
	if gameID == "" || matchID == "" {
		return nil, fmt.Errorf("game and platform-owned match id are required")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	pinKey := gameID + "\x00" + matchID
	if digest := r.pins[pinKey]; digest != "" {
		return r.packages[digest], nil
	}
	state := r.rollouts[gameID]
	if state == nil || state.stable == "" {
		return nil, fmt.Errorf("game has no active package")
	}
	selected := state.stable
	if state.draining[selected] {
		if state.previous == "" || state.draining[state.previous] {
			return nil, fmt.Errorf("game has no non-draining package")
		}
		selected = state.previous
	}
	if state.candidate != "" && !state.draining[state.candidate] &&
		bucket(gameID, matchID) < state.canaryPercent {
		selected = state.candidate
	}
	value := r.packages[selected]
	if value == nil {
		return nil, fmt.Errorf("active package is unavailable")
	}
	r.pins[pinKey] = selected
	r.recordLocked("pin_match", gameID, value, "match_id="+matchID)
	return value, nil
}

func (r *Registry) Promote(gameID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	state := r.rollouts[gameID]
	if state == nil || state.candidate == "" {
		return fmt.Errorf("game has no canary to promote")
	}
	state.previous, state.stable = state.stable, state.candidate
	state.candidate, state.canaryPercent = "", 0
	r.recordLocked("promote", gameID, r.packages[state.stable], "")
	return nil
}

func (r *Registry) Drain(gameID, digest string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	state := r.rollouts[gameID]
	if state == nil || !r.byGame[gameID][digest] {
		return fmt.Errorf("package is not registered for game")
	}
	state.draining[digest] = true
	r.recordLocked("drain", gameID, r.packages[digest], "")
	return nil
}

func (r *Registry) Rollback(gameID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	state := r.rollouts[gameID]
	if state == nil {
		return fmt.Errorf("game has no rollout")
	}
	if state.candidate != "" {
		value := r.packages[state.candidate]
		state.draining[state.candidate] = true
		state.candidate, state.canaryPercent = "", 0
		r.recordLocked("rollback_canary", gameID, value, "")
		return nil
	}
	if state.previous == "" {
		return fmt.Errorf("game has no previous package")
	}
	current := state.stable
	state.stable, state.previous = state.previous, current
	state.draining[current] = true
	delete(state.draining, state.stable)
	r.recordLocked("rollback", gameID, r.packages[state.stable], "")
	return nil
}

func (r *Registry) EndMatch(gameID, matchID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.pins, gameID+"\x00"+matchID)
}

func (r *Registry) Observe(digest string, sample PackageTelemetry) {
	r.mu.Lock()
	defer r.mu.Unlock()
	current := r.telemetry[digest]
	current.Starts += sample.Starts
	current.Crashes += sample.Crashes
	current.ResourceExhaustions += sample.ResourceExhaustions
	current.HealthFailures += sample.HealthFailures
	current.Calls += sample.Calls
	current.LatencyMillis += sample.LatencyMillis
	r.telemetry[digest] = current
}

func (r *Registry) Telemetry(digest string) PackageTelemetry {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.telemetry[digest]
}

func (r *Registry) Audit() []AuditRecord {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]AuditRecord(nil), r.audit...)
}

func (r *Registry) rolloutLocked(gameID string) *rollout {
	if r.rollouts[gameID] == nil {
		r.rollouts[gameID] = &rollout{draining: make(map[string]bool)}
	}
	return r.rollouts[gameID]
}

func (r *Registry) recordLocked(action, gameID string, value *VerifiedPackage, detail string) {
	record := AuditRecord{
		UnixMilli: r.now().UnixMilli(), Action: action, GameID: gameID, Detail: detail,
	}
	if value != nil {
		record.PackageID, record.Digest = value.Manifest.PackageID, value.Digest
	}
	r.audit = append(r.audit, record)
}

func bucket(gameID, matchID string) int {
	sum := sha256.Sum256([]byte(gameID + "\x00" + matchID))
	return int(binary.BigEndian.Uint64(sum[:8]) % 100)
}
