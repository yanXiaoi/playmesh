//go:build windows

package credential

import "testing"

func TestWindowsDPAPITokenRoundTrip(t *testing.T) {
	storage, protected, err := platformProtect("dpapi-test-token")
	if err != nil {
		t.Fatal(err)
	}
	if protected == "" || protected == "dpapi-test-token" {
		t.Fatal("DPAPI did not return protected ciphertext")
	}
	token, err := platformUnprotect(storage, protected)
	if err != nil {
		t.Fatal(err)
	}
	if token != "dpapi-test-token" {
		t.Fatalf("DPAPI token mismatch: %q", token)
	}
}
