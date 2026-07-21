package main

import (
	"archive/zip"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestManifestVersionsComeFromLocalSDK(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "playmesh", "sdk"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh.js"), `const PLAYMESH_SDK_VERSION = "1.4.0";`)
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh-app.js"), `const PLAYMESH_APP_SDK_VERSION = "1.2.0";`)
	writeTestFile(t, filepath.Join(root, "main.json"), `{"id":"com.example.game","sdkVersion":"9.9.9","appSdkVersion":"9.9.9"}`)

	versions, err := versionsFromSDK(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := updateManifestSDKVersions(root, versions); err != nil {
		t.Fatal(err)
	}
	var manifest map[string]any
	data, _ := os.ReadFile(filepath.Join(root, "main.json"))
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	if manifest["sdkVersion"] != "1.4.0" || manifest["appSdkVersion"] != "1.2.0" {
		t.Fatalf("manifest versions were not normalized: %#v", manifest)
	}
}

func TestInstallSDKUsesPlaymeshDirectoryAndPreservesLegacyState(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, ".playmesh", "sdk", "legacy.js"), "legacy")
	writeTestFile(t, filepath.Join(root, ".playmesh", "keep.txt"), "keep")
	encoded := func(value string) string {
		return base64.StdEncoding.EncodeToString([]byte(value))
	}
	bundle := sdkBundle{
		GameSDKVersion: "1.4.0",
		AppSDKVersion:  "1.2.0",
		Encoding:       "base64",
		Files: map[string]string{
			"playmesh.js":       encoded(`const PLAYMESH_SDK_VERSION = "1.4.0";`),
			"playmesh-app.js":   encoded(`const PLAYMESH_APP_SDK_VERSION = "1.2.0";`),
			"playmesh.d.ts":     encoded("declare const playmesh: unknown;"),
			"playmesh-app.d.ts": encoded("declare const playmeshApp: unknown;"),
		},
	}
	if _, err := installSDK(root, bundle); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "playmesh", "sdk", "playmesh.js")); err != nil {
		t.Fatalf("new SDK directory was not installed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".playmesh", "sdk", "legacy.js")); err != nil {
		t.Fatalf("legacy .playmesh/sdk content must be preserved: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".playmesh", "keep.txt")); err != nil {
		t.Fatalf("non-SDK legacy content must be preserved: %v", err)
	}
}

func TestBuildPackageExcludesPlaymeshSDK(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "main.json"), `{"id":"com.example.game"}`)
	writeTestFile(t, filepath.Join(root, "capabilities.json"), `{"required":[]}`)
	writeTestFile(t, filepath.Join(root, "app", "index.html"), "<!doctype html>")
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh.js"), "private")
	data, err := buildPackage(root)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	paths := map[string]bool{}
	for _, entry := range reader.File {
		paths[entry.Name] = true
	}
	if !paths["main.json"] || !paths["capabilities.json"] || !paths["app/index.html"] {
		t.Fatalf("package is incomplete: %#v", paths)
	}
	if paths["playmesh/sdk/playmesh.js"] {
		t.Fatal("local SDK must never enter the package")
	}
}

func TestExtractProjectPackageKeepsAppDirectory(t *testing.T) {
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for path, value := range map[string]string{
		"main.json":      `{"id":"com.example.get"}`,
		"app/index.html": "<!doctype html>",
	} {
		entry, err := writer.Create(path)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write([]byte(value)); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	root := t.TempDir()
	if err := extractProjectPackage(buffer.Bytes(), root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "app", "index.html")); err != nil {
		t.Fatalf("package app/ was not extracted to local app/: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "game")); !os.IsNotExist(err) {
		t.Fatal("local project must not create a game/ compatibility mirror")
	}
}

func writeTestFile(t *testing.T, path, value string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(value), 0o644); err != nil {
		t.Fatal(err)
	}
}
