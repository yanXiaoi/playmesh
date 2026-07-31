package target

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type testProtector struct{}

func (testProtector) Protect(token string) (string, string, error) {
	return "test-protected", base64.StdEncoding.EncodeToString([]byte(token)), nil
}

func (testProtector) Unprotect(storage, protected string) (string, error) {
	data, err := base64.StdEncoding.DecodeString(protected)
	return string(data), err
}

func TestParseWorkspaceURL(t *testing.T) {
	target, err := ParseWorkspaceURL(
		"http://10.31.2.222:16666/dev/workspace-id/workspace?token=secret-token",
	)
	if err != nil {
		t.Fatal(err)
	}
	if target.BaseURL != "http://10.31.2.222:16666" {
		t.Fatalf("unexpected base URL: %s", target.BaseURL)
	}
	if target.WorkspaceID != "workspace-id" || target.Token != "secret-token" {
		t.Fatalf("unexpected parsed target: %#v", target)
	}
	if target.WorkspaceURL != "http://10.31.2.222:16666/dev/workspace-id/workspace" {
		t.Fatalf("workspace URL must not retain token: %s", target.WorkspaceURL)
	}
}

func TestParseWorkspaceURLRejectsMissingToken(t *testing.T) {
	if _, err := ParseWorkspaceURL("http://127.0.0.1:16666/dev/id/workspace"); err == nil {
		t.Fatal("expected missing token to fail")
	}
}

func TestSaveTargetNeverWritesPlaintextToken(t *testing.T) {
	t.Setenv("APPDATA", t.TempDir())
	target := Config{
		BaseURL:      "http://127.0.0.1:16666",
		WorkspaceURL: "http://127.0.0.1:16666/dev/id/workspace",
		WorkspaceID:  "id",
		Token:        "plain-secret-token",
	}
	store := NewSystemStoreWithProtector(testProtector{})
	if err := store.Save(target); err != nil {
		t.Fatal(err)
	}
	path, err := systemConfigPath()
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), target.Token) ||
		strings.Contains(string(data), `"token":`) {
		t.Fatalf("target config leaked plaintext token: %s", data)
	}
	if !strings.Contains(string(data), `"tokenStorage": "test-protected"`) {
		t.Fatalf("target config did not record protected storage: %s", data)
	}
	loaded, err := store.Load()
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Token != target.Token || loaded.BaseURL != target.BaseURL {
		t.Fatalf("protected target did not round-trip: %#v", loaded)
	}
}

func TestLoadTargetRejectsLegacyPlaintextToken(t *testing.T) {
	t.Setenv("APPDATA", t.TempDir())
	path, err := systemConfigPath()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		path,
		[]byte(`{"baseUrl":"http://127.0.0.1:16666","token":"legacy-secret"}`),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	store := NewSystemStoreWithProtector(testProtector{})
	if _, err := store.Load(); err == nil ||
		!strings.Contains(err.Error(), "配置不完整") {
		t.Fatalf("legacy plaintext token must be rejected, got %v", err)
	}
}
