package recovery

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type FileStore struct {
	cfg FileStoreConfig
	mu  sync.Mutex
}

type manifest struct {
	Version            int    `json:"version"`
	MatchID            string `json:"match_id"`
	CommittedSequence  uint64 `json:"committed_sequence"`
	CheckpointSequence uint64 `json:"checkpoint_sequence"`
	CheckpointFile     string `json:"checkpoint_file,omitempty"`
	CheckpointSHA256   string `json:"checkpoint_sha256,omitempty"`
	LastEpoch          uint64 `json:"last_epoch"`
	LastRequestID      uint64 `json:"last_request_id"`
	UpdatedUnixMs      int64  `json:"updated_unix_ms"`
}

type journalRecord struct {
	Version   int       `json:"version"`
	Kind      string    `json:"kind"`
	MatchID   string    `json:"match_id"`
	Sequence  uint64    `json:"sequence"`
	Epoch     uint64    `json:"epoch"`
	RequestID uint64    `json:"request_id"`
	Operation Operation `json:"operation"`
	Request   []byte    `json:"request,omitempty"`
	Response  []byte    `json:"response,omitempty"`
	StateHash string    `json:"state_hash,omitempty"`
	Checksum  string    `json:"checksum"`
}

type checkpointEnvelope struct {
	Version       int    `json:"version"`
	MatchID       string `json:"match_id"`
	Sequence      uint64 `json:"sequence"`
	CodecID       string `json:"codec_id"`
	Payload       []byte `json:"payload"`
	StateHash     string `json:"state_hash"`
	Tick          uint64 `json:"tick"`
	CreatedUnixMs int64  `json:"created_unix_ms"`
	PayloadSHA256 string `json:"payload_sha256"`
}

func NewFileStore(cfg FileStoreConfig) (*FileStore, error) {
	if strings.TrimSpace(cfg.Root) == "" {
		return nil, fmt.Errorf("recovery store root is required")
	}
	if cfg.RetainCheckpoints <= 0 {
		cfg.RetainCheckpoints = 2
	}
	if cfg.RetainDedupe <= 0 {
		cfg.RetainDedupe = 256
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if err := os.MkdirAll(cfg.Root, 0o700); err != nil {
		return nil, err
	}
	return &FileStore{cfg: cfg}, nil
}

func (s *FileStore) Close() error { return nil }

func (s *FileStore) Prepare(
	ctx context.Context, mutation Mutation,
) (PrepareResult, error) {
	if err := ctx.Err(); err != nil {
		return PrepareResult{}, err
	}
	if err := validateMutation(mutation); err != nil {
		return PrepareResult{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	state, currentManifest, err := s.loadLocked(mutation.MatchID)
	if err != nil {
		return PrepareResult{}, err
	}
	for _, entry := range state.Entries {
		if entry.Epoch != mutation.Epoch || entry.RequestID != mutation.RequestID {
			continue
		}
		if entry.Operation != mutation.Operation || !bytes.Equal(entry.Request, mutation.Request) {
			return PrepareResult{}, fail(CodeDuplicateMismatch,
				"request id was reused with different bytes", nil)
		}
		return PrepareResult{Entry: entry, Duplicate: true}, nil
	}
	if mutation.Epoch < state.LastEpoch {
		return PrepareResult{}, fail(CodeStaleEpoch,
			"request belongs to an older adapter epoch", nil)
	}
	if mutation.Epoch == state.LastEpoch && mutation.RequestID <= state.LastRequestID {
		return PrepareResult{}, fail(CodeOutOfOrder,
			"request id is not strictly monotonic", nil)
	}
	sequence := nextSequence(state.Entries)
	entry := Entry{Mutation: mutation, Sequence: sequence}
	record := recordForEntry(entry, "prepare")
	if err := s.appendRecordLocked(mutation.MatchID, record); err != nil {
		return PrepareResult{}, err
	}
	if err := s.inject(FaultAfterPrepareSync); err != nil {
		return PrepareResult{}, err
	}
	currentManifest.Version = StoreVersion
	currentManifest.MatchID = mutation.MatchID
	currentManifest.LastEpoch = mutation.Epoch
	currentManifest.LastRequestID = mutation.RequestID
	if err := s.writeManifestLocked(mutation.MatchID, currentManifest); err != nil {
		return PrepareResult{}, err
	}
	return PrepareResult{Entry: entry}, nil
}

func (s *FileStore) Commit(
	ctx context.Context,
	matchID string,
	sequence uint64,
	response []byte,
	stateHash string,
) (Entry, error) {
	if err := ctx.Err(); err != nil {
		return Entry{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	state, currentManifest, err := s.loadLocked(matchID)
	if err != nil {
		return Entry{}, err
	}
	var prepared *Entry
	for index := range state.Entries {
		if state.Entries[index].Sequence == sequence {
			prepared = &state.Entries[index]
			break
		}
	}
	if prepared == nil {
		return Entry{}, fail(CodeCorrupt, "commit has no prepared journal entry", nil)
	}
	if prepared.Committed {
		if !bytes.Equal(prepared.Response, response) || prepared.StateHash != stateHash {
			return Entry{}, fail(CodeDuplicateMismatch,
				"committed response differs from durable result", nil)
		}
		return *prepared, nil
	}
	if sequence != state.CommittedSequence+1 {
		return Entry{}, fail(CodeOutOfOrder,
			"commits must advance the contiguous watermark", nil)
	}
	committed := *prepared
	committed.Committed = true
	committed.Response = append([]byte(nil), response...)
	committed.StateHash = stateHash
	if err := s.appendRecordLocked(matchID, recordForEntry(committed, "commit")); err != nil {
		return Entry{}, err
	}
	if err := s.inject(FaultAfterCommitSync); err != nil {
		return Entry{}, err
	}
	currentManifest.Version = StoreVersion
	currentManifest.MatchID = matchID
	currentManifest.CommittedSequence = sequence
	currentManifest.LastEpoch = max(currentManifest.LastEpoch, committed.Epoch)
	if currentManifest.LastEpoch == committed.Epoch {
		currentManifest.LastRequestID = max(currentManifest.LastRequestID, committed.RequestID)
	}
	if err := s.writeManifestLocked(matchID, currentManifest); err != nil {
		return Entry{}, err
	}
	return committed, nil
}

func (s *FileStore) SaveCheckpoint(ctx context.Context, checkpoint Checkpoint) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if checkpoint.Version == 0 {
		checkpoint.Version = StoreVersion
	}
	if checkpoint.Version != StoreVersion {
		return fail(CodeIncompatible, "checkpoint version is not supported", nil)
	}
	if checkpoint.MatchID == "" || checkpoint.Sequence == 0 || checkpoint.CodecID == "" {
		return fmt.Errorf("checkpoint identity, sequence and codec are required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	state, currentManifest, err := s.loadLocked(checkpoint.MatchID)
	if err != nil {
		return err
	}
	if checkpoint.Sequence > state.CommittedSequence {
		return fail(CodeOutOfOrder, "checkpoint is ahead of committed journal", nil)
	}
	if checkpoint.Sequence < state.CheckpointSequence {
		return fail(CodeOutOfOrder, "checkpoint sequence moved backwards", nil)
	}
	if checkpoint.CreatedUnixMs == 0 {
		checkpoint.CreatedUnixMs = s.cfg.Now().UnixMilli()
	}
	envelope := checkpointEnvelope{
		Version:       checkpoint.Version,
		MatchID:       checkpoint.MatchID,
		Sequence:      checkpoint.Sequence,
		CodecID:       checkpoint.CodecID,
		Payload:       append([]byte(nil), checkpoint.Payload...),
		StateHash:     checkpoint.StateHash,
		Tick:          checkpoint.Tick,
		CreatedUnixMs: checkpoint.CreatedUnixMs,
		PayloadSHA256: checksum(checkpoint.Payload),
	}
	raw, err := json.Marshal(envelope)
	if err != nil {
		return err
	}
	dir, err := s.matchDir(checkpoint.MatchID)
	if err != nil {
		return err
	}
	name := fmt.Sprintf("checkpoint-%020d.json", checkpoint.Sequence)
	if err := atomicWrite(filepath.Join(dir, name), raw, 0o600); err != nil {
		return fail(CodeStorage, "could not persist checkpoint", err)
	}
	if err := s.inject(FaultAfterCheckpointRename); err != nil {
		return err
	}
	currentManifest.Version = StoreVersion
	currentManifest.MatchID = checkpoint.MatchID
	currentManifest.CheckpointSequence = checkpoint.Sequence
	currentManifest.CheckpointFile = name
	currentManifest.CheckpointSHA256 = checksum(raw)
	if err := s.writeManifestLocked(checkpoint.MatchID, currentManifest); err != nil {
		return err
	}
	if err := s.compactJournalLocked(checkpoint.MatchID, checkpoint.Sequence); err != nil {
		return err
	}
	return s.pruneCheckpointsLocked(dir, name)
}

func (s *FileStore) Load(ctx context.Context, matchID string) (State, error) {
	if err := ctx.Err(); err != nil {
		return State{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	state, currentManifest, err := s.loadLocked(matchID)
	if err != nil {
		return State{}, err
	}
	// A synced commit record is authoritative if a crash happened before the
	// atomic manifest rename. Repairing the derived watermark is idempotent.
	derivedCommitted := contiguousCommitted(state.Entries, state.CheckpointSequence)
	if derivedCommitted > currentManifest.CommittedSequence {
		currentManifest.CommittedSequence = derivedCommitted
		if err := s.writeManifestLocked(matchID, currentManifest); err != nil {
			return State{}, err
		}
		state.CommittedSequence = derivedCommitted
	}
	return state, nil
}

func (s *FileStore) loadLocked(matchID string) (State, manifest, error) {
	dir, err := s.matchDir(matchID)
	if err != nil {
		return State{}, manifest{}, err
	}
	currentManifest := manifest{Version: StoreVersion, MatchID: matchID}
	manifestPath := filepath.Join(dir, "manifest.json")
	if raw, readErr := os.ReadFile(manifestPath); readErr == nil {
		if err := json.Unmarshal(raw, &currentManifest); err != nil {
			return State{}, manifest{}, fail(CodeCorrupt, "manifest is malformed", err)
		}
		if currentManifest.Version != StoreVersion {
			return State{}, manifest{}, fail(CodeIncompatible,
				"manifest version is not supported", nil)
		}
		if currentManifest.MatchID != matchID {
			return State{}, manifest{}, fail(CodeCorrupt, "manifest match identity differs", nil)
		}
	} else if !errors.Is(readErr, os.ErrNotExist) {
		return State{}, manifest{}, fail(CodeStorage, "could not read manifest", readErr)
	}
	entries, err := s.readJournalLocked(filepath.Join(dir, "journal.jsonl"), matchID)
	if err != nil {
		return State{}, manifest{}, err
	}
	derivedEpoch, derivedRequest := lastIdentity(entries)
	if derivedEpoch > currentManifest.LastEpoch ||
		(derivedEpoch == currentManifest.LastEpoch && derivedRequest > currentManifest.LastRequestID) {
		currentManifest.LastEpoch = derivedEpoch
		currentManifest.LastRequestID = derivedRequest
	}
	if currentManifest.CheckpointSequence > currentManifest.CommittedSequence {
		return State{}, manifest{}, fail(CodeCorrupt,
			"checkpoint watermark is ahead of committed watermark", nil)
	}
	derivedCommitted := contiguousCommitted(entries, currentManifest.CheckpointSequence)
	if currentManifest.CommittedSequence > derivedCommitted {
		return State{}, manifest{}, fail(CodeCorrupt,
			"manifest committed watermark has no contiguous journal records", nil)
	}
	state := State{
		Version:            StoreVersion,
		MatchID:            matchID,
		CommittedSequence:  max(currentManifest.CommittedSequence, derivedCommitted),
		CheckpointSequence: currentManifest.CheckpointSequence,
		LastEpoch:          currentManifest.LastEpoch,
		LastRequestID:      currentManifest.LastRequestID,
		Entries:            entries,
	}
	if currentManifest.CheckpointFile != "" {
		checkpoint, checkpointErr := s.readCheckpointLocked(dir, currentManifest)
		if checkpointErr != nil {
			return State{}, manifest{}, checkpointErr
		}
		state.Checkpoint = checkpoint
	}
	state.StorageBytes = directoryBytes(dir)
	return state, currentManifest, nil
}

func (s *FileStore) readJournalLocked(path, matchID string) ([]Entry, error) {
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fail(CodeStorage, "could not open journal", err)
	}
	defer file.Close()
	bySequence := make(map[uint64]Entry)
	reader := bufio.NewReader(file)
	lineNumber := 0
	for {
		line, readErr := reader.ReadBytes('\n')
		if len(line) != 0 {
			lineNumber++
			if line[len(line)-1] != '\n' {
				return nil, fail(CodeCorrupt,
					fmt.Sprintf("journal line %d is truncated", lineNumber), nil)
			}
			var record journalRecord
			if err := json.Unmarshal(bytes.TrimSpace(line), &record); err != nil {
				return nil, fail(CodeCorrupt,
					fmt.Sprintf("journal line %d is malformed", lineNumber), err)
			}
			if err := validateRecord(record, matchID); err != nil {
				return nil, err
			}
			entry := bySequence[record.Sequence]
			switch record.Kind {
			case "prepare":
				if entry.Sequence != 0 {
					return nil, fail(CodeCorrupt, "duplicate prepare record", nil)
				}
				entry = Entry{Mutation: Mutation{
					MatchID: record.MatchID, Epoch: record.Epoch,
					RequestID: record.RequestID, Operation: record.Operation,
					Request: append([]byte(nil), record.Request...),
				}, Sequence: record.Sequence}
			case "commit":
				if entry.Sequence == 0 {
					return nil, fail(CodeCorrupt, "commit precedes prepare record", nil)
				}
				entry.Committed = true
				entry.Response = append([]byte(nil), record.Response...)
				entry.StateHash = record.StateHash
			default:
				return nil, fail(CodeIncompatible, "journal record kind is unsupported", nil)
			}
			bySequence[record.Sequence] = entry
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return nil, fail(CodeStorage, "could not read journal", readErr)
		}
	}
	entries := make([]Entry, 0, len(bySequence))
	for _, entry := range bySequence {
		entries = append(entries, entry)
	}
	sort.Slice(entries, func(left, right int) bool {
		return entries[left].Sequence < entries[right].Sequence
	})
	return entries, nil
}

func (s *FileStore) readCheckpointLocked(
	dir string, currentManifest manifest,
) (*Checkpoint, error) {
	if filepath.Base(currentManifest.CheckpointFile) != currentManifest.CheckpointFile ||
		!strings.HasPrefix(currentManifest.CheckpointFile, "checkpoint-") {
		return nil, fail(CodeCorrupt, "checkpoint filename is invalid", nil)
	}
	path := filepath.Join(dir, currentManifest.CheckpointFile)
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fail(CodeCorrupt, "checkpoint file is missing", err)
	}
	if checksum(raw) != currentManifest.CheckpointSHA256 {
		return nil, fail(CodeCorrupt, "checkpoint envelope checksum differs", nil)
	}
	var envelope checkpointEnvelope
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return nil, fail(CodeCorrupt, "checkpoint envelope is malformed", err)
	}
	if envelope.Version != StoreVersion {
		return nil, fail(CodeIncompatible, "checkpoint version is not supported", nil)
	}
	if envelope.MatchID != currentManifest.MatchID ||
		envelope.Sequence != currentManifest.CheckpointSequence {
		return nil, fail(CodeCorrupt, "checkpoint identity differs from manifest", nil)
	}
	if checksum(envelope.Payload) != envelope.PayloadSHA256 {
		return nil, fail(CodeCorrupt, "checkpoint payload checksum differs", nil)
	}
	return &Checkpoint{
		Version: envelope.Version, MatchID: envelope.MatchID,
		Sequence: envelope.Sequence, CodecID: envelope.CodecID,
		Payload:   append([]byte(nil), envelope.Payload...),
		StateHash: envelope.StateHash, Tick: envelope.Tick,
		CreatedUnixMs: envelope.CreatedUnixMs,
	}, nil
}

func (s *FileStore) appendRecordLocked(matchID string, record journalRecord) error {
	dir, err := s.matchDir(matchID)
	if err != nil {
		return err
	}
	record.Checksum = recordChecksum(record)
	raw, err := json.Marshal(record)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(filepath.Join(dir, "journal.jsonl"),
		os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return fail(CodeStorage, "could not open journal for append", err)
	}
	if _, err := file.Write(append(raw, '\n')); err != nil {
		_ = file.Close()
		return fail(CodeStorage, "could not append journal", err)
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return fail(CodeStorage, "could not sync journal", err)
	}
	return file.Close()
}

func (s *FileStore) writeManifestLocked(matchID string, value manifest) error {
	dir, err := s.matchDir(matchID)
	if err != nil {
		return err
	}
	value.UpdatedUnixMs = s.cfg.Now().UnixMilli()
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if err := atomicWrite(filepath.Join(dir, "manifest.json"), raw, 0o600); err != nil {
		return fail(CodeStorage, "could not atomically update committed watermark", err)
	}
	return nil
}

func (s *FileStore) compactJournalLocked(matchID string, checkpointSequence uint64) error {
	state, _, err := s.loadLocked(matchID)
	if err != nil {
		return err
	}
	cutoff := uint64(0)
	if checkpointSequence > uint64(s.cfg.RetainDedupe) {
		cutoff = checkpointSequence - uint64(s.cfg.RetainDedupe)
	}
	var output bytes.Buffer
	for _, entry := range state.Entries {
		if entry.Sequence <= cutoff {
			continue
		}
		prepare := recordForEntry(entry, "prepare")
		prepare.Checksum = recordChecksum(prepare)
		raw, _ := json.Marshal(prepare)
		output.Write(raw)
		output.WriteByte('\n')
		if entry.Committed {
			commit := recordForEntry(entry, "commit")
			commit.Checksum = recordChecksum(commit)
			raw, _ = json.Marshal(commit)
			output.Write(raw)
			output.WriteByte('\n')
		}
	}
	dir, err := s.matchDir(matchID)
	if err != nil {
		return err
	}
	return atomicWrite(filepath.Join(dir, "journal.jsonl"), output.Bytes(), 0o600)
}

func (s *FileStore) pruneCheckpointsLocked(dir, current string) error {
	matches, err := filepath.Glob(filepath.Join(dir, "checkpoint-*.json"))
	if err != nil {
		return err
	}
	sort.Strings(matches)
	keep := s.cfg.RetainCheckpoints
	if len(matches) <= keep {
		return nil
	}
	for _, path := range matches[:len(matches)-keep] {
		if filepath.Base(path) == current {
			continue
		}
		if err := os.Remove(path); err != nil {
			return fail(CodeStorage, "could not prune old checkpoint", err)
		}
	}
	return nil
}

func (s *FileStore) matchDir(matchID string) (string, error) {
	if strings.TrimSpace(matchID) == "" || len(matchID) > 256 {
		return "", fmt.Errorf("invalid match id")
	}
	sum := sha256.Sum256([]byte(matchID))
	dir := filepath.Join(s.cfg.Root, hex.EncodeToString(sum[:16]))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fail(CodeStorage, "could not create match store", err)
	}
	return dir, nil
}

func (s *FileStore) inject(point FaultPoint) error {
	if s.cfg.Fault == nil {
		return nil
	}
	if err := s.cfg.Fault(point); err != nil {
		return fail(CodeStorage, "injected crash at "+string(point), err)
	}
	return nil
}

func validateMutation(mutation Mutation) error {
	if mutation.MatchID == "" || mutation.Epoch == 0 || mutation.RequestID == 0 {
		return fmt.Errorf("match, epoch and request identity are required")
	}
	if mutation.Operation != OperationApplyCommand && mutation.Operation != OperationAdvance {
		return fmt.Errorf("unsupported durable operation %q", mutation.Operation)
	}
	if len(mutation.Request) == 0 {
		return fmt.Errorf("durable request bytes are required")
	}
	return nil
}

func recordForEntry(entry Entry, kind string) journalRecord {
	record := journalRecord{
		Version: StoreVersion, Kind: kind, MatchID: entry.MatchID,
		Sequence: entry.Sequence, Epoch: entry.Epoch, RequestID: entry.RequestID,
		Operation: entry.Operation,
	}
	if kind == "prepare" {
		record.Request = append([]byte(nil), entry.Request...)
	} else {
		record.Response = append([]byte(nil), entry.Response...)
		record.StateHash = entry.StateHash
	}
	return record
}

func validateRecord(record journalRecord, matchID string) error {
	if record.Version != StoreVersion {
		return fail(CodeIncompatible, "journal version is not supported", nil)
	}
	if record.MatchID != matchID || record.Sequence == 0 ||
		record.Epoch == 0 || record.RequestID == 0 {
		return fail(CodeCorrupt, "journal identity is invalid", nil)
	}
	if record.Checksum != recordChecksum(record) {
		return fail(CodeCorrupt, "journal checksum differs", nil)
	}
	return nil
}

func recordChecksum(record journalRecord) string {
	record.Checksum = ""
	raw, _ := json.Marshal(record)
	return checksum(raw)
}

func checksum(value []byte) string {
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}

func nextSequence(entries []Entry) uint64 {
	var result uint64 = 1
	for _, entry := range entries {
		if entry.Sequence >= result {
			result = entry.Sequence + 1
		}
	}
	return result
}

func lastIdentity(entries []Entry) (uint64, uint64) {
	var epoch, requestID uint64
	for _, entry := range entries {
		if entry.Epoch > epoch || (entry.Epoch == epoch && entry.RequestID > requestID) {
			epoch, requestID = entry.Epoch, entry.RequestID
		}
	}
	return epoch, requestID
}

func contiguousCommitted(entries []Entry, checkpointSequence uint64) uint64 {
	result := checkpointSequence
	for _, entry := range entries {
		if entry.Sequence <= result {
			continue
		}
		if entry.Sequence != result+1 || !entry.Committed {
			break
		}
		result = entry.Sequence
	}
	return result
}

func atomicWrite(path string, contents []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	temp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	tempName := temp.Name()
	defer os.Remove(tempName)
	if err := temp.Chmod(mode); err != nil {
		_ = temp.Close()
		return err
	}
	if _, err := temp.Write(contents); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tempName, path); err != nil {
		return err
	}
	directory, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func directoryBytes(root string) int64 {
	var total int64
	_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err == nil && !entry.IsDir() {
			if info, infoErr := entry.Info(); infoErr == nil {
				total += info.Size()
			}
		}
		return nil
	})
	return total
}
