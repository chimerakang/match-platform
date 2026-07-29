package gateway

import (
	"fmt"
	"sync"
	"time"
)

type Translator interface {
	ClientToV3([]byte) (Envelope, error)
	ServerFromV3(Envelope, string) ([]byte, error)
	Error(code, detail string) []byte
}

type Config struct {
	Translator        Translator
	MaxCustomBytes    int
	MessagesPerSecond int
	Burst             int
	Now               func() time.Time
}

type Telemetry struct {
	ClientMessages     uint64
	ServerMessages     uint64
	Malformed          uint64
	Oversized          uint64
	RateLimited        uint64
	DeliveryDowngrades uint64
}

type Gateway struct {
	cfg Config

	mu        sync.Mutex
	window    time.Time
	remaining int
	telemetry Telemetry
}

func New(config Config) (*Gateway, error) {
	if config.Translator == nil {
		return nil, fmt.Errorf("custom protocol translator is required")
	}
	if config.MaxCustomBytes <= 0 {
		config.MaxCustomBytes = 64 << 10
	}
	if config.MessagesPerSecond <= 0 {
		config.MessagesPerSecond = 30
	}
	if config.Burst <= 0 {
		config.Burst = config.MessagesPerSecond
	}
	if config.Now == nil {
		config.Now = time.Now
	}
	return &Gateway{cfg: config, remaining: config.Burst}, nil
}

func (g *Gateway) ClientToV3(value []byte) (Envelope, []byte) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(value) > g.cfg.MaxCustomBytes {
		g.telemetry.Oversized++
		return nil, g.cfg.Translator.Error(RejectPayloadTooLarge,
			"custom message exceeds gateway limit")
	}
	if !g.admitLocked() {
		g.telemetry.RateLimited++
		return nil, g.cfg.Translator.Error(RejectRateLimited,
			"gateway admission limit exceeded")
	}
	envelope, err := g.cfg.Translator.ClientToV3(value)
	if err != nil {
		g.telemetry.Malformed++
		return nil, g.cfg.Translator.Error(RejectMalformed, err.Error())
	}
	if err := ValidateClient(envelope); err != nil {
		g.telemetry.Malformed++
		return nil, g.cfg.Translator.Error(codeFromError(err), err.Error())
	}
	g.telemetry.ClientMessages++
	return envelope, nil
}

func (g *Gateway) ServerFromV3(value Envelope) ([]byte, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if err := ValidateServer(value); err != nil {
		g.telemetry.Malformed++
		return nil, err
	}
	delivery := Reliability(value)
	translated, err := g.cfg.Translator.ServerFromV3(value, delivery)
	if err != nil {
		g.telemetry.Malformed++
		return nil, err
	}
	if len(translated) > g.cfg.MaxCustomBytes {
		g.telemetry.Oversized++
		return nil, fmt.Errorf("%s: translated response exceeds gateway limit",
			RejectPayloadTooLarge)
	}
	if delivery == Droppable {
		g.telemetry.DeliveryDowngrades++
	}
	g.telemetry.ServerMessages++
	return translated, nil
}

func (g *Gateway) Telemetry() Telemetry {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.telemetry
}

func (g *Gateway) admitLocked() bool {
	now := g.cfg.Now()
	currentWindow := now.Truncate(time.Second)
	if g.window.IsZero() || currentWindow.After(g.window) {
		g.window = currentWindow
		g.remaining = g.cfg.Burst
	}
	if g.remaining <= 0 {
		return false
	}
	g.remaining--
	return true
}

func codeFromError(err error) string {
	for _, code := range []string{
		RejectPayloadTooLarge, RejectUnsupportedProtocol, RejectMalformed,
	} {
		if len(err.Error()) >= len(code) && err.Error()[:len(code)] == code {
			return code
		}
	}
	return RejectMalformed
}
