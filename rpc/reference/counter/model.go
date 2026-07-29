package counter

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
)

const (
	GameID         = "counter-reference"
	AdapterVersion = "1.0.0"
	ContentVersion = "counter-rules.1"
	CodecID        = "counter.json.v1"
	TickRate       = 20
)

var participantSlots = []string{"slot_1", "slot_2", "slot_3"}

type slotValues struct {
	Slot1 int `json:"slot_1"`
	Slot2 int `json:"slot_2"`
	Slot3 int `json:"slot_3"`
}

func (v *slotValues) add(slot string, amount int) {
	switch slot {
	case "slot_1":
		v.Slot1 += amount
	case "slot_2":
		v.Slot2 += amount
	case "slot_3":
		v.Slot3 += amount
	}
}

type slotPrepared struct {
	Slot1 bool `json:"slot_1"`
	Slot2 bool `json:"slot_2"`
	Slot3 bool `json:"slot_3"`
}

func (v *slotPrepared) ready(slot string) {
	switch slot {
	case "slot_1":
		v.Slot1 = true
	case "slot_2":
		v.Slot2 = true
	case "slot_3":
		v.Slot3 = true
	}
}

type completion struct {
	CompletedBy string     `json:"completed_by"`
	Totals      slotValues `json:"totals"`
	Step        uint64     `json:"step"`
}

type gameState struct {
	Seed       uint64       `json:"seed"`
	Step       uint64       `json:"step"`
	Limit      int          `json:"limit"`
	Closed     bool         `json:"closed"`
	Values     slotValues   `json:"values"`
	Prepared   slotPrepared `json:"prepared"`
	Completion *completion  `json:"completion"`
}

type command struct {
	Action string `json:"action"`
	Amount int    `json:"amount"`
}

type commandEntry struct {
	Slot    string  `json:"slot"`
	Payload command `json:"payload"`
	At      uint64  `json:"at"`
}

type gameEvent struct {
	Index  int    `json:"index"`
	Kind   string `json:"kind"`
	Source string `json:"source"`
	Step   uint64 `json:"step"`
}

type checkpoint struct {
	GameID  string         `json:"game_id"`
	MatchID string         `json:"match_id"`
	State   gameState      `json:"state"`
	Log     []commandEntry `json:"log"`
}

type replay struct {
	Schema     int            `json:"schema"`
	GameID     string         `json:"game_id"`
	MatchID    string         `json:"match_id"`
	Seed       uint64         `json:"seed"`
	Limit      int            `json:"limit"`
	Log        []commandEntry `json:"log"`
	Steps      uint64         `json:"steps"`
	StateHash  string         `json:"state_hash"`
	Completion *completion    `json:"completion"`
}

type delta struct {
	Replace gameState `json:"replace"`
}

type match struct {
	id          string
	state       gameState
	pending     []commandEntry
	events      []gameEvent
	eventCursor int
	history     map[uint64]gameState
	log         []commandEntry
	accepted    uint64
	refused     uint64
	checkpoints uint64
	increments  uint64
}

func newMatch(id string, seed uint64, limit int) *match {
	value := &match{
		id:      id,
		state:   gameState{Seed: seed, Limit: limit},
		history: make(map[uint64]gameState),
	}
	value.storeHistory()
	return value
}

func recoverMatch(value checkpoint) (*match, error) {
	if value.GameID != GameID {
		return nil, fmt.Errorf("checkpoint belongs to another package")
	}
	if value.MatchID == "" || value.State.Limit < 2 || value.State.Limit > 100 {
		return nil, fmt.Errorf("checkpoint state is invalid")
	}
	result := &match{
		id:      value.MatchID,
		state:   value.State,
		history: make(map[uint64]gameState),
		log:     append([]commandEntry(nil), value.Log...),
	}
	result.storeHistory()
	return result, nil
}

func (m *match) validateCommand(slot string, candidate command) (command, error) {
	if !isParticipant(slot) {
		m.refused++
		return command{}, fmt.Errorf("source has no participant slot")
	}
	if m.state.Closed {
		m.refused++
		return command{}, fmt.Errorf("match is already complete")
	}
	switch candidate.Action {
	case "ready", "finish":
	case "increment":
		if candidate.Amount < 1 || candidate.Amount > 3 {
			m.refused++
			return command{}, fmt.Errorf("amount is outside 1..3")
		}
	default:
		m.refused++
		return command{}, fmt.Errorf("unknown action")
	}
	return candidate, nil
}

func (m *match) apply(slot string, candidate command) error {
	normalized, err := m.validateCommand(slot, candidate)
	if err != nil {
		return err
	}
	entry := commandEntry{Slot: slot, Payload: normalized, At: m.state.Step}
	m.pending = append(m.pending, entry)
	m.log = append(m.log, entry)
	m.accepted++
	return nil
}

func (m *match) advance(ticks uint32) {
	for index := uint32(0); index < ticks && !m.state.Closed; index++ {
		pending := m.pending
		m.pending = nil
		for _, entry := range pending {
			switch entry.Payload.Action {
			case "ready":
				m.state.Prepared.ready(entry.Slot)
				m.emit("prepared", entry.Slot)
			case "increment":
				m.state.Values.add(entry.Slot, entry.Payload.Amount)
				m.emit("changed", entry.Slot)
			case "finish":
				m.close(entry.Slot)
			}
		}
		m.state.Step++
		if m.state.Step >= uint64(m.state.Limit) && !m.state.Closed {
			m.close("clock")
		}
		m.storeHistory()
	}
}

func (m *match) close(source string) {
	m.state.Closed = true
	m.state.Completion = &completion{
		CompletedBy: source,
		Totals:      m.state.Values,
		Step:        m.state.Step,
	}
	m.emit("completed", source)
}

func (m *match) emit(kind, source string) {
	m.events = append(m.events, gameEvent{
		Index: len(m.events) + 1, Kind: kind, Source: source, Step: m.state.Step,
	})
}

func (m *match) storeHistory() {
	m.history[m.state.Step] = m.state
	if m.state.Step > 64 {
		delete(m.history, m.state.Step-65)
	}
}

func (m *match) stateHash() string {
	value, _ := json.Marshal(m.state)
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}

func contentHash() string {
	sum := sha256.Sum256([]byte(
		"counter-reference|rules=1|slots=3|actions=ready,increment,finish"))
	return hex.EncodeToString(sum[:])
}

func isParticipant(slot string) bool {
	for _, candidate := range participantSlots {
		if slot == candidate {
			return true
		}
	}
	return false
}
