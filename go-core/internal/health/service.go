package health

import (
	"context"
	"time"
)

const OnlineStatus = "online"

type Snapshot struct {
	Status      string `json:"status"`
	CoreVersion string `json:"coreVersion"`
	StartedAt   int64  `json:"startedAt"`
}

type Checker interface {
	Check(context.Context) (Snapshot, error)
}

type Service struct {
	coreVersion string
	startedAt   time.Time
}

func NewService(coreVersion string, startedAt time.Time) *Service {
	return &Service{
		coreVersion: coreVersion,
		startedAt:   startedAt.UTC(),
	}
}

func (s *Service) Check(context.Context) (Snapshot, error) {
	return Snapshot{
		Status:      OnlineStatus,
		CoreVersion: s.coreVersion,
		StartedAt:   s.startedAt.UnixMilli(),
	}, nil
}
