package recovery

import (
	"context"
	"time"
)

const StoreVersion = 1

type Operation string

const (
	OperationApplyCommand Operation = "apply_command"
	OperationAdvance      Operation = "advance"
)

type Mutation struct {
	MatchID   string
	Epoch     uint64
	RequestID uint64
	Operation Operation
	Request   []byte
}

type Entry struct {
	Mutation
	Sequence  uint64
	Committed bool
	Response  []byte
	StateHash string
}

type Checkpoint struct {
	Version       int
	MatchID       string
	Sequence      uint64
	CodecID       string
	Payload       []byte
	StateHash     string
	Tick          uint64
	CreatedUnixMs int64
}

type State struct {
	Version            int
	MatchID            string
	CommittedSequence  uint64
	CheckpointSequence uint64
	LastEpoch          uint64
	LastRequestID      uint64
	Checkpoint         *Checkpoint
	Entries            []Entry
	StorageBytes       int64
}

func (s State) ReplayEntries() []Entry {
	result := make([]Entry, 0)
	for _, entry := range s.Entries {
		if entry.Committed && entry.Sequence > s.CheckpointSequence {
			result = append(result, entry)
		}
	}
	return result
}

type PrepareResult struct {
	Entry     Entry
	Duplicate bool
}

type Store interface {
	Prepare(context.Context, Mutation) (PrepareResult, error)
	Commit(context.Context, string, uint64, []byte, string) (Entry, error)
	SaveCheckpoint(context.Context, Checkpoint) error
	Load(context.Context, string) (State, error)
	Close() error
}

type FaultPoint string

const (
	FaultAfterPrepareSync      FaultPoint = "after_prepare_sync"
	FaultAfterCommitSync       FaultPoint = "after_commit_sync"
	FaultAfterCheckpointRename FaultPoint = "after_checkpoint_rename"
)

type FileStoreConfig struct {
	Root              string
	RetainCheckpoints int
	RetainDedupe      int
	Fault             func(FaultPoint) error
	Now               func() time.Time
}
