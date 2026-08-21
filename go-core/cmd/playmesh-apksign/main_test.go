package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolvePasswordLiteralEnvironmentAndFile(t *testing.T) {
	t.Setenv("PLAYMESH_APKSIGN_TEST_PASS", "from-environment")
	passwordFile := filepath.Join(t.TempDir(), "password.txt")
	if err := os.WriteFile(passwordFile, []byte("from-file\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	tests := map[string]string{
		"literal":                        "literal",
		"env:PLAYMESH_APKSIGN_TEST_PASS": "from-environment",
		"file:" + passwordFile:           "from-file",
	}
	for specification, expected := range tests {
		actual, err := resolvePassword(specification)
		if err != nil {
			t.Fatalf("resolvePassword(%q): %v", specification, err)
		}
		if actual != expected {
			t.Fatalf("resolvePassword(%q) = %q, want %q", specification, actual, expected)
		}
	}
}

func TestResolvePasswordRejectsEmptyFilePath(t *testing.T) {
	if _, err := resolvePassword("file:"); err == nil {
		t.Fatal("resolvePassword(file:) should fail")
	}
}

func TestResolveRuntimeExportRequestLiteralAndFile(t *testing.T) {
	literal := `{"templateZipPath":"template.zip"}`
	actual, err := resolveRuntimeExportRequest(literal, "")
	if err != nil {
		t.Fatalf("literal request: %v", err)
	}
	if actual != literal {
		t.Fatalf("literal request = %q, want %q", actual, literal)
	}

	requestFile := filepath.Join(t.TempDir(), "request.json")
	if err := os.WriteFile(requestFile, []byte(literal), 0o600); err != nil {
		t.Fatal(err)
	}
	actual, err = resolveRuntimeExportRequest("", requestFile)
	if err != nil {
		t.Fatalf("file request: %v", err)
	}
	if actual != literal {
		t.Fatalf("file request = %q, want %q", actual, literal)
	}
	actual, err = resolveRuntimeExportRequest(requestFile, "")
	if err != nil {
		t.Fatalf("-request file alias: %v", err)
	}
	if actual != literal {
		t.Fatalf("-request file alias = %q, want %q", actual, literal)
	}
}

func TestResolveRuntimeExportRequestRejectsInvalidSelectionAndJSON(t *testing.T) {
	for name, inputs := range map[string][2]string{
		"missing": {},
		"both":    {`{}`, "request.json"},
		"invalid": {`not-json`, ""},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := resolveRuntimeExportRequest(inputs[0], inputs[1]); err == nil {
				t.Fatal("request should fail")
			}
		})
	}
}
