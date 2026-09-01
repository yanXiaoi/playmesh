package packaging

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"io"
	"path/filepath"
	"testing"
)

func TestBuildUploadPassesPackageContentsThroughWithoutValidation(t *testing.T) {
	root := t.TempDir()
	manifest := `{"id":"com.example.passthrough","sdkVersion":"999.0.0","appSdkVersion":"gateway-current","unknown":{"preserve":true}}`
	writeTestFile(t, filepath.Join(root, "main.json"), manifest)
	writeTestFile(t, filepath.Join(root, "capabilities.json"), `[]`)
	writeTestFile(t, filepath.Join(root, RootIconName), "not a PNG")
	writeTestFile(t, filepath.Join(root, "app", "asset.bin"), "payload")

	archive, err := BuildUpload(root)
	if err != nil {
		t.Fatal(err)
	}
	files := readUploadArchive(t, archive)
	for name, want := range map[string]string{
		"main.json":         manifest,
		"capabilities.json": `[]`,
		RootIconName:        "not a PNG",
		"app/asset.bin":     "payload",
	} {
		if got := string(files[name]); got != want {
			t.Fatalf("uploaded %s = %q, want %q", name, got, want)
		}
	}
}

func TestBuildUploadLeavesMissingPackagePartsForGatewayValidation(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "main.json"), `{"id":"com.example.gateway-validation"}`)

	archive, err := BuildUpload(root)
	if err != nil {
		t.Fatal(err)
	}
	files := readUploadArchive(t, archive)
	if len(files) != 1 || files["main.json"] == nil {
		t.Fatalf("unexpected upload contents: %#v", files)
	}
}

func TestBuildDevelopmentUploadDoesNotValidateManifestVersionsOrCapabilities(t *testing.T) {
	root := t.TempDir()
	writeTestFile(
		t,
		filepath.Join(root, "main.json"),
		`{"id":"com.example.development-passthrough","sdkVersion":"future","appSdkVersion":"next","entries":{"game":"old.html"}}`,
	)
	writeTestFile(t, filepath.Join(root, "capabilities.json"), `[]`)
	writeTestFile(t, filepath.Join(root, RootIconName), "invalid icon")

	archive, projectID, err := BuildDevelopmentUpload(
		root,
		"preview/current.html?debug=1",
	)
	if err != nil {
		t.Fatal(err)
	}
	if projectID != "com.example.development-passthrough" {
		t.Fatalf("project ID = %q", projectID)
	}
	files := readUploadArchive(t, archive)
	if string(files["capabilities.json"]) != `[]` ||
		string(files[RootIconName]) != "invalid icon" {
		t.Fatalf("gateway-owned fields were changed: %#v", files)
	}
	if files["app/preview/current.html"] == nil {
		t.Fatalf("development placeholder missing: %#v", files)
	}
	var archivedManifest map[string]any
	if err := json.Unmarshal(files["main.json"], &archivedManifest); err != nil {
		t.Fatal(err)
	}
	entries, _ := archivedManifest["entries"].(map[string]any)
	if entries["game"] != "preview/current.html?debug=1" ||
		archivedManifest["sdkVersion"] != "future" ||
		archivedManifest["appSdkVersion"] != "next" {
		t.Fatalf("development manifest was unexpectedly normalized: %#v", archivedManifest)
	}
}

func readUploadArchive(t *testing.T, data []byte) map[string][]byte {
	t.Helper()
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	files := make(map[string][]byte, len(reader.File))
	for _, entry := range reader.File {
		input, err := entry.Open()
		if err != nil {
			t.Fatal(err)
		}
		content, err := io.ReadAll(input)
		_ = input.Close()
		if err != nil {
			t.Fatal(err)
		}
		files[entry.Name] = content
	}
	return files
}
