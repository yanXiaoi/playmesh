package health

import (
	"context"
	"testing"
	"time"
)

func TestServiceCheckReturnsOnlineSnapshot(t *testing.T) {
	startedAt := time.Date(2026, time.July, 15, 8, 30, 0, 0, time.UTC)
	service := NewService("0.1.0", startedAt)

	snapshot, err := service.Check(context.Background())
	if err != nil {
		t.Fatalf("Check() error = %v", err)
	}
	if snapshot.Status != OnlineStatus {
		t.Fatalf("Status = %q, want %q", snapshot.Status, OnlineStatus)
	}
	if snapshot.CoreVersion != "0.1.0" {
		t.Fatalf("CoreVersion = %q, want 0.1.0", snapshot.CoreVersion)
	}
	if snapshot.StartedAt != startedAt.UnixMilli() {
		t.Fatalf("StartedAt = %d, want %d", snapshot.StartedAt, startedAt.UnixMilli())
	}
}
