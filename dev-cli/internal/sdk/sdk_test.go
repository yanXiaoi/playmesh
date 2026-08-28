package sdk

import "testing"

func TestVersionsFromBytesDoesNotRestrictVersionIdentifiers(t *testing.T) {
	versions, err := VersionsFromBytes(
		[]byte(`const PLAYMESH_SDK_VERSION = "2026.8-next";`),
		[]byte(`const PLAYMESH_APP_SDK_VERSION = "gateway-current";`),
	)
	if err != nil {
		t.Fatal(err)
	}
	if versions.Game != "2026.8-next" || versions.App != "gateway-current" {
		t.Fatalf("version identifiers were changed: %#v", versions)
	}
}
