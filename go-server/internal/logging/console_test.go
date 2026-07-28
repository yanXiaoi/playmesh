package logging

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestConsoleHandlerAvoidsHTMLEncodedJSONQuotes(t *testing.T) {
	var output bytes.Buffer
	logger := slog.New(NewConsoleHandler(&output, slog.LevelDebug))
	record := slog.NewRecord(
		time.Date(2026, 7, 27, 18, 34, 12, 0, time.FixedZone("CST", 8*60*60)),
		slog.LevelInfo,
		"HTTP 请求",
		0,
	)
	record.Add(
		"method", "GET",
		"path", "/admin",
		"status", 200,
		"error", `Get "https://example.com/image?a=1&b=2": timeout`,
	)
	if err := logger.Handler().Handle(context.Background(), record); err != nil {
		t.Fatal(err)
	}
	line := output.String()
	for _, expected := range []string{
		"2026-07-27 18:34:12 [INFO] HTTP 请求",
		"method=[GET]",
		"path=[/admin]",
		"status=[200]",
		"error=[Get https://example.com/image?a=1＆b=2: timeout]",
	} {
		if !strings.Contains(line, expected) {
			t.Fatalf("console log is missing %q: %s", expected, line)
		}
	}
	for _, unsafe := range []string{`"`, "'", "&", "<", ">"} {
		if strings.Contains(line, unsafe) {
			t.Fatalf("console log contains HTML-sensitive text %q: %s", unsafe, line)
		}
	}
}
