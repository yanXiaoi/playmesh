package webpath

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestUserAppDirectoryIsOrdinaryWebContent(t *testing.T) {
	appRoot := filepath.Join(t.TempDir(), "playmesh", "package", "app")
	output, err := ResolveAppOutputDirectory(appRoot, "app")
	if err != nil {
		t.Fatal(err)
	}
	if output != filepath.Join(appRoot, "app") {
		t.Fatalf("unexpected physical output directory: %s", output)
	}
	if err := ValidateWebEntry(
		"app/index.html",
		"playmesh-cli.json.integration.entry",
	); err != nil {
		t.Fatal(err)
	}
}

func TestHTMLWebEntryAllowsQueryWhilePhysicalPathStaysStable(
	t *testing.T,
) {
	const entry = "preview/session/index.html?scene=first&scene=second&encoded=%2Fkeep%2forder"
	if err := ValidateWebEntryURL(entry, "entry"); err != nil {
		t.Fatal(err)
	}
	if path := WebEntryPath(entry); path != "preview/session/index.html" {
		t.Fatalf("unexpected physical entry path: %q", path)
	}
}

func TestHTMLWebEntryTreatsQueryAsOpaqueLocalData(t *testing.T) {
	for _, entry := range []string{
		"index.html?target=http://127.0.0.1/example",
		"index.html?raw=%zz",
		"index.html?text=hello world",
		"index.html?windows=folder\\file",
	} {
		if err := ValidateWebEntryURL(entry, "entry"); err != nil {
			t.Fatalf("opaque local query %q was rejected: %v", entry, err)
		}
	}
	if err := ValidateWebEntryURL("index.html?", "entry"); err == nil {
		t.Fatal("empty query entry was accepted")
	}
}

func TestWebEntryStillRejectsUnsafeAndReservedPaths(t *testing.T) {
	for _, value := range []string{
		"/app/index.html",
		"playmesh/index.html",
		"BUCKET/index.html",
		"assets/../index.html",
		"%61pp/index.html",
		"index.html#debug",
		"authority.js?scene=main",
		"https://example.com/index.html?scene=main",
	} {
		t.Run(strings.ReplaceAll(value, "/", "_"), func(t *testing.T) {
			if err := ValidateWebEntry(value, "entry"); err == nil {
				t.Fatalf("unsafe or reserved entry %q was accepted", value)
			}
		})
	}
}
