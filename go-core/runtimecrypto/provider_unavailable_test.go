//go:build !playmesh_private_crypto && !playmesh_runtime_private

package runtimecrypto

import (
	"errors"
	"testing"
)

func TestPublicBuildFailsClosedWithoutPrivateProvider(t *testing.T) {
	if result, err := EncryptPME1(nil, nil, WindowsScheme, WindowsOAEPLabel); result != nil ||
		!errors.Is(err, ErrPrivateCryptoUnavailable) || Classify(err) != FailureUnavailable {
		t.Fatalf("EncryptPME1() = (%v, %v), want private_crypto_unavailable", result, err)
	}
	if clear, err := DecryptPME1(nil, "", nil, WindowsScheme, WindowsOAEPLabel); clear != nil ||
		!errors.Is(err, ErrPrivateCryptoUnavailable) || Classify(err) != FailureUnavailable {
		t.Fatalf("DecryptPME1() = (%v, %v), want private_crypto_unavailable", clear, err)
	}
}
