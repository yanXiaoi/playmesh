package development

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestRebuildingDevelopmentHandlerRefreshesChangedSource(t *testing.T) {
	root := t.TempDir()
	sourceRoot := filepath.Join(root, "src")
	webRoot := filepath.Join(root, "playmesh", "package", "app")
	writeTestFile(t, filepath.Join(sourceRoot, "main.ts"), "export const value = 1;")
	writeTestFile(t, filepath.Join(webRoot, "index.html"), "<title>old</title>")
	var builds atomic.Int32
	handler, err := NewRebuildingHandler(
		sourceRoot,
		webRoot,
		func(ctx context.Context) error {
			builds.Add(1)
			return os.WriteFile(
				filepath.Join(webRoot, "index.html"),
				[]byte("<title>updated</title>"),
				0o644,
			)
		},
	)
	if err != nil {
		t.Fatal(err)
	}

	first := httptest.NewRecorder()
	handler.ServeHTTP(
		first,
		httptest.NewRequest(http.MethodGet, "/index.html", nil),
	)
	if first.Code != http.StatusOK ||
		!strings.Contains(first.Body.String(), "old") ||
		builds.Load() != 0 {
		t.Fatalf("unchanged source unexpectedly rebuilt: %d %q", first.Code, first.Body.String())
	}

	writeTestFile(
		t,
		filepath.Join(sourceRoot, "main.ts"),
		"export const value = 200;",
	)
	second := httptest.NewRecorder()
	handler.ServeHTTP(
		second,
		httptest.NewRequest(http.MethodGet, "/index.html", nil),
	)
	if second.Code != http.StatusOK ||
		!strings.Contains(second.Body.String(), "updated") ||
		builds.Load() != 1 {
		t.Fatalf(
			"changed source was not rebuilt once: builds=%d code=%d body=%q",
			builds.Load(),
			second.Code,
			second.Body.String(),
		)
	}
}

func TestSafeDevelopmentFileHandlerRejectsSymlinkDirectoryIndex(t *testing.T) {
	root := t.TempDir()
	webRoot := filepath.Join(root, "web")
	if err := os.MkdirAll(webRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	secret := filepath.Join(root, "secret.html")
	writeTestFile(t, secret, "<title>secret</title>")
	if err := os.Symlink(secret, filepath.Join(webRoot, "index.html")); err != nil {
		t.Skipf("当前环境无法创建符号链接: %v", err)
	}

	response := httptest.NewRecorder()
	safeDevelopmentFileHandler(webRoot).ServeHTTP(
		response,
		httptest.NewRequest(http.MethodGet, "/", nil),
	)
	if response.Code != http.StatusNotFound ||
		strings.Contains(response.Body.String(), "secret") {
		t.Fatalf(
			"directory index symlink escaped web root: code=%d body=%q",
			response.Code,
			response.Body.String(),
		)
	}
}
