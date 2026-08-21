package appnative

import (
	"archive/zip"
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"go-core/runtimecrypto"
)

const testRuntimeTemplatePackage = "top.zfjmm.playmesh.runtime"

func TestExportAndroidRuntimeEndToEnd(t *testing.T) {
	directory := t.TempDir()
	keystorePath, certificate := writeTestPKCS12(t, directory)
	templatePath := filepath.Join(directory, "runtime-template.apk")
	gamePath := filepath.Join(directory, "game.zip")
	iconPath := filepath.Join(directory, "icon.png")
	outputPath := filepath.Join(directory, "exported.apk")
	publicKeyFingerprint, err := androidRuntimePublicKeyFingerprint(androidRuntimePublicKeyDER)
	if err != nil {
		t.Fatal(err)
	}

	manifest := makeTestRuntimeManifest(t)
	makeTestRuntimeTemplateAPK(t, templatePath, manifest, publicKeyFingerprint)
	clearGame := makeTestRuntimeGameZIP(t)
	if err := os.WriteFile(gamePath, clearGame, 0o600); err != nil {
		t.Fatal(err)
	}
	icon := []byte{
		0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
		0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
		0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
		0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
		0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41,
		0x54, 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
		0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99,
		0x3d, 0x1d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
		0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
	}
	if err := os.WriteFile(iconPath, icon, 0o600); err != nil {
		t.Fatal(err)
	}

	gameID := "com.playmesh.game-3b1p45k3a1"
	applicationID := mustRuntimeApplicationID(t, gameID)
	request := androidRuntimeExportRequest{
		TemplateAPKPath:      templatePath,
		ClearGamePackagePath: gamePath,
		OutputAPKPath:        outputPath,
		KeystorePath:         keystorePath,
		StorePassword:        testKeystorePassword,
		GameID:               gameID,
		ApplicationID:        applicationID,
		Label:                "一个比底包名称长得多的测试游戏",
		VersionName:          "2026.08.20-runtime-export-test",
		VersionCode:          20260820,
		IconPath:             iconPath,
	}
	requestJSON, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}

	fakeEncrypted := append([]byte("PME1"), bytes.Repeat([]byte{0x42}, 12)...)
	fakeEncrypted = append(fakeEncrypted, clearGame...)
	fakeEncrypted = append(fakeEncrypted, bytes.Repeat([]byte{0x24}, 16)...)
	wrapper := bytes.Repeat([]byte{0x5a}, 3072/8)
	fakeKeyID := androidRuntimePackageScheme + ":" + publicKeyFingerprint + ":" +
		base64.RawURLEncoding.EncodeToString(wrapper)
	reportJSON, err := exportAndroidRuntimeWithEncryptor(
		string(requestJSON),
		androidRuntimePublicKeyDER,
		func(clear, publicDER []byte, scheme, label string) (*runtimecrypto.EncryptResult, error) {
			if !bytes.Equal(clear, clearGame) || !bytes.Equal(publicDER, androidRuntimePublicKeyDER) ||
				scheme != androidRuntimePackageScheme || label != androidRuntimeOAEPLabel {
				t.Fatal("Android exporter passed the wrong contract to the private crypto provider")
			}
			return &runtimecrypto.EncryptResult{
				Envelope:        append([]byte(nil), fakeEncrypted...),
				KeyID:           fakeKeyID,
				Scheme:          androidRuntimePackageScheme,
				Codec:           runtimecrypto.CodecAESGCMV1,
				PublicKeySHA256: publicKeyFingerprint,
			}, nil
		},
	)
	if err != nil {
		t.Fatalf("ExportAndroidRuntime() error = %v", err)
	}
	var report androidRuntimeExportReport
	if err := json.Unmarshal([]byte(reportJSON), &report); err != nil {
		t.Fatalf("decode report: %v", err)
	}
	if report.OutputPath != outputPath || report.ApplicationID != applicationID {
		t.Fatalf("unexpected export report: %#v", report)
	}
	if report.SizeBytes <= 0 || len(report.SHA256) != 64 {
		t.Fatalf("missing artifact metadata: %#v", report)
	}
	if report.CertificateSHA256 != certificateSHA256(certificate.Raw) {
		t.Fatalf("certificate SHA-256 = %q", report.CertificateSHA256)
	}
	if report.RuntimePublicKeySHA256 != publicKeyFingerprint ||
		report.PackageKeyID != fakeKeyID {
		t.Fatalf("Runtime encryption report = %#v", report)
	}
	if !report.Signature.Verified || !report.Signature.V2Verified {
		t.Fatalf("signature report = %#v", report.Signature)
	}

	templateOffsets, err := nativeLibraryOffsets(templatePath)
	if err != nil {
		t.Fatal(err)
	}
	outputOffsets, err := nativeLibraryOffsets(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := verifyNativeOffsets(templateOffsets, outputOffsets); err != nil {
		t.Fatalf("native offsets changed: %v", err)
	}

	outputManifest, err := readAPKEntry(outputPath, runtimeManifestEntry)
	if err != nil {
		t.Fatal(err)
	}
	assertTestRuntimeManifest(t, outputManifest, report.ApplicationID, request.Label, request.VersionName, uint32(request.VersionCode))

	encrypted, err := readAPKEntry(outputPath, runtimeGameEntry)
	if err != nil {
		t.Fatal(err)
	}
	configData, err := readAPKEntry(outputPath, runtimeConfigEntry)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(encrypted, fakeEncrypted) {
		t.Fatal("private crypto provider envelope was not injected verbatim")
	}
	var config runtimePackageConfig
	if err := json.Unmarshal(configData, &config); err != nil {
		t.Fatal(err)
	}
	if config.Package.Codec != runtimecrypto.CodecAESGCMV1 ||
		config.Package.KeyID != fakeKeyID {
		t.Fatalf("Runtime package config = %#v", config)
	}
	for _, name := range runtimeDefaultIconEntries {
		actual, err := readAPKEntry(outputPath, name)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(actual, icon) {
			t.Fatalf("icon entry %s was not replaced", name)
		}
	}
	reader, err := zip.OpenReader(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	for _, file := range reader.File {
		if isRuntimeV1SignatureEntry(file.Name) {
			t.Fatalf("legacy v1 entry survived export: %s", file.Name)
		}
	}
}

func TestAndroidRuntimeTemplateContractRejectsWrongKey(t *testing.T) {
	directory := t.TempDir()
	templatePath := filepath.Join(directory, "wrong-key-template.apk")
	makeTestRuntimeTemplateAPK(
		t,
		templatePath,
		makeTestRuntimeManifest(t),
		strings.Repeat("A", 43),
	)
	actualFingerprint, err := androidRuntimePublicKeyFingerprint(
		androidRuntimePublicKeyDER,
	)
	if err != nil {
		t.Fatal(err)
	}
	err = validateAndroidRuntimeTemplateContract(
		templatePath,
		actualFingerprint,
	)
	if err == nil || !strings.Contains(err.Error(), "publicKeySha256") {
		t.Fatalf("wrong Android Runtime key contract error = %v", err)
	}
}

func TestAndroidRuntimeEncryptionResultRejectsOldOrMalformedKeyIDs(t *testing.T) {
	fingerprint := strings.Repeat("A", 43)
	valid := &runtimecrypto.EncryptResult{
		Envelope:        append([]byte("PME1"), bytes.Repeat([]byte{1}, 29)...),
		KeyID:           androidRuntimePackageScheme + ":" + fingerprint + ":" + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, 384)),
		Scheme:          androidRuntimePackageScheme,
		Codec:           runtimecrypto.CodecAESGCMV1,
		PublicKeySHA256: fingerprint,
	}
	if err := validateAndroidRuntimeEncryptionResult(valid, fingerprint, 1); err != nil {
		t.Fatalf("valid provider result rejected: %v", err)
	}
	for name, keyID := range map[string]string{
		"old-certificate-derived": "legacy-certificate-derived:anything",
		"wrong-platform":          "win-rsa-oaep-sha256-v1:" + fingerprint + ":" + strings.Repeat("A", 512),
		"extra-segment":           valid.KeyID + ":extra",
	} {
		t.Run(name, func(t *testing.T) {
			candidate := *valid
			candidate.KeyID = keyID
			if err := validateAndroidRuntimeEncryptionResult(&candidate, fingerprint, 1); err == nil {
				t.Fatal("malformed Android provider keyId was accepted")
			}
		})
	}
}

func TestExportAndroidRuntimeRepositoryTemplatesSmoke(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping large repository Runtime template smoke tests in short mode")
	}
	publicKeyFingerprint, err := androidRuntimePublicKeyFingerprint(androidRuntimePublicKeyDER)
	if err != nil {
		t.Fatal(err)
	}
	for _, target := range []struct {
		name     string
		fileName string
	}{
		{name: "arm64-v8a", fileName: "playmesh-runtime-arm.apk"},
		{name: "x86_64", fileName: "playmesh-runtime-x86.apk"},
	} {
		t.Run(target.name, func(t *testing.T) {
			templatePath := filepath.Clean(filepath.Join(
				"..", "..", "runtime", "resource", "v1.0.0-build2", target.fileName,
			))
			if _, err := os.Stat(templatePath); errors.Is(err, os.ErrNotExist) {
				t.Skipf("repository %s Runtime template is not present", target.name)
			} else if err != nil {
				t.Fatal(err)
			}
			if err := validateAndroidRuntimeTemplateContract(
				templatePath,
				publicKeyFingerprint,
			); err != nil {
				t.Fatalf("repository %s Runtime contract: %v", target.name, err)
			}
			templateOffsets, err := nativeLibraryOffsets(templatePath)
			if err != nil {
				t.Fatal(err)
			}
			if len(templateOffsets) == 0 {
				t.Fatal("repository Runtime template contains no native libraries")
			}
		})
	}
}

func TestExportAndroidRuntimeRejectsNonDeterministicApplicationID(t *testing.T) {
	request := `{
		"templateApkPath":"template.apk",
		"clearGamePackagePath":"game.zip",
		"outputApkPath":"output.apk",
		"keystorePath":"key.p12",
		"storePassword":"secret",
		"keyPassword":"",
		"keyAlias":"",
		"gameId":"game-one",
		"applicationId":"com.example.some.other.game",
		"label":"Game",
		"versionName":"1.0.0",
		"versionCode":1
	}`
	_, err := ExportAndroidRuntime(request)
	if err == nil || !strings.Contains(err.Error(), "deterministic value") {
		t.Fatalf("ExportAndroidRuntime() error = %v", err)
	}
}

func TestRuntimeApplicationIDFormattingAndKnownCollision(t *testing.T) {
	tests := map[string]string{
		"com.playmesh.game-3b1p45k3a1": "com.playmesh.game3b1p45k3a1",
		" single-game ":                "playmesh.singlegame",
		"9studio._game":                "g9studio.g_game",
		"com...example.游戏":             "com.example",
	}
	for gameID, expected := range tests {
		actual, err := runtimeApplicationID(gameID)
		if err != nil {
			t.Fatalf("runtimeApplicationID(%q): %v", gameID, err)
		}
		if actual != expected {
			t.Fatalf("runtimeApplicationID(%q) = %q, want %q", gameID, actual, expected)
		}
	}

	left, err := runtimeApplicationID("com.example.game-a")
	if err != nil {
		t.Fatal(err)
	}
	right, err := runtimeApplicationID("com.example.gamea")
	if err != nil {
		t.Fatal(err)
	}
	if left != right {
		t.Fatalf("known sanitizer collision changed: %q != %q", left, right)
	}
	if _, err := runtimeApplicationID("---"); err == nil {
		t.Fatal("gameId without usable ASCII characters should fail")
	}
	if _, err := runtimeApplicationID(strings.Repeat("a", 256) + ".b"); err == nil ||
		!strings.Contains(err.Error(), "255") {
		t.Fatalf("overlong formatted applicationId error = %v", err)
	}
}

func TestRewriteRuntimeManifestSupportsLongerUTF8Strings(t *testing.T) {
	manifest := makeTestRuntimeManifest(t)
	applicationID := mustRuntimeApplicationID(t, "manifest-unit-test")
	label := strings.Repeat("玩家游戏", 20)
	version := strings.Repeat("v123", 20)
	rewritten, err := rewriteRuntimeManifest(manifest, applicationID, label, version, 123456)
	if err != nil {
		t.Fatalf("rewriteRuntimeManifest() error = %v", err)
	}
	if len(rewritten) <= len(manifest) {
		t.Fatalf("rewritten manifest length = %d, want greater than %d", len(rewritten), len(manifest))
	}
	assertTestRuntimeManifest(t, rewritten, applicationID, label, version, 123456)
}

func TestReadAndValidateRuntimeGameZIPRejectsTraversal(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "unsafe.zip")
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for name, data := range map[string][]byte{
		"main.json":  []byte(`{"entry":"index.html"}`),
		"../evil.js": []byte("bad"),
	} {
		entry, err := writer.Create(name)
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
	if err := os.WriteFile(path, buffer.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readAndValidateRuntimeGameZIP(path); err == nil || !strings.Contains(err.Error(), "unsafe path") {
		t.Fatalf("readAndValidateRuntimeGameZIP() error = %v", err)
	}
}

func makeTestRuntimeGameZIP(t *testing.T) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for _, entry := range []struct {
		name string
		data []byte
	}{
		{name: "main.json", data: []byte(`{"entry":"index.html","name":"Test"}`)},
		{name: "index.html", data: []byte("<!doctype html><script src=\"game.js\"></script>")},
		{name: "game.js", data: []byte("console.log('encrypted runtime game')")},
	} {
		file, err := writer.Create(entry.name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := file.Write(entry.data); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func makeTestRuntimeTemplateAPK(
	t *testing.T,
	path string,
	manifest []byte,
	androidPublicKeyFingerprint string,
) {
	t.Helper()
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	counter := &byteCountingWriter{writer: file}
	writer := zip.NewWriter(counter)
	write := func(name string, method uint16, data []byte, extra []byte) {
		header := zip.FileHeader{Name: name, Method: method, Extra: extra}
		header.SetMode(0o644)
		if err := writeRuntimeReplacement(writer, header, data); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	write(runtimeManifestEntry, zip.Deflate, manifest, nil)
	write("classes.dex", zip.Deflate, bytes.Repeat([]byte{0x64}, 2048), nil)
	for _, name := range []string{"lib/arm64-v8a/libapp.so", "lib/arm64-v8a/libflutter.so"} {
		// Creating the next entry closes and flushes the previous one. Add a
		// zero-sized raw entry boundary first so counter.count is current.
		boundary := "assets/test-boundary-" + strings.ReplaceAll(filepath.Base(name), ".", "-")
		write(boundary, zip.Store, nil, nil)
		if err := writer.Flush(); err != nil {
			t.Fatal(err)
		}
		base := counter.count + 30 + int64(len(name))
		padding := int((runtimeNativeAlign - base%runtimeNativeAlign) % runtimeNativeAlign)
		write(name, zip.Store, bytes.Repeat([]byte{0x7f}, 8192), runtimeAlignmentExtra(padding))
	}
	write(runtimeGameEntry, zip.Deflate, []byte("placeholder-game"), nil)
	write(runtimeConfigEntry, zip.Deflate, []byte(`{"schemaVersion":1,"package":{"asset":"assets/runtime/game.pmp","codec":"plain-zip"}}`), nil)
	contract := fmt.Sprintf(
		`{"schemaVersion":1,"android":{"packageKeyScheme":%q,"publicKeySha256":%q},"windows":{"packageKeyScheme":"win-rsa-oaep-sha256-v1","publicKeySha256":%q}}`,
		androidRuntimePackageScheme,
		androidPublicKeyFingerprint,
		strings.Repeat("A", 43),
	)
	write(runtimeContractEntry, zip.Deflate, []byte(contract), nil)
	for _, name := range runtimeDefaultIconEntries {
		write(name, zip.Store, []byte("placeholder-icon"), nil)
	}
	write("META-INF/OLD.SF", zip.Store, []byte("stale-v1"), nil)
	write("META-INF/OLD.RSA", zip.Store, []byte("stale-v1"), nil)
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	offsets, err := nativeLibraryOffsets(path)
	if err != nil {
		t.Fatal(err)
	}
	for name, offset := range offsets {
		if offset%runtimeNativeAlign != 0 {
			t.Fatalf("test template %s offset %d is not aligned", name, offset)
		}
	}
}

type testAXMLAttribute struct {
	name   uint32
	raw    uint32
	typeID byte
	value  uint32
}

func makeTestRuntimeManifest(t *testing.T) []byte {
	t.Helper()
	stringsTable := []string{
		"manifest", "package", testRuntimeTemplatePackage,
		"versionName", "1", "versionCode",
		"uses-sdk", "minSdkVersion",
		"application", "label", "R",
		"provider", "authorities", testRuntimeTemplatePackage + ".fileProvider",
		"permission", testRuntimeTemplatePackage + ".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION",
		"uses-permission", "name",
	}
	index := make(map[string]uint32, len(stringsTable))
	for position, value := range stringsTable {
		index[value] = uint32(position)
	}
	pool := makeTestAXMLStringPool(t, stringsTable)
	resourceMap := makeTestAXMLResourceMap(len(stringsTable), index["minSdkVersion"])
	chunks := [][]byte{
		makeTestAXMLStart(index["manifest"], []testAXMLAttribute{
			{name: index["package"], raw: index[testRuntimeTemplatePackage], typeID: androidTypeString, value: index[testRuntimeTemplatePackage]},
			{name: index["versionName"], raw: index["1"], typeID: androidTypeString, value: index["1"]},
			{name: index["versionCode"], raw: androidNoString, typeID: androidTypeIntDec, value: 1},
		}),
		makeTestAXMLStart(index["uses-sdk"], []testAXMLAttribute{
			{name: index["minSdkVersion"], raw: androidNoString, typeID: androidTypeIntDec, value: 24},
		}),
		makeTestAXMLEnd(index["uses-sdk"]),
		makeTestAXMLStart(index["application"], []testAXMLAttribute{
			{name: index["label"], raw: index["R"], typeID: androidTypeString, value: index["R"]},
		}),
		makeTestAXMLStart(index["provider"], []testAXMLAttribute{
			{name: index["authorities"], raw: index[testRuntimeTemplatePackage+".fileProvider"], typeID: androidTypeString, value: index[testRuntimeTemplatePackage+".fileProvider"]},
			{name: index["permission"], raw: index[testRuntimeTemplatePackage+".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"], typeID: androidTypeString, value: index[testRuntimeTemplatePackage+".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"]},
		}),
		makeTestAXMLEnd(index["provider"]),
		makeTestAXMLStart(index["permission"], []testAXMLAttribute{
			{name: index["name"], raw: index[testRuntimeTemplatePackage+".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"], typeID: androidTypeString, value: index[testRuntimeTemplatePackage+".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"]},
		}),
		makeTestAXMLEnd(index["permission"]),
		makeTestAXMLStart(index["uses-permission"], []testAXMLAttribute{
			{name: index["name"], raw: index[testRuntimeTemplatePackage+".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"], typeID: androidTypeString, value: index[testRuntimeTemplatePackage+".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"]},
		}),
		makeTestAXMLEnd(index["uses-permission"]),
		makeTestAXMLEnd(index["application"]),
		makeTestAXMLEnd(index["manifest"]),
	}
	size := 8 + len(pool) + len(resourceMap)
	for _, chunk := range chunks {
		size += len(chunk)
	}
	result := make([]byte, 8, size)
	binary.LittleEndian.PutUint16(result[0:2], androidXMLType)
	binary.LittleEndian.PutUint16(result[2:4], 8)
	result = append(result, pool...)
	result = append(result, resourceMap...)
	for _, chunk := range chunks {
		result = append(result, chunk...)
	}
	binary.LittleEndian.PutUint32(result[4:8], uint32(len(result)))
	return result
}

func makeTestAXMLResourceMap(stringCount int, minSDKNameIndex uint32) []byte {
	chunk := make([]byte, 8+stringCount*4)
	binary.LittleEndian.PutUint16(chunk[0:2], 0x0180)
	binary.LittleEndian.PutUint16(chunk[2:4], 8)
	binary.LittleEndian.PutUint32(chunk[4:8], uint32(len(chunk)))
	binary.LittleEndian.PutUint32(chunk[8+int(minSDKNameIndex)*4:], 0x0101020c)
	return chunk
}

func makeTestAXMLStringPool(t *testing.T, values []string) []byte {
	t.Helper()
	headerSize := 28
	stringsStart := headerSize + len(values)*4
	chunk := make([]byte, stringsStart)
	binary.LittleEndian.PutUint16(chunk[0:2], androidStringPool)
	binary.LittleEndian.PutUint16(chunk[2:4], uint16(headerSize))
	binary.LittleEndian.PutUint32(chunk[8:12], uint32(len(values)))
	binary.LittleEndian.PutUint32(chunk[16:20], androidUTF8Flag)
	binary.LittleEndian.PutUint32(chunk[20:24], uint32(stringsStart))
	for index, value := range values {
		binary.LittleEndian.PutUint32(chunk[headerSize+index*4:], uint32(len(chunk)-stringsStart))
		encoded, err := encodeRuntimePoolString(value, true)
		if err != nil {
			t.Fatal(err)
		}
		chunk = append(chunk, encoded...)
	}
	for len(chunk)%4 != 0 {
		chunk = append(chunk, 0)
	}
	binary.LittleEndian.PutUint32(chunk[4:8], uint32(len(chunk)))
	return chunk
}

func makeTestAXMLStart(element uint32, attributes []testAXMLAttribute) []byte {
	chunk := make([]byte, 36+len(attributes)*20)
	binary.LittleEndian.PutUint16(chunk[0:2], androidStartElement)
	binary.LittleEndian.PutUint16(chunk[2:4], 16)
	binary.LittleEndian.PutUint32(chunk[4:8], uint32(len(chunk)))
	binary.LittleEndian.PutUint32(chunk[12:16], androidNoString)
	binary.LittleEndian.PutUint32(chunk[16:20], androidNoString)
	binary.LittleEndian.PutUint32(chunk[20:24], element)
	binary.LittleEndian.PutUint16(chunk[24:26], 20)
	binary.LittleEndian.PutUint16(chunk[26:28], 20)
	binary.LittleEndian.PutUint16(chunk[28:30], uint16(len(attributes)))
	for index, attribute := range attributes {
		offset := 36 + index*20
		binary.LittleEndian.PutUint32(chunk[offset:offset+4], androidNoString)
		binary.LittleEndian.PutUint32(chunk[offset+4:offset+8], attribute.name)
		binary.LittleEndian.PutUint32(chunk[offset+8:offset+12], attribute.raw)
		binary.LittleEndian.PutUint16(chunk[offset+12:offset+14], 8)
		chunk[offset+15] = attribute.typeID
		binary.LittleEndian.PutUint32(chunk[offset+16:offset+20], attribute.value)
	}
	return chunk
}

func makeTestAXMLEnd(element uint32) []byte {
	chunk := make([]byte, 24)
	binary.LittleEndian.PutUint16(chunk[0:2], 0x0103)
	binary.LittleEndian.PutUint16(chunk[2:4], 16)
	binary.LittleEndian.PutUint32(chunk[4:8], uint32(len(chunk)))
	binary.LittleEndian.PutUint32(chunk[12:16], androidNoString)
	binary.LittleEndian.PutUint32(chunk[16:20], androidNoString)
	binary.LittleEndian.PutUint32(chunk[20:24], element)
	return chunk
}

func assertTestRuntimeManifest(t *testing.T, data []byte, applicationID, label, version string, versionCode uint32) {
	t.Helper()
	pool, err := parseRuntimeStringPool(data)
	if err != nil {
		t.Fatal(err)
	}
	attributes, err := parseRuntimeAXMLAttributes(data, pool)
	if err != nil {
		t.Fatal(err)
	}
	assertString := func(element, name, expected string) {
		attribute, err := findRuntimeAttribute(attributes, element, name)
		if err != nil {
			t.Fatal(err)
		}
		actual, _, err := runtimeStringAttribute(pool, attribute)
		if err != nil {
			t.Fatal(err)
		}
		if actual != expected {
			t.Fatalf("%s.%s = %q, want %q", element, name, actual, expected)
		}
	}
	assertString("manifest", "package", applicationID)
	assertString("manifest", "versionName", version)
	assertString("application", "label", label)
	assertString("provider", "authorities", applicationID+".fileProvider")
	assertString("provider", "permission", applicationID+".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION")
	assertString("permission", "name", applicationID+".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION")
	assertString("uses-permission", "name", applicationID+".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION")
	attribute, err := findRuntimeAttribute(attributes, "manifest", "versionCode")
	if err != nil {
		t.Fatal(err)
	}
	if attribute.value != versionCode {
		t.Fatalf("manifest.versionCode = %d, want %d", attribute.value, versionCode)
	}
}

func mustRuntimeApplicationID(t *testing.T, gameID string) string {
	t.Helper()
	applicationID, err := runtimeApplicationID(gameID)
	if err != nil {
		t.Fatalf("runtimeApplicationID(%q): %v", gameID, err)
	}
	return applicationID
}

func verifyWithOfficialAndroidTools(t *testing.T, apkPath string) {
	t.Helper()
	zipalign := findAndroidBuildTool(t, "zipalign")
	apksigner := findAndroidBuildTool(t, "apksigner")
	if zipalign == "" || apksigner == "" {
		t.Log("Android SDK zipalign/apksigner not found; skipping official cross-check")
		return
	}
	if output, err := runAndroidBuildTool(
		zipalign,
		"-c", "-P", "16", "-v", "4", apkPath,
	); err != nil {
		t.Fatalf("official zipalign check failed: %v\n%s", err, output)
	}
	if output, err := runAndroidBuildTool(
		apksigner,
		"verify", "--verbose", "--print-certs", apkPath,
	); err != nil {
		t.Fatalf("official apksigner check failed: %v\n%s", err, output)
	}
}

func findAndroidBuildTool(t *testing.T, name string) string {
	t.Helper()
	for _, candidate := range []string{name, name + ".exe", name + ".bat"} {
		if resolved, err := exec.LookPath(candidate); err == nil {
			return resolved
		}
	}
	roots := []string{os.Getenv("ANDROID_SDK_ROOT"), os.Getenv("ANDROID_HOME")}
	propertiesPath := filepath.Clean(filepath.Join("..", "..", "android", "local.properties"))
	if data, err := os.ReadFile(propertiesPath); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if !strings.HasPrefix(line, "sdk.dir=") {
				continue
			}
			value := strings.TrimSpace(strings.TrimPrefix(line, "sdk.dir="))
			roots = append(roots, strings.ReplaceAll(value, `\\`, `\`))
		}
	}
	var matches []string
	for _, root := range roots {
		if root == "" {
			continue
		}
		for _, candidate := range []string{name, name + ".exe", name + ".bat"} {
			found, err := filepath.Glob(filepath.Join(root, "build-tools", "*", candidate))
			if err == nil {
				matches = append(matches, found...)
			}
		}
	}
	sort.Strings(matches)
	for index := len(matches) - 1; index >= 0; index-- {
		if info, err := os.Stat(matches[index]); err == nil && info.Mode().IsRegular() {
			return matches[index]
		}
	}
	return ""
}

func runAndroidBuildTool(tool string, arguments ...string) ([]byte, error) {
	if strings.EqualFold(filepath.Ext(tool), ".bat") {
		arguments = append([]string{"/d", "/c", tool}, arguments...)
		return exec.Command("cmd.exe", arguments...).CombinedOutput()
	}
	return exec.Command(tool, arguments...).CombinedOutput()
}

func readTestZipEntry(t *testing.T, path, name string) []byte {
	t.Helper()
	reader, err := zip.OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	for _, file := range reader.File {
		if file.Name != name {
			continue
		}
		input, err := file.Open()
		if err != nil {
			t.Fatal(err)
		}
		defer input.Close()
		data, err := io.ReadAll(input)
		if err != nil {
			t.Fatal(err)
		}
		return data
	}
	t.Fatalf("missing ZIP entry %s", name)
	return nil
}
