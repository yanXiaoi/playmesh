// Package runtimecrypto exposes the narrow package-encryption boundary used by
// Playmesh exporters and compiled Runtime hosts.
//
// The repository-owned package deliberately contains no cryptographic
// implementation. Release builds install the private implementation from the
// ignored runtime/crypto overlay. A build which omits that overlay fails closed.
package runtimecrypto

import (
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"sync"
)

const (
	CodecAESGCMV1 = "aes-gcm-v1"

	WindowsScheme    = "win-rsa-oaep-sha256-v1"
	WindowsOAEPLabel = "Playmesh Windows Runtime Package Key v1"

	AndroidScheme    = "android-rsa-oaep-sha256-v1"
	AndroidOAEPLabel = "Playmesh Android Runtime Package Key v1"
)

// ErrPrivateCryptoUnavailable is returned by ordinary/public builds. It is a
// stable sentinel so callers can report a missing private release overlay
// without silently weakening package protection.
var ErrPrivateCryptoUnavailable = errors.New("private_crypto_unavailable")

// FailureKind is intentionally coarse. Runtime bridges must not expose RSA or
// authentication internals as a detailed decryption oracle.
type FailureKind uint8

const (
	FailureInternal FailureKind = iota
	FailureInvalidArgument
	FailureContract
	FailureAuthentication
	FailureUnavailable
)

// Failure describes a private-provider failure without embedding secret data.
type Failure struct {
	Kind      FailureKind
	Operation string
	Cause     error
}

func (failure *Failure) Error() string {
	if failure == nil {
		return "runtime crypto failure"
	}
	if failure.Cause == nil {
		return failure.Operation
	}
	return fmt.Sprintf("%s: %v", failure.Operation, failure.Cause)
}

func (failure *Failure) Unwrap() error {
	if failure == nil {
		return nil
	}
	return failure.Cause
}

// Classify returns a stable, deliberately coarse category for a bridge error.
func Classify(err error) FailureKind {
	if err == nil {
		return FailureInternal
	}
	var failure *Failure
	if errors.As(err, &failure) {
		return failure.Kind
	}
	if errors.Is(err, ErrPrivateCryptoUnavailable) {
		return FailureUnavailable
	}
	return FailureInternal
}

// EncryptResult is the complete output required by an APK/Windows bundle
// exporter. Envelope is PME1 bytes; KeyID contains the scheme, exact SPKI
// fingerprint, and RSA-OAEP-wrapped per-export AES key.
type EncryptResult struct {
	Envelope        []byte
	KeyID           string
	Scheme          string
	Codec           string
	PublicKeySHA256 string
}

type encryptProvider interface {
	encryptPME1(
		clear []byte,
		publicKeyDER []byte,
		scheme string,
		label string,
		randomness io.Reader,
	) (*EncryptResult, error)
}

type decryptProvider interface {
	decryptPME1(
		envelope []byte,
		keyID string,
		privateKeyPKCS8PEM []byte,
		scheme string,
		label string,
	) ([]byte, error)
}

var (
	providerMutex         sync.RWMutex
	activeEncryptProvider encryptProvider
	activeDecryptProvider decryptProvider
)

// installProvider is intentionally unexported. The ignored private overlay is
// copied into this same package in a controlled staging tree and installs its
// implementation from init().
func installEncryptProvider(candidate encryptProvider) {
	if candidate == nil {
		panic("runtimecrypto: attempted to install a nil private encrypt provider")
	}
	providerMutex.Lock()
	defer providerMutex.Unlock()
	if activeEncryptProvider != nil {
		panic("runtimecrypto: more than one private encrypt provider was installed")
	}
	activeEncryptProvider = candidate
}

func installDecryptProvider(candidate decryptProvider) {
	if candidate == nil {
		panic("runtimecrypto: attempted to install a nil private decrypt provider")
	}
	providerMutex.Lock()
	defer providerMutex.Unlock()
	if activeDecryptProvider != nil {
		panic("runtimecrypto: more than one private decrypt provider was installed")
	}
	activeDecryptProvider = candidate
}

func currentEncryptProvider(operation string) (encryptProvider, error) {
	providerMutex.RLock()
	candidate := activeEncryptProvider
	providerMutex.RUnlock()
	if candidate == nil {
		return nil, &Failure{
			Kind:      FailureUnavailable,
			Operation: operation,
			Cause:     ErrPrivateCryptoUnavailable,
		}
	}
	return candidate, nil
}

func currentDecryptProvider(operation string) (decryptProvider, error) {
	providerMutex.RLock()
	candidate := activeDecryptProvider
	providerMutex.RUnlock()
	if candidate == nil {
		return nil, &Failure{
			Kind:      FailureUnavailable,
			Operation: operation,
			Cause:     ErrPrivateCryptoUnavailable,
		}
	}
	return candidate, nil
}

// EncryptPME1 creates a fresh PME1 envelope. Every call uses a fresh 256-bit
// AES key and 96-bit nonce from crypto/rand; the AES key is wrapped by the exact
// RSA-3072 public key supplied by the exporter.
func EncryptPME1(
	clear []byte,
	publicKeyDER []byte,
	scheme string,
	label string,
) (*EncryptResult, error) {
	candidate, err := currentEncryptProvider("encrypt PME1")
	if err != nil {
		return nil, err
	}
	return candidate.encryptPME1(clear, publicKeyDER, scheme, label, rand.Reader)
}

// DecryptPME1 strictly validates keyID, unwraps its AES key using the supplied
// PKCS#8 RSA private key, authenticates the PME1 envelope, and returns clear
// bytes. Runtime-only wrappers embed and supply the platform private key; Dart,
// Java, and C++ must never receive that key or the unwrapped AES key.
func DecryptPME1(
	envelope []byte,
	keyID string,
	privateKeyPKCS8PEM []byte,
	scheme string,
	label string,
) ([]byte, error) {
	candidate, err := currentDecryptProvider("decrypt PME1")
	if err != nil {
		return nil, err
	}
	return candidate.decryptPME1(
		envelope,
		keyID,
		privateKeyPKCS8PEM,
		scheme,
		label,
	)
}
