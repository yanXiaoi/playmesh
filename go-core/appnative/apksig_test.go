package appnative

import (
	"archive/zip"
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	pkcs12 "software.sslmate.com/src/go-pkcs12"
)

const testKeystorePassword = "playmesh-test-password"

func TestApkSigVersionPinsBridgeAndSource(t *testing.T) {
	version := ApkSigVersion()
	if !strings.Contains(version, apkSigBridgeVersion) || !strings.Contains(version, "a0389a9d7f83") {
		t.Fatalf("ApkSigVersion() = %q", version)
	}
}

func TestApkSignerInfoSignAndVerifyV2WithoutAlignmentRewrite(t *testing.T) {
	directory := t.TempDir()
	keystorePath, certificate := writeTestPKCS12(t, directory)
	inputPath := filepath.Join(directory, "input.apk")
	outputPath := filepath.Join(directory, "output.apk")
	unsignedAPK := makeTestUnsignedAPK(t)
	if err := os.WriteFile(inputPath, unsignedAPK, 0o600); err != nil {
		t.Fatalf("write input APK: %v", err)
	}

	infoJSON, err := ApkSignerInfo(keystorePath, testKeystorePassword, "", "")
	if err != nil {
		t.Fatalf("ApkSignerInfo() error = %v", err)
	}
	var info apkSignerInfoReport
	if err := json.Unmarshal([]byte(infoJSON), &info); err != nil {
		t.Fatalf("decode signer info: %v", err)
	}
	if info.BridgeVersion != apkSigBridgeVersion || info.SourceVersion != apkSigSourceVersion {
		t.Fatalf("unexpected signer versions: %#v", info)
	}
	if info.KeystoreFormat != "PKCS12" || info.KeyType != "RSA" {
		t.Fatalf("unexpected signer metadata: %#v", info)
	}
	if info.CertificateSHA256 != certificateSHA256(certificate.Raw) {
		t.Fatalf("certificate SHA-256 = %q, want %q", info.CertificateSHA256, certificateSHA256(certificate.Raw))
	}

	if err := SignApk(
		inputPath,
		outputPath,
		keystorePath,
		testKeystorePassword,
		"",
		"",
	); err != nil {
		t.Fatalf("SignApk() error = %v", err)
	}
	signedAPK, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("read signed APK: %v", err)
	}
	centralDirectoryOffset := bytes.Index(unsignedAPK, []byte{'P', 'K', 0x01, 0x02})
	if centralDirectoryOffset < 0 {
		t.Fatal("test APK central directory was not found")
	}
	if !bytes.Equal(signedAPK[:centralDirectoryOffset], unsignedAPK[:centralDirectoryOffset]) {
		t.Fatal("SignApk rewrote ZIP entries even though alignment is disabled")
	}

	reportJSON, err := VerifyApk(outputPath, 24, 35)
	if err != nil {
		t.Fatalf("VerifyApk() error = %v", err)
	}
	var report apkVerifyReport
	if err := json.Unmarshal([]byte(reportJSON), &report); err != nil {
		t.Fatalf("decode verification report: %v", err)
	}
	if !report.Verified || !report.V2Verified {
		t.Fatalf("signed APK did not verify: %#v", report)
	}
	if report.V1Verified || report.V3Verified || report.V31Verified {
		t.Fatalf("SignApk must emit v2 only: %#v", report)
	}
	if len(report.SignerCertSHA256) != 1 || report.SignerCertSHA256[0] != info.CertificateSHA256 {
		t.Fatalf("verification signer fingerprints = %#v", report.SignerCertSHA256)
	}
	if len(report.Errors) != 0 {
		t.Fatalf("verification errors = %#v", report.Errors)
	}
}

func TestSignApkDoesNotOverwriteExistingOutput(t *testing.T) {
	directory := t.TempDir()
	keystorePath, _ := writeTestPKCS12(t, directory)
	inputPath := filepath.Join(directory, "input.apk")
	outputPath := filepath.Join(directory, "existing.apk")
	if err := os.WriteFile(inputPath, makeTestUnsignedAPK(t), 0o600); err != nil {
		t.Fatal(err)
	}
	original := []byte("keep-existing-output")
	if err := os.WriteFile(outputPath, original, 0o600); err != nil {
		t.Fatal(err)
	}

	err := SignApk(inputPath, outputPath, keystorePath, testKeystorePassword, "", "")
	if err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("SignApk() error = %v, want existing-output rejection", err)
	}
	actual, readErr := os.ReadFile(outputPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !bytes.Equal(actual, original) {
		t.Fatalf("existing output changed to %q", actual)
	}
}

func TestSignApkRejectsLegacyV1SignatureEntries(t *testing.T) {
	directory := t.TempDir()
	keystorePath, _ := writeTestPKCS12(t, directory)
	inputPath := filepath.Join(directory, "v1.apk")
	outputPath := filepath.Join(directory, "output.apk")
	input := makeTestAPKWithExtraEntry(t, "META-INF/OLD.SF", []byte("stale-v1-signature"))
	if err := os.WriteFile(inputPath, input, 0o600); err != nil {
		t.Fatal(err)
	}

	err := SignApk(inputPath, outputPath, keystorePath, testKeystorePassword, "", "")
	if err == nil || !strings.Contains(err.Error(), "legacy v1 signature entry") {
		t.Fatalf("SignApk() error = %v, want v1-entry rejection", err)
	}
	if _, statErr := os.Stat(outputPath); !os.IsNotExist(statErr) {
		t.Fatalf("output should not exist after v1 rejection, stat error = %v", statErr)
	}
}

func TestVerifyApkReportsTamperingWithoutAPIFailure(t *testing.T) {
	directory := t.TempDir()
	keystorePath, _ := writeTestPKCS12(t, directory)
	inputPath := filepath.Join(directory, "input.apk")
	outputPath := filepath.Join(directory, "output.apk")
	if err := os.WriteFile(inputPath, makeTestUnsignedAPK(t), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := SignApk(inputPath, outputPath, keystorePath, testKeystorePassword, "", ""); err != nil {
		t.Fatal(err)
	}

	signed, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	signed[48] ^= 0xff
	if err := os.WriteFile(outputPath, signed, 0o600); err != nil {
		t.Fatal(err)
	}
	reportJSON, err := VerifyApk(outputPath, 24, 35)
	if err != nil {
		t.Fatalf("VerifyApk() returned an operational error for tampering: %v", err)
	}
	var report apkVerifyReport
	if err := json.Unmarshal([]byte(reportJSON), &report); err != nil {
		t.Fatal(err)
	}
	if report.Verified || report.V2Verified || len(report.Errors) == 0 {
		t.Fatalf("tampered APK report = %#v", report)
	}
}

func TestVerifyApkRejectsInvalidSDKRange(t *testing.T) {
	if _, err := VerifyApk("unused.apk", 35, 24); err == nil || !strings.Contains(err.Error(), "SDK") {
		t.Fatalf("VerifyApk() error = %v", err)
	}
}

func makeTestUnsignedAPK(t *testing.T) []byte {
	return makeTestAPKWithExtraEntry(t, "", nil)
}

func makeTestAPKWithExtraEntry(t *testing.T, extraName string, extraData []byte) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	entries := []struct {
		name string
		data []byte
	}{
		{name: "AndroidManifest.xml", data: []byte("<manifest/>")},
		{name: "classes.dex", data: bytes.Repeat([]byte{0x42}, 4096)},
		{name: "assets/runtime/game.pmp", data: bytes.Repeat([]byte{0x24}, 1024)},
	}
	if extraName != "" {
		entries = append(entries, struct {
			name string
			data []byte
		}{name: extraName, data: extraData})
	}
	for _, entry := range entries {
		file, err := writer.Create(entry.name)
		if err != nil {
			t.Fatalf("create APK entry %s: %v", entry.name, err)
		}
		if _, err := file.Write(entry.data); err != nil {
			t.Fatalf("write APK entry %s: %v", entry.name, err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close test APK: %v", err)
	}
	return buffer.Bytes()
}

func writeTestPKCS12(t *testing.T, directory string) (string, *x509.Certificate) {
	t.Helper()
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	now := time.Now().UTC()
	template := &x509.Certificate{
		SerialNumber: big.NewInt(20260820),
		Subject: pkix.Name{
			CommonName:   "Playmesh APK signing test",
			Organization: []string{"Playmesh"},
		},
		NotBefore: now.Add(-time.Hour),
		NotAfter:  now.Add(24 * time.Hour),
		KeyUsage:  x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &privateKey.PublicKey, privateKey)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parse certificate: %v", err)
	}
	store, err := pkcs12.Encode(rand.Reader, privateKey, certificate, nil, testKeystorePassword)
	if err != nil {
		t.Fatalf("encode PKCS#12: %v", err)
	}
	path := filepath.Join(directory, "signing.p12")
	if err := os.WriteFile(path, store, 0o600); err != nil {
		t.Fatalf("write PKCS#12: %v", err)
	}
	return path, certificate
}
