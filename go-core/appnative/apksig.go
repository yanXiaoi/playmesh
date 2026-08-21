package appnative

import (
	"archive/zip"
	"crypto/ecdsa"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/agusibrahim/apksig-go/pkg/algo"
	"github.com/agusibrahim/apksig-go/pkg/apkverifier"
	"github.com/agusibrahim/apksig-go/pkg/apkwriter"
	"github.com/agusibrahim/apksig-go/pkg/datasource"
	"github.com/agusibrahim/apksig-go/pkg/keystore"
	"github.com/agusibrahim/apksig-go/pkg/signer"
)

const (
	apkSigBridgeVersion = "0.1.0"
	apkSigSourceVersion = "apksig-go@a0389a9d7f83032504713ac6052f85edfb52f64b"
	apkSigVerifyMinSDK  = 24
	apkSigVerifyMaxSDK  = 36
)

type apkSignerInfoReport struct {
	BridgeVersion        string `json:"bridgeVersion"`
	SourceVersion        string `json:"sourceVersion"`
	KeystoreFormat       string `json:"keystoreFormat"`
	RequestedAlias       string `json:"requestedAlias,omitempty"`
	CertificateSubject   string `json:"certificateSubject"`
	CertificateIssuer    string `json:"certificateIssuer"`
	CertificateSerial    string `json:"certificateSerial"`
	CertificateSHA256    string `json:"certificateSha256"`
	CertificateNotBefore string `json:"certificateNotBefore"`
	CertificateNotAfter  string `json:"certificateNotAfter"`
	KeyType              string `json:"keyType"`
}

type apkVerifyReport struct {
	BridgeVersion    string   `json:"bridgeVersion"`
	SourceVersion    string   `json:"sourceVersion"`
	Verified         bool     `json:"verified"`
	V1Verified       bool     `json:"v1Verified"`
	V2Verified       bool     `json:"v2Verified"`
	V3Verified       bool     `json:"v3Verified"`
	V31Verified      bool     `json:"v31Verified"`
	HasV2Block       bool     `json:"hasV2Block"`
	HasV3Block       bool     `json:"hasV3Block"`
	HasV31Block      bool     `json:"hasV31Block"`
	DetectedMinSDK   int      `json:"detectedMinSdk"`
	SignerCertSHA256 []string `json:"signerCertSha256"`
	Errors           []string `json:"errors"`
	Warnings         []string `json:"warnings"`
}

// ApkSigVersion reports the Playmesh bridge version and its pinned
// apksig-go source revision. It is intentionally independent from the Go Core
// protocol version because APK signing is a local host capability.
func ApkSigVersion() string {
	return apkSigBridgeVersion + "+" + apkSigSourceVersion
}

// ApkSignerInfo reads a JKS or PKCS#12 keystore and returns non-secret
// certificate metadata as JSON. Passwords and private-key material are never
// included in the result.
func ApkSignerInfo(keystorePath, storePass, keyPass, alias string) (string, error) {
	data, entry, format, err := loadAPKSigner(keystorePath, storePass, keyPass, alias)
	if err != nil {
		return "", err
	}
	clear(data)

	report := apkSignerInfoReport{
		BridgeVersion:        apkSigBridgeVersion,
		SourceVersion:        apkSigSourceVersion,
		KeystoreFormat:       format.String(),
		RequestedAlias:       alias,
		CertificateSubject:   entry.Cert.Subject.String(),
		CertificateIssuer:    entry.Cert.Issuer.String(),
		CertificateSerial:    entry.Cert.SerialNumber.String(),
		CertificateSHA256:    certificateSHA256(entry.Cert.Raw),
		CertificateNotBefore: entry.Cert.NotBefore.UTC().Format(time.RFC3339),
		CertificateNotAfter:  entry.Cert.NotAfter.UTC().Format(time.RFC3339),
		KeyType:              apkKeyType(entry.PrivateKey),
	}
	return marshalAPKReport(report)
}

// SignApk replaces any existing APK Signing Block with a v2 signature. The
// input must already have its final ZIP layout and native-library alignment;
// this function deliberately does not run zipalign or otherwise rewrite ZIP
// entries. The output path must not already exist and must differ from input.
// A temporary output is verified before it is atomically renamed into place.
func SignApk(inputPath, outputPath, keystorePath, storePass, keyPass, alias string) error {
	input, err := existingRegularFile(inputPath, "input APK")
	if err != nil {
		return err
	}
	output, err := newOutputPath(outputPath)
	if err != nil {
		return err
	}
	if sameAPKPath(input, output) {
		return errors.New("apksig: input and output paths must differ")
	}

	data, entry, _, err := loadAPKSigner(keystorePath, storePass, keyPass, alias)
	if err != nil {
		return err
	}
	clear(data)

	algorithm, err := algo.PickAlgorithm(entry.PrivateKey)
	if err != nil {
		return fmt.Errorf("apksig: choose signing algorithm: %w", err)
	}
	certificates := entry.Chain
	if len(certificates) == 0 {
		certificates = []*x509.Certificate{entry.Cert}
	}
	config := &signer.SignerConfig{
		PrivateKey: entry.PrivateKey,
		Certs:      certificates,
		Algorithms: []algo.Algorithm{algorithm},
	}

	inputFile, err := os.Open(input)
	if err != nil {
		return fmt.Errorf("apksig: open input APK: %w", err)
	}
	defer inputFile.Close()
	inputInfo, err := inputFile.Stat()
	if err != nil {
		return fmt.Errorf("apksig: stat input APK: %w", err)
	}
	if err := rejectV1SignatureEntries(inputFile, inputInfo.Size()); err != nil {
		return err
	}

	temporary, err := os.CreateTemp(filepath.Dir(output), ".playmesh-apksig-*.apk")
	if err != nil {
		return fmt.Errorf("apksig: create temporary output: %w", err)
	}
	temporaryPath := temporary.Name()
	temporaryClosed := false
	defer func() {
		if !temporaryClosed {
			_ = temporary.Close()
		}
		_ = os.Remove(temporaryPath)
	}()

	writer := &apkwriter.SignedAPKWriter{
		Src:     datasource.NewReaderAt(inputFile, inputInfo.Size()),
		Signers: []*signer.SignerConfig{config},
		Align:   false,
	}
	if err := writer.Write(temporary); err != nil {
		return fmt.Errorf("apksig: write v2 signature: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		return fmt.Errorf("apksig: flush temporary output: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("apksig: close temporary output: %w", err)
	}
	temporaryClosed = true

	verification, err := verifyAPKFile(temporaryPath, apkSigVerifyMinSDK, apkSigVerifyMaxSDK)
	if err != nil {
		return fmt.Errorf("apksig: verify signed output: %w", err)
	}
	if !verification.Verified || !verification.V2Verified || len(verification.Errors) != 0 {
		return fmt.Errorf(
			"apksig: signed output failed v2 verification: verified=%t v2=%t errors=%s",
			verification.Verified,
			verification.V2Verified,
			strings.Join(verification.Errors, "; "),
		)
	}
	if err := os.Rename(temporaryPath, output); err != nil {
		return fmt.Errorf("apksig: publish verified output: %w", err)
	}
	return nil
}

// VerifyApk verifies APK signing schemes and returns a JSON report. Zero SDK
// bounds select apksig-go's defaults. A cryptographically invalid APK is
// represented by verified=false rather than an API error.
func VerifyApk(path string, minSDK, maxSDK int) (string, error) {
	if minSDK < 0 || maxSDK < 0 || (minSDK > 0 && maxSDK > 0 && minSDK > maxSDK) {
		return "", errors.New("apksig: invalid SDK verification range")
	}
	resolved, err := existingRegularFile(path, "APK")
	if err != nil {
		return "", err
	}
	result, err := verifyAPKFile(resolved, minSDK, maxSDK)
	if err != nil {
		return "", err
	}

	fingerprints := make([]string, 0, len(result.SignerCerts))
	for _, certificate := range result.SignerCerts {
		fingerprints = append(fingerprints, certificateSHA256(certificate))
	}
	report := apkVerifyReport{
		BridgeVersion:    apkSigBridgeVersion,
		SourceVersion:    apkSigSourceVersion,
		Verified:         result.Verified,
		V1Verified:       result.V1Verified,
		V2Verified:       result.V2Verified,
		V3Verified:       result.V3Verified,
		V31Verified:      result.V31Verified,
		HasV2Block:       result.HasV2Block,
		HasV3Block:       result.HasV3Block,
		HasV31Block:      result.HasV31Block,
		DetectedMinSDK:   result.DetectedMinSdk,
		SignerCertSHA256: fingerprints,
		Errors:           nonNilStrings(result.Errors),
		Warnings:         nonNilStrings(result.Warnings),
	}
	return marshalAPKReport(report)
}

func loadAPKSigner(path, storePass, keyPass, alias string) ([]byte, *keystore.Entry, keystore.Format, error) {
	resolved, err := existingRegularFile(path, "keystore")
	if err != nil {
		return nil, nil, keystore.FormatUnknown, err
	}
	data, err := os.ReadFile(resolved)
	if err != nil {
		return nil, nil, keystore.FormatUnknown, fmt.Errorf("apksig: read keystore: %w", err)
	}
	format := keystore.Detect(data)
	if format == keystore.FormatUnknown {
		clear(data)
		return nil, nil, format, errors.New("apksig: unsupported keystore format; use JKS or PKCS#12")
	}
	entry, err := keystore.Load(data, keystore.LoadOpts{
		StorePass: storePass,
		KeyPass:   keyPass,
		Alias:     alias,
	})
	if err != nil {
		clear(data)
		return nil, nil, format, fmt.Errorf("apksig: load keystore: %w", err)
	}
	if entry.Cert == nil || entry.PrivateKey == nil {
		clear(data)
		return nil, nil, format, errors.New("apksig: keystore entry has no signing key or certificate")
	}
	return data, entry, format, nil
}

func verifyAPKFile(path string, minSDK, maxSDK int) (*apkverifier.Result, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("apksig: open APK for verification: %w", err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("apksig: stat APK for verification: %w", err)
	}
	result, err := apkverifier.Verify(datasource.NewReaderAt(file, info.Size()), minSDK, maxSDK)
	if err != nil {
		return nil, fmt.Errorf("apksig: verify APK: %w", err)
	}
	return result, nil
}

func rejectV1SignatureEntries(file *os.File, size int64) error {
	archive, err := zip.NewReader(file, size)
	if err != nil {
		return fmt.Errorf("apksig: parse input APK ZIP: %w", err)
	}
	for _, entry := range archive.File {
		name := strings.ToUpper(strings.ReplaceAll(entry.Name, "\\", "/"))
		if name == "META-INF/MANIFEST.MF" ||
			(strings.HasPrefix(name, "META-INF/") &&
				(strings.HasSuffix(name, ".SF") ||
					strings.HasSuffix(name, ".RSA") ||
					strings.HasSuffix(name, ".DSA") ||
					strings.HasSuffix(name, ".EC"))) {
			return fmt.Errorf(
				"apksig: input APK contains legacy v1 signature entry %q; remove all v1 META-INF signature files before signing",
				entry.Name,
			)
		}
	}
	return nil
}

func existingRegularFile(path, label string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", fmt.Errorf("apksig: %s path is required", label)
	}
	resolved, err := filepath.Abs(filepath.Clean(path))
	if err != nil {
		return "", fmt.Errorf("apksig: resolve %s path: %w", label, err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", fmt.Errorf("apksig: stat %s: %w", label, err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("apksig: %s is not a regular file", label)
	}
	return resolved, nil
}

func newOutputPath(path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", errors.New("apksig: output APK path is required")
	}
	resolved, err := filepath.Abs(filepath.Clean(path))
	if err != nil {
		return "", fmt.Errorf("apksig: resolve output APK path: %w", err)
	}
	if info, err := os.Stat(resolved); err == nil {
		if info.Mode().IsRegular() {
			return "", fmt.Errorf("apksig: output APK already exists: %w", os.ErrExist)
		}
		return "", errors.New("apksig: output APK path exists and is not a regular file")
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", fmt.Errorf("apksig: stat output APK: %w", err)
	}
	parentInfo, err := os.Stat(filepath.Dir(resolved))
	if err != nil {
		return "", fmt.Errorf("apksig: stat output directory: %w", err)
	}
	if !parentInfo.IsDir() {
		return "", errors.New("apksig: output parent is not a directory")
	}
	return resolved, nil
}

func sameAPKPath(left, right string) bool {
	return left == right || strings.EqualFold(left, right)
}

func certificateSHA256(certificate []byte) string {
	digest := sha256.Sum256(certificate)
	return strings.ToUpper(hex.EncodeToString(digest[:]))
}

func apkKeyType(key any) string {
	switch key.(type) {
	case *rsa.PrivateKey:
		return "RSA"
	case *ecdsa.PrivateKey:
		return "ECDSA"
	default:
		return fmt.Sprintf("%T", key)
	}
}

func nonNilStrings(values []string) []string {
	if values == nil {
		return []string{}
	}
	return values
}

func marshalAPKReport(report any) (string, error) {
	data, err := json.Marshal(report)
	if err != nil {
		return "", fmt.Errorf("apksig: encode report: %w", err)
	}
	return string(data), nil
}
