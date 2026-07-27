package main

import (
	"archive/zip"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
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
	writeTestFile(t, filepath.Join(root, "main.json"), `{"id":"com.example.game","sdkVersion":"9.9.9","appSdkVersion":"9.9.9","permissions":["keyboard"],"icon":"app/legacy.png","redundant":{"kept":false}}`)

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
	if _, exists := manifest["permissions"]; exists {
		t.Fatalf("removed permissions field was preserved: %#v", manifest)
	}
	if _, exists := manifest["icon"]; exists {
		t.Fatalf("unknown field was preserved: %#v", manifest)
	}
	if _, exists := manifest["redundant"]; exists {
		t.Fatalf("ordinary unknown field was preserved: %#v", manifest)
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
	writeTestFile(t, filepath.Join(root, "main.json"), `{"id":"com.example.game","permissions":["keyboard"],"icon":"app/legacy.png","redundant":true}`)
	writeTestFile(t, filepath.Join(root, "capabilities.json"), `{"required":[]}`)
	writeTestFile(t, filepath.Join(root, "app", "index.html"), "<!doctype html>")
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh.js"), "private")
	writeTestBytes(t, filepath.Join(root, rootIconName), validRootIcon(t))
	data, err := buildPackage(root)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	paths := map[string]bool{}
	var packedManifest map[string]any
	for _, entry := range reader.File {
		paths[entry.Name] = true
		if entry.Name == "main.json" {
			stream, err := entry.Open()
			if err != nil {
				t.Fatal(err)
			}
			if err := json.NewDecoder(stream).Decode(&packedManifest); err != nil {
				stream.Close()
				t.Fatal(err)
			}
			stream.Close()
		}
	}
	if !paths["main.json"] || !paths["capabilities.json"] ||
		!paths[rootIconName] || !paths["app/index.html"] {
		t.Fatalf("package is incomplete: %#v", paths)
	}
	if paths["playmesh/sdk/playmesh.js"] {
		t.Fatal("local SDK must never enter the package")
	}
	if _, exists := packedManifest["permissions"]; exists {
		t.Fatalf("removed permissions field entered package: %#v", packedManifest)
	}
	if _, exists := packedManifest["icon"]; exists {
		t.Fatalf("unknown field entered package: %#v", packedManifest)
	}
	if _, exists := packedManifest["redundant"]; exists {
		t.Fatalf("ordinary unknown field entered package: %#v", packedManifest)
	}
}

func TestBuildPackageIgnoresUnsafeRootIcon(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "main.json"), `{"id":"com.example.game"}`)
	writeTestFile(t, filepath.Join(root, "capabilities.json"), `{"required":[]}`)
	writeTestFile(t, filepath.Join(root, "app", "index.html"), "<!doctype html>")
	writeTestFile(t, filepath.Join(root, rootIconName), "not a png")

	data, err := buildPackage(root)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range reader.File {
		if entry.Name == rootIconName {
			t.Fatal("unsafe icon.png must be ignored instead of entering the package")
		}
	}
}

func TestBuildPackageRejectsRootIconDirectory(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "main.json"), `{"id":"com.example.game"}`)
	writeTestFile(t, filepath.Join(root, "capabilities.json"), `{"required":[]}`)
	writeTestFile(t, filepath.Join(root, "app", "index.html"), "<!doctype html>")
	if err := os.Mkdir(filepath.Join(root, rootIconName), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := buildPackage(root); err == nil {
		t.Fatal("icon.png directory must be rejected")
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
	iconEntry, err := writer.Create(rootIconName)
	if err != nil {
		t.Fatal(err)
	}
	icon := validRootIcon(t)
	if _, err := iconEntry.Write(icon); err != nil {
		t.Fatal(err)
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
	extractedIcon, err := os.ReadFile(filepath.Join(root, rootIconName))
	if err != nil || !bytes.Equal(extractedIcon, icon) {
		t.Fatalf("root icon.png was not preserved: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "game")); !os.IsNotExist(err) {
		t.Fatal("local project must not create a game/ compatibility mirror")
	}
}

func TestExtractProjectPackageRemovesStaleIconWhenRemoteHasNone(t *testing.T) {
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	entry, err := writer.Create("main.json")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.Write([]byte(`{"id":"com.example.get"}`)); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	root := t.TempDir()
	writeTestBytes(t, filepath.Join(root, rootIconName), validRootIcon(t))
	if err := extractProjectPackage(buffer.Bytes(), root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, rootIconName)); !os.IsNotExist(err) {
		t.Fatal("get without icon.png must remove the stale local icon")
	}
}

func TestExtractProjectPackageIgnoresUnsafeIcon(t *testing.T) {
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for path, value := range map[string]string{
		"main.json":  `{"id":"com.example.get"}`,
		rootIconName: "not a png",
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
	writeTestBytes(t, filepath.Join(root, rootIconName), validRootIcon(t))
	if err := extractProjectPackage(buffer.Bytes(), root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, rootIconName)); !os.IsNotExist(err) {
		t.Fatal("unsafe downloaded icon.png must be ignored and stale content removed")
	}
}

func TestExtractProjectPackageRejectsIconSymlink(t *testing.T) {
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	manifest, err := writer.Create("main.json")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manifest.Write([]byte(`{"id":"com.example.get"}`)); err != nil {
		t.Fatal(err)
	}
	header := &zip.FileHeader{Name: rootIconName, Method: zip.Store}
	header.SetMode(os.ModeSymlink | 0o777)
	link, err := writer.CreateHeader(header)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := link.Write([]byte("outside.png")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := extractProjectPackage(buffer.Bytes(), t.TempDir()); err == nil {
		t.Fatal("icon.png symlink must be rejected")
	}
}

func TestExtractProjectPackageAllowsBrokenProjectWithoutApp(t *testing.T) {
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	entry, err := writer.Create("main.json")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.Write([]byte(`{"id":"com.example.broken"}`)); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	root := t.TempDir()
	if err := extractProjectPackage(buffer.Bytes(), root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "main.json")); err != nil {
		t.Fatalf("broken manifest must remain recoverable: %v", err)
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

func writeTestBytes(t *testing.T, path string, value []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, value, 0o644); err != nil {
		t.Fatal(err)
	}
}

func validRootIcon(t *testing.T) []byte {
	t.Helper()
	var buffer bytes.Buffer
	icon := image.NewRGBA(image.Rect(0, 0, 2, 2))
	icon.Set(0, 0, color.RGBA{R: 0x25, G: 0xb8, B: 0x7a, A: 0xff})
	if err := png.Encode(&buffer, icon); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}
