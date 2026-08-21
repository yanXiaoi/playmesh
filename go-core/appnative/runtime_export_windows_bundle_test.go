package appnative

import (
	"archive/zip"
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"debug/pe"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"go-core/runtimecrypto"

	"github.com/tc-hib/winres"
	winversion "github.com/tc-hib/winres/version"
)

const (
	testEmbeddedWindowsRuntimePublicKeyFingerprint = "10SbA_plmguDhuFby9uK26FJKk1MlcRKTbpH8QQipFo"
	testWindowsRuntimeAESKeyBytes                  = 32
	testWindowsRuntimeNonceBytes                   = 12
)

var (
	testWindowsRuntimeKeyOnce sync.Once
	testWindowsRuntimeKey     *rsa.PrivateKey
	testWindowsRuntimeKeyDER  []byte
	testWindowsRuntimeKeyErr  error
)

func TestEmbeddedWindowsRuntimePublicKey(t *testing.T) {
	parsed, err := x509.ParsePKIXPublicKey(windowsRuntimePublicKeyDER)
	if err != nil {
		t.Fatalf("parse embedded Windows Runtime public key: %v", err)
	}
	publicKey, ok := parsed.(*rsa.PublicKey)
	if !ok {
		t.Fatalf("embedded public key has type %T", parsed)
	}
	if publicKey.N.BitLen() != 3072 || publicKey.E != 65537 {
		t.Fatalf("embedded public key is RSA-%d/%d", publicKey.N.BitLen(), publicKey.E)
	}
	fingerprint, err := windowsRuntimePublicKeyFingerprint(windowsRuntimePublicKeyDER)
	if err != nil {
		t.Fatal(err)
	}
	if fingerprint != testEmbeddedWindowsRuntimePublicKeyFingerprint {
		t.Fatalf("embedded public key fingerprint = %q", fingerprint)
	}
}

func TestExportWindowsRuntimeEncryptsAndReplacesOnlyRuntimePayload(t *testing.T) {
	privateKey, publicKeyDER := testWindowsRuntimeRSAKey(t)
	directory := t.TempDir()
	templatePath := filepath.Join(directory, "fixed.zip")
	gamePath := filepath.Join(directory, "game.zip")
	outputPath := filepath.Join(directory, "export.zip")

	templateEntries := testWindowsTemplateEntries(t, publicKeyDER)
	templateEntries["data/flutter_assets/AssetManifest.bin"] = []byte("asset-manifest")
	templateEntries["data/app.so"] = bytes.Repeat([]byte("app-so-"), 100)
	writeTestZIP(t, templatePath, templateEntries)
	writeTestZIP(t, gamePath, map[string][]byte{
		"main.json":  []byte(`{"playmesh":{"game":{"entry":"index.html"}}}`),
		"index.html": []byte("<html>new game</html>"),
	})

	beforeRaw := rawZIPEntries(t, templatePath)
	reportJSON, err := exportWindowsRuntimeWithEncryptor(
		windowsRuntimeTestRequest(t, templatePath, gamePath, outputPath),
		publicKeyDER,
		testWindowsRuntimeEncryptor(t),
		testWindowsRuntimeExecutablePatcher,
	)
	if err != nil {
		t.Fatalf("exportWindowsRuntimeWithPublicKey: %v", err)
	}

	var report windowsRuntimeExportReport
	if err := json.Unmarshal([]byte(reportJSON), &report); err != nil {
		t.Fatalf("decode report: %v", err)
	}
	fingerprint, err := windowsRuntimePublicKeyFingerprint(publicKeyDER)
	if err != nil {
		t.Fatal(err)
	}
	if report.Kind != "windows-runtime-zip" || report.RuntimePackageCodec != "aes-gcm-v1" {
		t.Fatalf("unexpected report: %+v", report)
	}
	if report.OutputPath != outputPath || report.SizeBytes == 0 || len(report.SHA256) != 64 {
		t.Fatalf("incomplete output report: %+v", report)
	}
	if report.RuntimePublicKeySHA256 != fingerprint || report.PackageKeyID == "" {
		t.Fatalf("incomplete encryption report: %+v", report)
	}

	after := readTestZIP(t, outputPath)
	if _, exists := after[windowsRuntimeExecutableEntry]; exists {
		t.Fatal("template executable name remains in completed ZIP")
	}
	patchedExecutable := after["Runtime Test Game.exe"]
	if len(patchedExecutable) == 0 || !bytes.Contains(patchedExecutable, []byte("Runtime Test Game\x00")) {
		t.Fatal("completed ZIP is missing the renamed customized executable")
	}
	gameBytes, err := os.ReadFile(gamePath)
	if err != nil {
		t.Fatal(err)
	}
	encrypted := after[windowsRuntimeGameEntry]
	if bytes.Equal(encrypted, gameBytes) || len(encrypted) != len(gameBytes)+windowsRuntimeEnvelopeBytes {
		t.Fatalf("game.pmp is not the expected encrypted envelope: clear=%d encrypted=%d", len(gameBytes), len(encrypted))
	}
	if string(encrypted[:4]) != "PME1" {
		t.Fatalf("game.pmp magic = %q", encrypted[:4])
	}

	var config windowsRuntimePackageConfig
	if err := json.Unmarshal(after[windowsRuntimeConfigEntry], &config); err != nil {
		t.Fatalf("decode runtime config: %v", err)
	}
	if config.SchemaVersion != 1 || config.Package.Asset != "assets/runtime/game.pmp" ||
		config.Package.Codec != "aes-gcm-v1" || config.Package.KeyID != report.PackageKeyID {
		t.Fatalf("unexpected runtime config: %+v", config)
	}
	packageKey := unwrapTestWindowsPackageKey(t, privateKey, publicKeyDER, config.Package.KeyID)
	decrypted := decryptTestWindowsPME1WithStandardLibrary(t, encrypted, packageKey)
	clear(packageKey)
	if !bytes.Equal(decrypted, gameBytes) {
		t.Fatal("RSA-unwrapped PME1 payload does not equal the clear game ZIP")
	}
	if report.ClearGameSize != int64(len(gameBytes)) ||
		report.EncryptedGameSize != int64(len(encrypted)) {
		t.Fatalf("incorrect payload sizes in report: %+v", report)
	}

	for name, expected := range templateEntries {
		if name == windowsRuntimeExecutableEntry || name == windowsRuntimeGameEntry || name == windowsRuntimeConfigEntry {
			continue
		}
		if !bytes.Equal(after[name], expected) {
			t.Fatalf("non-replaced entry %q changed", name)
		}
	}
	afterRaw := rawZIPEntries(t, outputPath)
	for name, expected := range beforeRaw {
		if name == windowsRuntimeExecutableEntry || name == windowsRuntimeGameEntry || name == windowsRuntimeConfigEntry {
			continue
		}
		if !bytes.Equal(afterRaw[name], expected) {
			t.Fatalf("compressed bytes for %q were not copied verbatim", name)
		}
	}
}

func TestExportWindowsRuntimeUsesFreshKeyAndNonce(t *testing.T) {
	privateKey, publicKeyDER := testWindowsRuntimeRSAKey(t)
	directory := t.TempDir()
	templatePath := filepath.Join(directory, "fixed.zip")
	gamePath := filepath.Join(directory, "game.zip")
	writeWindowsTemplateZIP(t, templatePath, publicKeyDER)
	writeTestZIP(t, gamePath, map[string][]byte{
		"main.json":  []byte(`{"playmesh":{"game":{"entry":"index.html"}}}`),
		"index.html": bytes.Repeat([]byte("fresh-key-test"), 100),
	})

	type exportResult struct {
		keyID     string
		key       []byte
		encrypted []byte
	}
	results := make([]exportResult, 2)
	for index := range results {
		outputPath := filepath.Join(directory, "export-"+string(rune('a'+index))+".zip")
		if _, err := exportWindowsRuntimeWithEncryptor(
			windowsRuntimeTestRequest(t, templatePath, gamePath, outputPath),
			publicKeyDER,
			testWindowsRuntimeEncryptor(t),
			testWindowsRuntimeExecutablePatcher,
		); err != nil {
			t.Fatalf("export %d: %v", index, err)
		}
		entries := readTestZIP(t, outputPath)
		var config windowsRuntimePackageConfig
		if err := json.Unmarshal(entries[windowsRuntimeConfigEntry], &config); err != nil {
			t.Fatal(err)
		}
		results[index] = exportResult{
			keyID:     config.Package.KeyID,
			key:       unwrapTestWindowsPackageKey(t, privateKey, publicKeyDER, config.Package.KeyID),
			encrypted: entries[windowsRuntimeGameEntry],
		}
	}
	defer clear(results[0].key)
	defer clear(results[1].key)
	if results[0].keyID == results[1].keyID {
		t.Fatal("two exports reused the same wrapped key")
	}
	if bytes.Equal(results[0].key, results[1].key) {
		t.Fatal("two exports reused the same AES key")
	}
	if bytes.Equal(results[0].encrypted[4:4+testWindowsRuntimeNonceBytes], results[1].encrypted[4:4+testWindowsRuntimeNonceBytes]) {
		t.Fatal("two exports reused the same AES-GCM nonce")
	}
	if bytes.Equal(results[0].encrypted, results[1].encrypted) {
		t.Fatal("two exports produced identical encrypted payloads")
	}
}

func TestExportWindowsRuntimeRejectsIncompatibleContractWithoutOutput(t *testing.T) {
	_, publicKeyDER := testWindowsRuntimeRSAKey(t)
	fingerprint, err := windowsRuntimePublicKeyFingerprint(publicKeyDER)
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	gamePath := filepath.Join(directory, "game.zip")
	writeTestZIP(t, gamePath, map[string][]byte{"main.json": []byte("{}")})

	tests := []struct {
		name            string
		includeContract bool
		contract        []byte
	}{
		{name: "missing"},
		{name: "unsupported-scheme", includeContract: true, contract: []byte(`{"schemaVersion":1,"windows":{"packageKeyScheme":"unsupported-v0","publicKeySha256":"` + fingerprint + `"}}`)},
		{name: "wrong-fingerprint", includeContract: true, contract: []byte(`{"schemaVersion":1,"windows":{"packageKeyScheme":"win-rsa-oaep-sha256-v1","publicKeySha256":"wrong"}}`)},
		{name: "unknown-top-field", includeContract: true, contract: []byte(`{"schemaVersion":1,"windows":{"packageKeyScheme":"win-rsa-oaep-sha256-v1","publicKeySha256":"` + fingerprint + `"},"extra":true}`)},
		{name: "unknown-windows-field", includeContract: true, contract: []byte(`{"schemaVersion":1,"windows":{"packageKeyScheme":"win-rsa-oaep-sha256-v1","publicKeySha256":"` + fingerprint + `","extra":true}}`)},
		{name: "trailing-json", includeContract: true, contract: append(testWindowsRuntimeContract(t, publicKeyDER), []byte(" {}")...)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			templatePath := filepath.Join(directory, test.name+"-fixed.zip")
			outputPath := filepath.Join(directory, test.name+"-output.zip")
			entries := testWindowsTemplateEntries(t, publicKeyDER)
			delete(entries, windowsRuntimeContractEntry)
			if test.includeContract {
				entries[windowsRuntimeContractEntry] = test.contract
			}
			writeTestZIP(t, templatePath, entries)
			_, err := exportWindowsRuntimeWithEncryptor(
				windowsRuntimeTestRequest(t, templatePath, gamePath, outputPath),
				publicKeyDER,
				testWindowsRuntimeEncryptor(t),
				testWindowsRuntimeExecutablePatcher,
			)
			if err == nil || !strings.Contains(err.Error(), "must be updated") {
				t.Fatalf("expected Runtime update error, got %v", err)
			}
			if _, err := os.Stat(outputPath); !os.IsNotExist(err) {
				t.Fatalf("failed export left output behind: %v", err)
			}
		})
	}
}

func TestExportWindowsRuntimeRepositoryTemplateSmoke(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping repository Runtime bundle smoke test in short mode")
	}
	templatePath := filepath.Clean(filepath.Join(
		"..", "..", "resources", "runtime", "playmesh-runtime-win.zip",
	))
	if _, err := os.Stat(templatePath); os.IsNotExist(err) {
		t.Skip("repository Windows Runtime template is not present")
	} else if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	gamePath := filepath.Join(directory, "game.zip")
	iconPath := filepath.Join(directory, "icon.png")
	outputPath := filepath.Join(directory, "export.zip")
	writeTestZIP(t, gamePath, map[string][]byte{
		"main.json":  []byte(`{"playmesh":{"game":{"entry":"index.html"}}}`),
		"index.html": []byte("<!doctype html><title>Runtime export smoke</title>"),
	})
	iconPNG := testWindowsRuntimeIconPNG(t)
	if err := os.WriteFile(iconPath, iconPNG, 0o600); err != nil {
		t.Fatal(err)
	}
	reportJSON, err := exportWindowsRuntimeWithEncryptor(
		windowsRuntimeTestRequest(t, templatePath, gamePath, outputPath, iconPath),
		windowsRuntimePublicKeyDER,
		testWindowsRuntimeEncryptor(t),
		customizeWindowsRuntimeExecutable,
	)
	if err != nil {
		t.Fatalf("export repository Windows Runtime template: %v", err)
	}
	var report windowsRuntimeExportReport
	if err := json.Unmarshal([]byte(reportJSON), &report); err != nil {
		t.Fatal(err)
	}
	if report.OutputPath != outputPath || report.SizeBytes <= 0 || len(report.SHA256) != 64 ||
		report.RuntimePackageCodec != "aes-gcm-v1" || report.RuntimePublicKeySHA256 != testEmbeddedWindowsRuntimePublicKeyFingerprint {
		t.Fatalf("incomplete repository export report: %+v", report)
	}
	entries := readTestZIP(t, outputPath)
	if _, exists := entries[windowsRuntimeExecutableEntry]; exists {
		t.Fatal("repository smoke output retained template executable name")
	}
	patchedExecutable := entries["Runtime Test Game.exe"]
	if len(patchedExecutable) == 0 {
		t.Fatal("repository smoke output is missing renamed executable")
	}
	parsedPE, err := pe.NewFile(bytes.NewReader(patchedExecutable))
	if err != nil {
		t.Fatalf("customized executable is not a valid PE image: %v", err)
	}
	if err := parsedPE.Close(); err != nil {
		t.Fatalf("close parsed PE image: %v", err)
	}

	resources, err := winres.LoadFromEXE(bytes.NewReader(patchedExecutable))
	if err != nil {
		t.Fatalf("load customized executable resources: %v", err)
	}
	versionBytes := resources.Get(
		winres.RT_VERSION,
		winres.ID(windowsRuntimeVersionResourceID),
		winres.LCIDDefault,
	)
	versionInfo, err := winversion.FromBytes(versionBytes)
	if err != nil {
		t.Fatalf("parse customized VERSIONINFO: %v", err)
	}
	if versionInfo.FileVersion != [4]uint16{2, 34, 5, 0} ||
		versionInfo.ProductVersion != [4]uint16{2, 34, 5, 0} {
		t.Fatalf(
			"customized fixed versions = file %v, product %v",
			versionInfo.FileVersion,
			versionInfo.ProductVersion,
		)
	}
	versionTable := versionInfo.Table()[winres.LCIDDefault]
	if versionTable == nil {
		t.Fatal("customized VERSIONINFO is missing en-US strings")
	}
	for key, want := range map[string]string{
		winversion.FileDescription:  "Runtime Test Game",
		winversion.InternalName:     "Runtime Test Game",
		winversion.OriginalFilename: "Runtime Test Game.exe",
		winversion.FileVersion:      "2.34.5",
		winversion.ProductVersion:   "2.34.5",
		// ProductName is game-facing metadata. Runtime persistence must derive
		// same-name and rename isolation from gameId, which is covered by the
		// Runtime path tests rather than this PE resource contract.
		winversion.ProductName: "Runtime Test Game",
	} {
		if got := (*versionTable)[key]; got != want {
			t.Errorf("customized VERSIONINFO %s = %q, want %q", key, got, want)
		}
	}

	patchedIcon := windowsRuntimeIconICO(t, resources, "customized executable")
	decodedIcon, err := png.Decode(bytes.NewReader(iconPNG))
	if err != nil {
		t.Fatal(err)
	}
	expectedIcon, err := winres.NewIconFromResizedImage(decodedIcon, nil)
	if err != nil {
		t.Fatalf("build expected icon: %v", err)
	}
	var expectedICO bytes.Buffer
	if err := expectedIcon.SaveICO(&expectedICO); err != nil {
		t.Fatalf("encode expected icon: %v", err)
	}
	if !bytes.Equal(patchedIcon, expectedICO.Bytes()) {
		t.Fatal("customized executable icon group #101 does not match the injected PNG")
	}
	templateEntries := readTestZIP(t, templatePath)
	templateResources, err := winres.LoadFromEXE(
		bytes.NewReader(templateEntries[windowsRuntimeExecutableEntry]),
	)
	if err != nil {
		t.Fatalf("load template executable resources: %v", err)
	}
	if bytes.Equal(
		patchedIcon,
		windowsRuntimeIconICO(t, templateResources, "template executable"),
	) {
		t.Fatal("customized executable retained the template icon")
	}
}

func TestWindowsRuntimeExecutableValidationRejectsUnsafeNamesAndVersions(t *testing.T) {
	for _, name := range []string{
		"",
		" game.exe",
		"game.exe ",
		"folder/game.exe",
		`game?.exe`,
		"CON.exe",
		"CONIN$.exe",
		"com¹.exe",
		"lpt³.txt.exe",
	} {
		if err := validateWindowsRuntimeExecutableName(name); err == nil {
			t.Errorf("unsafe executable name was accepted: %q", name)
		}
	}
	for _, name := range []string{"game.exe", "游戏.exe", "playmesh-runtime.EXE"} {
		if err := validateWindowsRuntimeExecutableName(name); err != nil {
			t.Errorf("safe executable name %q was rejected: %v", name, err)
		}
	}

	for _, version := range []string{
		"",
		"1.2",
		"1.2.3.4",
		"01.2.3",
		"1.-2.3",
		"65536.0.0",
	} {
		if _, err := parseWindowsRuntimeVersion(version); err == nil {
			t.Errorf("invalid Windows version was accepted: %q", version)
		}
	}
	if got, err := parseWindowsRuntimeVersion("65535.65535.65535"); err != nil {
		t.Fatalf("maximum Windows version was rejected: %v", err)
	} else if got != [4]uint16{65535, 65535, 65535, 0} {
		t.Fatalf("maximum Windows version parsed as %v", got)
	}
}

func TestExportWindowsRuntimeRejectsCaseInsensitiveExecutableCollision(t *testing.T) {
	_, publicKeyDER := testWindowsRuntimeRSAKey(t)
	directory := t.TempDir()
	templatePath := filepath.Join(directory, "fixed.zip")
	gamePath := filepath.Join(directory, "game.zip")
	outputPath := filepath.Join(directory, "export.zip")
	writeWindowsTemplateZIP(t, templatePath, publicKeyDER)
	writeTestZIP(t, gamePath, map[string][]byte{"main.json": []byte("{}")})

	request := windowsRuntimeExportRequest{
		TemplateZipPath:      templatePath,
		ClearGamePackagePath: gamePath,
		OutputZipPath:        outputPath,
		ExecutableName:       "PLAYMESH-CORE.EXE",
		Label:                "Runtime Test Game",
		VersionName:          "2.34.5",
	}
	requestJSON, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	_, err = exportWindowsRuntimeWithEncryptor(
		string(requestJSON),
		publicKeyDER,
		testWindowsRuntimeEncryptor(t),
		testWindowsRuntimeExecutablePatcher,
	)
	if err == nil || !strings.Contains(err.Error(), "collides with fixed bundle entry") {
		t.Fatalf("expected case-insensitive executable collision, got %v", err)
	}
	if _, statErr := os.Stat(outputPath); !os.IsNotExist(statErr) {
		t.Fatalf("failed collision export left output behind: %v", statErr)
	}
}

func TestExportWindowsRuntimeRejectsMissingBundleFileWithoutOutput(t *testing.T) {
	_, publicKeyDER := testWindowsRuntimeRSAKey(t)
	directory := t.TempDir()
	templatePath := filepath.Join(directory, "fixed.zip")
	gamePath := filepath.Join(directory, "game.zip")
	outputPath := filepath.Join(directory, "export.zip")
	entries := testWindowsTemplateEntries(t, publicKeyDER)
	delete(entries, "playmesh-core.exe")
	writeTestZIP(t, templatePath, entries)
	writeTestZIP(t, gamePath, map[string][]byte{"main.json": []byte("{}")})

	_, err := exportWindowsRuntimeWithEncryptor(
		windowsRuntimeTestRequest(t, templatePath, gamePath, outputPath),
		publicKeyDER,
		testWindowsRuntimeEncryptor(t),
		testWindowsRuntimeExecutablePatcher,
	)
	if err == nil || !strings.Contains(err.Error(), "playmesh-core.exe") {
		t.Fatalf("expected missing bundle file error, got %v", err)
	}
	if _, err := os.Stat(outputPath); !os.IsNotExist(err) {
		t.Fatalf("failed export left output behind: %v", err)
	}
}

func TestExportWindowsRuntimeRejectsUnsafeOrInvalidGameZIP(t *testing.T) {
	_, publicKeyDER := testWindowsRuntimeRSAKey(t)
	directory := t.TempDir()
	templatePath := filepath.Join(directory, "fixed.zip")
	writeWindowsTemplateZIP(t, templatePath, publicKeyDER)

	for name, entries := range map[string]map[string][]byte{
		"missing-main": {"index.html": []byte("no main")},
		"unsafe-path":  {"main.json": []byte("{}"), "../escape": []byte("bad")},
	} {
		t.Run(name, func(t *testing.T) {
			gamePath := filepath.Join(directory, name+".zip")
			outputPath := filepath.Join(directory, name+"-output.zip")
			writeTestZIP(t, gamePath, entries)
			if _, err := exportWindowsRuntimeWithEncryptor(
				windowsRuntimeTestRequest(t, templatePath, gamePath, outputPath),
				publicKeyDER,
				testWindowsRuntimeEncryptor(t),
				testWindowsRuntimeExecutablePatcher,
			); err == nil {
				t.Fatal("invalid clear game ZIP should fail")
			}
			if _, err := os.Stat(outputPath); !os.IsNotExist(err) {
				t.Fatalf("failed export left output behind: %v", err)
			}
		})
	}
}

func TestExportWindowsRuntimeNeverOverwritesOutput(t *testing.T) {
	_, publicKeyDER := testWindowsRuntimeRSAKey(t)
	directory := t.TempDir()
	templatePath := filepath.Join(directory, "fixed.zip")
	gamePath := filepath.Join(directory, "game.zip")
	outputPath := filepath.Join(directory, "export.zip")
	writeWindowsTemplateZIP(t, templatePath, publicKeyDER)
	writeTestZIP(t, gamePath, map[string][]byte{"main.json": []byte("{}")})
	if err := os.WriteFile(outputPath, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := exportWindowsRuntimeWithEncryptor(
		windowsRuntimeTestRequest(t, templatePath, gamePath, outputPath),
		publicKeyDER,
		testWindowsRuntimeEncryptor(t),
		testWindowsRuntimeExecutablePatcher,
	); err == nil {
		t.Fatal("existing output should be rejected")
	}
	data, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "keep" {
		t.Fatal("existing output was modified")
	}
}

func TestDecodeWindowsRuntimeExportRequestRejectsUnknownAndTrailingJSON(t *testing.T) {
	for _, request := range []string{
		`{"templateZipPath":"a","clearGamePackagePath":"b","outputZipPath":"c","extra":true}`,
		`{"templateZipPath":"a","clearGamePackagePath":"b","outputZipPath":"c"} {}`,
	} {
		if _, err := decodeWindowsRuntimeExportRequest(request); err == nil {
			t.Fatalf("request should fail: %s", request)
		}
	}
}

func testWindowsRuntimeRSAKey(t *testing.T) (*rsa.PrivateKey, []byte) {
	t.Helper()
	testWindowsRuntimeKeyOnce.Do(func() {
		testWindowsRuntimeKey, testWindowsRuntimeKeyErr = rsa.GenerateKey(rand.Reader, 3072)
		if testWindowsRuntimeKeyErr != nil {
			return
		}
		testWindowsRuntimeKeyDER, testWindowsRuntimeKeyErr = x509.MarshalPKIXPublicKey(&testWindowsRuntimeKey.PublicKey)
	})
	if testWindowsRuntimeKeyErr != nil {
		t.Fatalf("generate test Windows Runtime RSA key: %v", testWindowsRuntimeKeyErr)
	}
	return testWindowsRuntimeKey, bytes.Clone(testWindowsRuntimeKeyDER)
}

func testWindowsRuntimeEncryptor(t *testing.T) windowsRuntimePackageEncryptor {
	t.Helper()
	return func(
		cleartext []byte,
		publicKeyDER []byte,
		scheme string,
		label string,
	) (*runtimecrypto.EncryptResult, error) {
		if scheme != windowsRuntimePackageScheme || label != windowsRuntimeOAEPLabel {
			return nil, fmt.Errorf("unexpected Windows Runtime crypto contract %q/%q", scheme, label)
		}
		parsed, err := x509.ParsePKIXPublicKey(publicKeyDER)
		if err != nil {
			return nil, err
		}
		publicKey, ok := parsed.(*rsa.PublicKey)
		if !ok {
			return nil, fmt.Errorf("test public key has type %T", parsed)
		}
		packageKey := make([]byte, testWindowsRuntimeAESKeyBytes)
		defer clear(packageKey)
		nonce := make([]byte, testWindowsRuntimeNonceBytes)
		defer clear(nonce)
		if _, err := io.ReadFull(rand.Reader, packageKey); err != nil {
			return nil, err
		}
		if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
			return nil, err
		}
		block, err := aes.NewCipher(packageKey)
		if err != nil {
			return nil, err
		}
		gcm, err := cipher.NewGCM(block)
		if err != nil {
			return nil, err
		}
		envelope := append([]byte("PME1"), nonce...)
		envelope = gcm.Seal(envelope, nonce, cleartext, nil)
		wrappedKey, err := rsa.EncryptOAEP(
			sha256.New(),
			rand.Reader,
			publicKey,
			packageKey,
			[]byte(label),
		)
		if err != nil {
			clear(envelope)
			return nil, err
		}
		defer clear(wrappedKey)
		fingerprint, err := windowsRuntimePublicKeyFingerprint(publicKeyDER)
		if err != nil {
			clear(envelope)
			return nil, err
		}
		return &runtimecrypto.EncryptResult{
			Envelope:        envelope,
			KeyID:           scheme + ":" + fingerprint + ":" + base64.RawURLEncoding.EncodeToString(wrappedKey),
			Scheme:          scheme,
			Codec:           runtimecrypto.CodecAESGCMV1,
			PublicKeySHA256: fingerprint,
		}, nil
	}
}

func testWindowsRuntimeContract(t *testing.T, publicKeyDER []byte) []byte {
	t.Helper()
	fingerprint, err := windowsRuntimePublicKeyFingerprint(publicKeyDER)
	if err != nil {
		t.Fatal(err)
	}
	contract := windowsRuntimeContract{SchemaVersion: 1}
	contract.Windows.PackageKeyScheme = windowsRuntimePackageScheme
	contract.Windows.PublicKeySHA256 = fingerprint
	data, err := json.Marshal(contract)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func testWindowsTemplateEntries(t *testing.T, publicKeyDER []byte) map[string][]byte {
	t.Helper()
	entries := map[string][]byte{
		windowsRuntimeGameEntry:     []byte("old-game"),
		windowsRuntimeConfigEntry:   []byte("old-config"),
		windowsRuntimeContractEntry: testWindowsRuntimeContract(t, publicKeyDER),
	}
	for _, required := range windowsRuntimeRequiredEntries {
		entries[required] = []byte("required-" + required)
	}
	return entries
}

func writeWindowsTemplateZIP(t *testing.T, destination string, publicKeyDER []byte) {
	t.Helper()
	writeTestZIP(t, destination, testWindowsTemplateEntries(t, publicKeyDER))
}

func windowsRuntimeTestRequest(
	t *testing.T,
	templatePath string,
	gamePath string,
	outputPath string,
	iconPath ...string,
) string {
	t.Helper()
	requestValue := windowsRuntimeExportRequest{
		TemplateZipPath:      templatePath,
		ClearGamePackagePath: gamePath,
		OutputZipPath:        outputPath,
		ExecutableName:       "Runtime Test Game.exe",
		Label:                "Runtime Test Game",
		VersionName:          "2.34.5",
	}
	if len(iconPath) > 1 {
		t.Fatal("windowsRuntimeTestRequest accepts at most one icon path")
	}
	if len(iconPath) == 1 {
		requestValue.IconPath = iconPath[0]
	}
	request, err := json.Marshal(requestValue)
	if err != nil {
		t.Fatal(err)
	}
	return string(request)
}

func testWindowsRuntimeExecutablePatcher(
	executable []byte,
	executableName string,
	label string,
	versionName string,
	iconPNG []byte,
) ([]byte, error) {
	result := append([]byte("patched-executable\x00"), executable...)
	result = append(result, executableName...)
	result = append(result, 0)
	result = append(result, label...)
	result = append(result, 0)
	result = append(result, versionName...)
	result = append(result, iconPNG...)
	return result, nil
}

func unwrapTestWindowsPackageKey(
	t *testing.T,
	privateKey *rsa.PrivateKey,
	publicKeyDER []byte,
	keyID string,
) []byte {
	t.Helper()
	parts := strings.Split(keyID, ":")
	if len(parts) != 3 || parts[0] != windowsRuntimePackageScheme {
		t.Fatalf("invalid Windows package keyId format: %q", keyID)
	}
	digest := sha256.Sum256(publicKeyDER)
	expectedFingerprint := base64.RawURLEncoding.EncodeToString(digest[:])
	if parts[1] != expectedFingerprint {
		t.Fatalf("keyId fingerprint = %q, want %q", parts[1], expectedFingerprint)
	}
	wrapped, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatalf("decode wrapped key: %v", err)
	}
	if len(wrapped) != privateKey.Size() || len(wrapped) != 384 {
		t.Fatalf("wrapped key length = %d", len(wrapped))
	}
	key, err := rsa.DecryptOAEP(
		sha256.New(),
		rand.Reader,
		privateKey,
		wrapped,
		[]byte(windowsRuntimeOAEPLabel),
	)
	if err != nil {
		t.Fatalf("unwrap package key: %v", err)
	}
	if len(key) != testWindowsRuntimeAESKeyBytes {
		t.Fatalf("unwrapped AES key length = %d", len(key))
	}
	return key
}

func decryptTestWindowsPME1WithStandardLibrary(t *testing.T, encrypted, key []byte) []byte {
	t.Helper()
	if len(encrypted) < windowsRuntimeEnvelopeBytes || string(encrypted[:4]) != "PME1" {
		t.Fatal("invalid PME1 envelope")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	decrypted, err := gcm.Open(nil, encrypted[4:4+testWindowsRuntimeNonceBytes], encrypted[4+testWindowsRuntimeNonceBytes:], nil)
	if err != nil {
		t.Fatalf("standard library rejected PME1 AES-GCM: %v", err)
	}
	return decrypted
}

func writeTestZIP(t *testing.T, destination string, entries map[string][]byte) {
	t.Helper()
	file, err := os.Create(destination)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	for name, data := range entries {
		header := &zip.FileHeader{Name: name, Method: zip.Deflate}
		entry, err := writer.CreateHeader(header)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
}

func readTestZIP(t *testing.T, source string) map[string][]byte {
	t.Helper()
	archive, err := zip.OpenReader(source)
	if err != nil {
		t.Fatal(err)
	}
	defer archive.Close()
	entries := make(map[string][]byte, len(archive.File))
	for _, entry := range archive.File {
		reader, err := entry.Open()
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(reader)
		_ = reader.Close()
		if err != nil {
			t.Fatal(err)
		}
		entries[entry.Name] = data
	}
	return entries
}

func testWindowsRuntimeIconPNG(t *testing.T) []byte {
	t.Helper()
	icon := image.NewNRGBA(image.Rect(0, 0, 48, 32))
	for y := 0; y < icon.Bounds().Dy(); y++ {
		for x := 0; x < icon.Bounds().Dx(); x++ {
			icon.SetNRGBA(x, y, color.NRGBA{
				R: uint8(20 + x*4),
				G: uint8(30 + y*6),
				B: uint8(220 - (x+y)%80),
				A: uint8(128 + (x*3+y*5)%128),
			})
		}
	}
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, icon); err != nil {
		t.Fatalf("encode test icon PNG: %v", err)
	}
	return encoded.Bytes()
}

func windowsRuntimeIconICO(
	t *testing.T,
	resources *winres.ResourceSet,
	context string,
) []byte {
	t.Helper()
	icon, err := resources.GetIconTranslation(
		winres.ID(windowsRuntimeIconResourceID),
		winres.LCIDDefault,
	)
	if err != nil {
		t.Fatalf("read %s icon group #101: %v", context, err)
	}
	var encoded bytes.Buffer
	if err := icon.SaveICO(&encoded); err != nil {
		t.Fatalf("encode %s icon group #101: %v", context, err)
	}
	return encoded.Bytes()
}

func rawZIPEntries(t *testing.T, source string) map[string][]byte {
	t.Helper()
	archive, err := zip.OpenReader(source)
	if err != nil {
		t.Fatal(err)
	}
	defer archive.Close()
	entries := make(map[string][]byte, len(archive.File))
	for _, entry := range archive.File {
		reader, err := entry.OpenRaw()
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(reader)
		if err != nil {
			t.Fatal(err)
		}
		entries[entry.Name] = data
	}
	return entries
}
