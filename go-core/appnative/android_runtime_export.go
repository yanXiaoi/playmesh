package appnative

import (
	"archive/zip"
	"bytes"
	"compress/flate"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc32"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf16"
	"unicode/utf8"

	"go-core/runtimecrypto"

	_ "embed"
)

const (
	runtimeManifestEntry = "AndroidManifest.xml"
	runtimeGameEntry     = "assets/flutter_assets/assets/runtime/game.pmp"
	runtimeConfigEntry   = "assets/flutter_assets/assets/runtime/runtime-config.json"
	runtimeContractEntry = "assets/flutter_assets/assets/runtime/runtime-contract.json"
	runtimeMaxGameZIP    = 512 << 20
	runtimeMaxIconPNG    = 16 << 20
	runtimeNativeAlign   = int64(16 << 10)

	androidRuntimePackageScheme = runtimecrypto.AndroidScheme
	androidRuntimeOAEPLabel     = runtimecrypto.AndroidOAEPLabel
	androidRuntimeContractMax   = 4 << 10

	androidXMLType      = 0x0003
	androidStringPool   = 0x0001
	androidStartElement = 0x0102
	androidUTF8Flag     = 0x00000100
	androidSortedFlag   = 0x00000001
	androidNoString     = 0xffffffff
	androidTypeString   = 0x03
	androidTypeIntDec   = 0x10
	androidTypeIntHex   = 0x11
)

// androidRuntimePublicKeyDER deliberately contains only the public key. The
// independent matching private key is compiled solely into Android Runtime.
//
//go:embed android_runtime_public_key.der
var androidRuntimePublicKeyDER []byte

type androidRuntimePackageEncryptor func(
	clear []byte,
	publicKeyDER []byte,
	scheme string,
	label string,
) (*runtimecrypto.EncryptResult, error)

var runtimeDefaultIconEntries = []string{
	"res/9w.png",
	"res/yn.png",
	"res/FS.png",
	"res/RJ.png",
	"res/o-.png",
}

type androidRuntimeExportRequest struct {
	TemplateAPKPath      string `json:"templateApkPath"`
	ClearGamePackagePath string `json:"clearGamePackagePath"`
	OutputAPKPath        string `json:"outputApkPath"`
	KeystorePath         string `json:"keystorePath"`
	StorePassword        string `json:"storePassword"`
	KeyPassword          string `json:"keyPassword,omitempty"`
	KeyAlias             string `json:"keyAlias,omitempty"`
	GameID               string `json:"gameId"`
	ApplicationID        string `json:"applicationId,omitempty"`
	Label                string `json:"label"`
	VersionName          string `json:"versionName"`
	VersionCode          int64  `json:"versionCode"`
	IconPath             string `json:"iconPath,omitempty"`
}

type androidRuntimeExportReport struct {
	OutputPath             string           `json:"outputPath"`
	ApplicationID          string           `json:"applicationId"`
	GameID                 string           `json:"gameId"`
	VersionName            string           `json:"versionName"`
	VersionCode            int64            `json:"versionCode"`
	CertificateSHA256      string           `json:"certificateSha256"`
	RuntimePublicKeySHA256 string           `json:"runtimePublicKeySha256"`
	PackageKeyID           string           `json:"packageKeyId"`
	SizeBytes              int64            `json:"sizeBytes"`
	SHA256                 string           `json:"sha256"`
	NativeLibraryOffset    map[string]int64 `json:"nativeLibraryOffsets"`
	Signature              apkVerifyReport  `json:"signature"`
}

type androidRuntimeContract struct {
	SchemaVersion int `json:"schemaVersion"`
	Android       struct {
		PackageKeyScheme string `json:"packageKeyScheme"`
		PublicKeySHA256  string `json:"publicKeySha256"`
	} `json:"android"`
	Windows struct {
		PackageKeyScheme string `json:"packageKeyScheme"`
		PublicKeySHA256  string `json:"publicKeySha256"`
	} `json:"windows"`
}

type runtimePackageConfig struct {
	SchemaVersion int `json:"schemaVersion"`
	Package       struct {
		Asset string `json:"asset"`
		Codec string `json:"codec"`
		KeyID string `json:"keyId"`
	} `json:"package"`
}

// ExportAndroidRuntime creates a signed Android game from a fixed Runtime APK.
// The request and result are JSON so the same API can be bound by gomobile and
// called by the Windows helper process. The output path must not exist.
func ExportAndroidRuntime(requestJSON string) (string, error) {
	return exportAndroidRuntimeWithEncryptor(
		requestJSON,
		androidRuntimePublicKeyDER,
		runtimecrypto.EncryptPME1,
	)
}

func exportAndroidRuntimeWithEncryptor(
	requestJSON string,
	publicKeyDER []byte,
	encryptPackage androidRuntimePackageEncryptor,
) (string, error) {
	publicKeyFingerprint, err := androidRuntimePublicKeyFingerprint(publicKeyDER)
	if err != nil {
		return "", err
	}
	if encryptPackage == nil {
		return "", errors.New("android export: private Runtime crypto provider is unavailable")
	}
	request, err := decodeAndroidRuntimeExportRequest(requestJSON)
	if err != nil {
		return "", err
	}

	templatePath, err := existingRegularFile(request.TemplateAPKPath, "Runtime template APK")
	if err != nil {
		return "", exportAndroidError(err)
	}
	gamePath, err := existingRegularFile(request.ClearGamePackagePath, "clear Runtime game ZIP")
	if err != nil {
		return "", exportAndroidError(err)
	}
	keystorePath, err := existingRegularFile(request.KeystorePath, "keystore")
	if err != nil {
		return "", exportAndroidError(err)
	}
	outputPath, err := newOutputPath(request.OutputAPKPath)
	if err != nil {
		return "", exportAndroidError(err)
	}
	for label, input := range map[string]string{
		"template APK": templatePath,
		"game ZIP":     gamePath,
		"keystore":     keystorePath,
	} {
		if sameAPKPath(input, outputPath) {
			return "", fmt.Errorf("android export: output APK must differ from %s", label)
		}
	}

	var iconBytes []byte
	if request.IconPath != "" {
		iconPath, resolveErr := existingRegularFile(request.IconPath, "icon PNG")
		if resolveErr != nil {
			return "", exportAndroidError(resolveErr)
		}
		if sameAPKPath(iconPath, outputPath) {
			return "", errors.New("android export: output APK must differ from icon PNG")
		}
		iconBytes, err = readLimitedFile(iconPath, runtimeMaxIconPNG, "icon PNG")
		if err != nil {
			return "", err
		}
		if _, err := png.DecodeConfig(bytes.NewReader(iconBytes)); err != nil {
			return "", fmt.Errorf("android export: invalid icon PNG: %w", err)
		}
	}

	clearGame, err := readAndValidateRuntimeGameZIP(gamePath)
	if err != nil {
		return "", err
	}
	defer clear(clearGame)

	keyStoreData, signerEntry, _, err := loadAPKSigner(
		keystorePath,
		request.StorePassword,
		request.KeyPassword,
		request.KeyAlias,
	)
	if err != nil {
		return "", exportAndroidError(err)
	}
	clear(keyStoreData)
	certificateDigest := sha256.Sum256(signerEntry.Cert.Raw)

	templateOffsets, err := nativeLibraryOffsets(templatePath)
	if err != nil {
		return "", fmt.Errorf("android export: inspect template native libraries: %w", err)
	}
	if len(templateOffsets) == 0 {
		return "", errors.New("android export: Runtime template contains no native libraries")
	}
	if err := verifyNativeOffsets(templateOffsets, templateOffsets); err != nil {
		return "", fmt.Errorf("android export: invalid Runtime template: %w", err)
	}
	if err := validateAndroidRuntimeTemplateContract(
		templatePath,
		publicKeyFingerprint,
	); err != nil {
		return "", err
	}
	encryption, err := encryptPackage(
		clearGame,
		publicKeyDER,
		androidRuntimePackageScheme,
		androidRuntimeOAEPLabel,
	)
	if err != nil {
		return "", fmt.Errorf("android export: encrypt Runtime game package: %w", err)
	}
	if err := validateAndroidRuntimeEncryptionResult(
		encryption,
		publicKeyFingerprint,
		len(clearGame),
	); err != nil {
		return "", err
	}
	encryptedGame := encryption.Envelope
	packageKeyID := encryption.KeyID
	defer clear(encryptedGame)
	runtimeConfig, err := encodeRuntimePackageConfig(packageKeyID)
	if err != nil {
		return "", err
	}

	manifest, err := readAPKEntry(templatePath, runtimeManifestEntry)
	if err != nil {
		return "", fmt.Errorf("android export: read binary AndroidManifest.xml: %w", err)
	}
	applicationID, err := runtimeApplicationID(request.GameID)
	if err != nil {
		return "", err
	}
	if request.ApplicationID != "" && request.ApplicationID != applicationID {
		return "", fmt.Errorf(
			"android export: applicationId must be empty or the deterministic value %q for gameId",
			applicationID,
		)
	}
	manifest, err = rewriteRuntimeManifest(
		manifest,
		applicationID,
		request.Label,
		request.VersionName,
		uint32(request.VersionCode),
	)
	if err != nil {
		return "", fmt.Errorf("android export: patch binary AndroidManifest.xml: %w", err)
	}

	replacements := map[string][]byte{
		runtimeManifestEntry: manifest,
		runtimeGameEntry:     encryptedGame,
		runtimeConfigEntry:   runtimeConfig,
	}
	if iconBytes != nil {
		for _, entry := range runtimeDefaultIconEntries {
			name, validateErr := validateAPKEntryName(entry)
			if validateErr != nil {
				return "", fmt.Errorf("android export: invalid icon entry: %w", validateErr)
			}
			if _, reserved := replacements[name]; reserved {
				return "", fmt.Errorf("android export: icon entry %q collides with a Runtime payload", name)
			}
			replacements[name] = iconBytes
		}
	}

	unsignedPath, err := reserveTemporaryAPK(filepath.Dir(outputPath), ".playmesh-export-unsigned-*.apk")
	if err != nil {
		return "", err
	}
	signedPath, err := reserveTemporaryAPK(filepath.Dir(outputPath), ".playmesh-export-signed-*.apk")
	if err != nil {
		return "", err
	}
	defer os.Remove(unsignedPath)
	defer os.Remove(signedPath)

	if err := rewriteRuntimeAPK(templatePath, unsignedPath, replacements, templateOffsets); err != nil {
		return "", fmt.Errorf("android export: rewrite fixed Runtime APK: %w", err)
	}
	unsignedOffsets, err := nativeLibraryOffsets(unsignedPath)
	if err != nil {
		return "", fmt.Errorf("android export: inspect unsigned native libraries: %w", err)
	}
	if err := verifyNativeOffsets(templateOffsets, unsignedOffsets); err != nil {
		return "", fmt.Errorf("android export: unsigned APK native alignment changed: %w", err)
	}

	if err := SignApk(
		unsignedPath,
		signedPath,
		keystorePath,
		request.StorePassword,
		request.KeyPassword,
		request.KeyAlias,
	); err != nil {
		return "", fmt.Errorf("android export: sign APK: %w", err)
	}
	signedOffsets, err := nativeLibraryOffsets(signedPath)
	if err != nil {
		return "", fmt.Errorf("android export: inspect signed native libraries: %w", err)
	}
	if err := verifyNativeOffsets(templateOffsets, signedOffsets); err != nil {
		return "", fmt.Errorf("android export: signed APK native alignment changed: %w", err)
	}

	verification, err := verifyAPKFile(signedPath, apkSigVerifyMinSDK, apkSigVerifyMaxSDK)
	if err != nil {
		return "", fmt.Errorf("android export: verify signed APK: %w", err)
	}
	if !verification.Verified || !verification.V2Verified || len(verification.Errors) != 0 {
		return "", errors.New("android export: final APK failed v2 signature verification")
	}
	if len(verification.SignerCerts) != 1 || !bytes.Equal(verification.SignerCerts[0], signerEntry.Cert.Raw) {
		return "", errors.New("android export: final APK signer differs from the configured signing certificate")
	}

	if err := os.Rename(signedPath, outputPath); err != nil {
		return "", fmt.Errorf("android export: publish completed APK: %w", err)
	}
	outputInfo, err := os.Stat(outputPath)
	if err != nil {
		_ = os.Remove(outputPath)
		return "", fmt.Errorf("android export: stat completed APK: %w", err)
	}
	outputDigest, err := fileSHA256(outputPath)
	if err != nil {
		_ = os.Remove(outputPath)
		return "", err
	}

	report := androidRuntimeExportReport{
		OutputPath:             outputPath,
		ApplicationID:          applicationID,
		GameID:                 request.GameID,
		VersionName:            request.VersionName,
		VersionCode:            request.VersionCode,
		CertificateSHA256:      strings.ToUpper(hex.EncodeToString(certificateDigest[:])),
		RuntimePublicKeySHA256: publicKeyFingerprint,
		PackageKeyID:           packageKeyID,
		SizeBytes:              outputInfo.Size(),
		SHA256:                 outputDigest,
		NativeLibraryOffset:    signedOffsets,
		Signature: apkVerifyReport{
			BridgeVersion:    apkSigBridgeVersion,
			SourceVersion:    apkSigSourceVersion,
			Verified:         verification.Verified,
			V1Verified:       verification.V1Verified,
			V2Verified:       verification.V2Verified,
			V3Verified:       verification.V3Verified,
			V31Verified:      verification.V31Verified,
			HasV2Block:       verification.HasV2Block,
			HasV3Block:       verification.HasV3Block,
			HasV31Block:      verification.HasV31Block,
			DetectedMinSDK:   verification.DetectedMinSdk,
			SignerCertSHA256: []string{strings.ToUpper(hex.EncodeToString(certificateDigest[:]))},
			Errors:           nonNilStrings(verification.Errors),
			Warnings:         nonNilStrings(verification.Warnings),
		},
	}
	encoded, err := json.Marshal(report)
	if err != nil {
		_ = os.Remove(outputPath)
		return "", fmt.Errorf("android export: encode result: %w", err)
	}
	return string(encoded), nil
}

func decodeAndroidRuntimeExportRequest(value string) (androidRuntimeExportRequest, error) {
	var request androidRuntimeExportRequest
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return request, fmt.Errorf("android export: decode request JSON: %w", err)
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return request, err
	}
	request.GameID = strings.TrimSpace(request.GameID)
	request.Label = strings.TrimSpace(request.Label)
	request.VersionName = strings.TrimSpace(request.VersionName)
	request.TemplateAPKPath = strings.TrimSpace(request.TemplateAPKPath)
	request.ClearGamePackagePath = strings.TrimSpace(request.ClearGamePackagePath)
	request.IconPath = strings.TrimSpace(request.IconPath)
	request.OutputAPKPath = strings.TrimSpace(request.OutputAPKPath)
	request.KeystorePath = strings.TrimSpace(request.KeystorePath)
	request.KeyAlias = strings.TrimSpace(request.KeyAlias)
	request.ApplicationID = strings.TrimSpace(request.ApplicationID)
	for field, candidate := range map[string]string{
		"templateApkPath":      request.TemplateAPKPath,
		"clearGamePackagePath": request.ClearGamePackagePath,
		"gameId":               request.GameID,
		"label":                request.Label,
		"versionName":          request.VersionName,
		"outputApkPath":        request.OutputAPKPath,
		"keystorePath":         request.KeystorePath,
	} {
		if candidate == "" {
			return request, fmt.Errorf("android export: %s is required", field)
		}
	}
	if request.VersionCode < 1 || request.VersionCode > 2100000000 {
		return request, errors.New("android export: versionCode must be between 1 and 2100000000")
	}
	if err := validateExportText("gameId", request.GameID, 512); err != nil {
		return request, err
	}
	if err := validateExportText("label", request.Label, 128); err != nil {
		return request, err
	}
	if err := validateExportText("versionName", request.VersionName, 128); err != nil {
		return request, err
	}
	if request.ApplicationID != "" && !validAndroidApplicationID(request.ApplicationID) {
		return request, fmt.Errorf("android export: applicationId %q is invalid", request.ApplicationID)
	}
	expectedApplicationID, err := runtimeApplicationID(request.GameID)
	if err != nil {
		return request, err
	}
	if request.ApplicationID != "" && request.ApplicationID != expectedApplicationID {
		return request, fmt.Errorf(
			"android export: applicationId must be empty or the deterministic value %q for gameId",
			expectedApplicationID,
		)
	}
	return request, nil
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("android export: request JSON contains multiple values")
		}
		return fmt.Errorf("android export: decode trailing request JSON: %w", err)
	}
	return nil
}

func validateExportText(field, value string, maxRunes int) error {
	if !utf8.ValidString(value) {
		return fmt.Errorf("android export: %s is not valid UTF-8", field)
	}
	if utf8.RuneCountInString(value) > maxRunes {
		return fmt.Errorf("android export: %s exceeds %d characters", field, maxRunes)
	}
	for _, character := range value {
		if character == 0 || character == '\r' || character == '\n' || character < 0x20 {
			return fmt.Errorf("android export: %s contains a control character", field)
		}
	}
	return nil
}

// runtimeApplicationID implements the public, readable gameId-to-package rule.
// Removing unsupported characters is intentionally lossy: distinct game IDs
// such as "com.example.game-a" and "com.example.gamea" collide. Callers must
// prevent those collisions at the game-ID allocation layer; this formatter
// must stay stable so an exported game can update an earlier installation.
func runtimeApplicationID(gameID string) (string, error) {
	segments := make([]string, 0, strings.Count(gameID, ".")+1)
	for _, rawSegment := range strings.Split(strings.TrimSpace(gameID), ".") {
		var sanitized strings.Builder
		sanitized.Grow(len(rawSegment))
		for index := 0; index < len(rawSegment); index++ {
			character := rawSegment[index]
			if isASCIIApplicationIDLetter(character) ||
				(character >= '0' && character <= '9') || character == '_' {
				sanitized.WriteByte(character)
			}
		}
		segment := sanitized.String()
		if segment == "" {
			continue
		}
		if !isASCIIApplicationIDLetter(segment[0]) {
			segment = "g" + segment
		}
		segments = append(segments, segment)
	}
	if len(segments) == 0 {
		return "", errors.New("android export: gameId contains no usable applicationId characters")
	}
	if len(segments) < 2 {
		segments = append([]string{"playmesh"}, segments...)
	}
	applicationID := strings.Join(segments, ".")
	if len(applicationID) > 255 {
		return "", errors.New("android export: formatted applicationId exceeds 255 ASCII characters")
	}
	if !validAndroidApplicationID(applicationID) {
		return "", fmt.Errorf("android export: formatted applicationId %q is invalid", applicationID)
	}
	return applicationID, nil
}

func isASCIIApplicationIDLetter(character byte) bool {
	return (character >= 'a' && character <= 'z') ||
		(character >= 'A' && character <= 'Z')
}

func readAndValidateRuntimeGameZIP(path string) ([]byte, error) {
	data, err := readLimitedFile(path, runtimeMaxGameZIP, "clear Runtime game ZIP")
	if err != nil {
		return nil, err
	}
	archive, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		clear(data)
		return nil, fmt.Errorf("android export: parse clear Runtime game ZIP: %w", err)
	}
	if len(archive.File) == 0 || len(archive.File) > 20000 {
		clear(data)
		return nil, errors.New("android export: clear Runtime game ZIP has an invalid file count")
	}
	seen := make(map[string]struct{}, len(archive.File))
	var total uint64
	hasManifest := false
	for _, file := range archive.File {
		name, validateErr := validateRuntimeZIPName(file.Name)
		if validateErr != nil {
			clear(data)
			return nil, fmt.Errorf("android export: invalid game ZIP entry: %w", validateErr)
		}
		if _, duplicate := seen[name]; duplicate {
			clear(data)
			return nil, fmt.Errorf("android export: duplicate game ZIP entry %q", name)
		}
		seen[name] = struct{}{}
		if file.Mode()&os.ModeSymlink != 0 {
			clear(data)
			return nil, fmt.Errorf("android export: game ZIP entry %q is a symbolic link", name)
		}
		if !strings.HasSuffix(name, "/") {
			total += file.UncompressedSize64
			if total > runtimeMaxGameZIP {
				clear(data)
				return nil, errors.New("android export: clear Runtime game ZIP expands beyond 512 MiB")
			}
		}
		if name == "main.json" {
			hasManifest = true
		}
	}
	if !hasManifest {
		clear(data)
		return nil, errors.New("android export: clear Runtime game ZIP is missing main.json")
	}
	return data, nil
}

func validateRuntimeZIPName(value string) (string, error) {
	if value == "" || strings.ContainsRune(value, 0) || strings.Contains(value, "\\") {
		return "", fmt.Errorf("unsafe path %q", value)
	}
	if strings.HasPrefix(value, "/") || filepath.IsAbs(value) {
		return "", fmt.Errorf("absolute path %q", value)
	}
	parts := strings.Split(value, "/")
	for index, part := range parts {
		if part == ".." || part == "." || (part == "" && index != len(parts)-1) {
			return "", fmt.Errorf("unsafe path %q", value)
		}
	}
	return value, nil
}

func readLimitedFile(path string, maximum int64, label string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("android export: open %s: %w", label, err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("android export: stat %s: %w", label, err)
	}
	if info.Size() > maximum {
		return nil, fmt.Errorf("android export: %s exceeds %d bytes", label, maximum)
	}
	data, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil {
		return nil, fmt.Errorf("android export: read %s: %w", label, err)
	}
	if int64(len(data)) > maximum {
		clear(data)
		return nil, fmt.Errorf("android export: %s exceeds %d bytes", label, maximum)
	}
	return data, nil
}

func androidRuntimePublicKeyFingerprint(publicKeyDER []byte) (string, error) {
	if len(publicKeyDER) == 0 || len(publicKeyDER) > 8<<10 {
		return "", errors.New("android export: Android Runtime SPKI public key is not embedded or has an invalid size")
	}
	digest := sha256.Sum256(publicKeyDER)
	return base64.RawURLEncoding.EncodeToString(digest[:]), nil
}

func validateAndroidRuntimeTemplateContract(templatePath, publicKeyFingerprint string) error {
	data, err := readLimitedAPKEntry(
		templatePath,
		runtimeContractEntry,
		androidRuntimeContractMax,
	)
	if err != nil {
		return fmt.Errorf(
			"android export: Runtime template must be updated: read encryption contract: %w",
			err,
		)
	}
	var contract androidRuntimeContract
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&contract); err != nil {
		return fmt.Errorf(
			"android export: Runtime template must be updated: invalid encryption contract: %w",
			err,
		)
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return fmt.Errorf(
			"android export: Runtime template must be updated: invalid encryption contract: %w",
			err,
		)
	}
	if contract.SchemaVersion != 1 ||
		contract.Android.PackageKeyScheme != androidRuntimePackageScheme ||
		contract.Windows.PackageKeyScheme != windowsRuntimePackageScheme ||
		len(contract.Windows.PublicKeySHA256) != 43 {
		return fmt.Errorf(
			"android export: Runtime template must be updated: unsupported shared encryption contract schemaVersion=%d androidPackageKeyScheme=%q windowsPackageKeyScheme=%q",
			contract.SchemaVersion,
			contract.Android.PackageKeyScheme,
			contract.Windows.PackageKeyScheme,
		)
	}
	if subtle.ConstantTimeCompare(
		[]byte(contract.Android.PublicKeySHA256),
		[]byte(publicKeyFingerprint),
	) != 1 {
		return errors.New("android export: Runtime template must be updated: encryption publicKeySha256 does not match the exporter key")
	}
	return nil
}

func validateAndroidRuntimeEncryptionResult(
	result *runtimecrypto.EncryptResult,
	publicKeyFingerprint string,
	clearPackageLength int,
) error {
	if result == nil ||
		result.Codec != runtimecrypto.CodecAESGCMV1 ||
		result.Scheme != androidRuntimePackageScheme ||
		clearPackageLength <= 0 ||
		len(result.Envelope) != clearPackageLength+4+12+16 ||
		!bytes.Equal(result.Envelope[:4], []byte("PME1")) {
		return errors.New("android export: private Runtime crypto provider returned an invalid PME1 result")
	}
	if subtle.ConstantTimeCompare(
		[]byte(result.PublicKeySHA256),
		[]byte(publicKeyFingerprint),
	) != 1 {
		return errors.New("android export: private Runtime crypto provider returned the wrong public key fingerprint")
	}
	parts := strings.Split(result.KeyID, ":")
	if len(parts) != 3 || parts[0] != androidRuntimePackageScheme ||
		subtle.ConstantTimeCompare([]byte(parts[1]), []byte(publicKeyFingerprint)) != 1 {
		return errors.New("android export: private Runtime crypto provider returned an invalid keyId")
	}
	wrappedKey, err := base64.RawURLEncoding.Strict().DecodeString(parts[2])
	if err != nil || len(wrappedKey) != 3072/8 ||
		base64.RawURLEncoding.EncodeToString(wrappedKey) != parts[2] {
		clear(wrappedKey)
		return errors.New("android export: private Runtime crypto provider returned an invalid wrapped key")
	}
	clear(wrappedKey)
	return nil
}

func encodeRuntimePackageConfig(keyID string) ([]byte, error) {
	config := runtimePackageConfig{SchemaVersion: 1}
	config.Package.Asset = "assets/runtime/game.pmp"
	config.Package.Codec = runtimecrypto.CodecAESGCMV1
	config.Package.KeyID = keyID
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("android export: encode runtime-config.json: %w", err)
	}
	return append(data, '\n'), nil
}

func reserveTemporaryAPK(directory, pattern string) (string, error) {
	file, err := os.CreateTemp(directory, pattern)
	if err != nil {
		return "", fmt.Errorf("android export: reserve temporary APK: %w", err)
	}
	path := file.Name()
	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		return "", fmt.Errorf("android export: close temporary APK reservation: %w", err)
	}
	if err := os.Remove(path); err != nil {
		return "", fmt.Errorf("android export: release temporary APK reservation: %w", err)
	}
	return path, nil
}

type byteCountingWriter struct {
	writer io.Writer
	count  int64
}

func (writer *byteCountingWriter) Write(data []byte) (int, error) {
	written, err := writer.writer.Write(data)
	writer.count += int64(written)
	return written, err
}

func rewriteRuntimeAPK(templatePath, outputPath string, replacements map[string][]byte, expectedNative map[string]int64) (returnErr error) {
	reader, err := zip.OpenReader(templatePath)
	if err != nil {
		return err
	}
	defer reader.Close()

	out, err := os.OpenFile(outputPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	closed := false
	defer func() {
		if !closed {
			_ = out.Close()
		}
		if returnErr != nil {
			_ = os.Remove(outputPath)
		}
	}()
	counter := &byteCountingWriter{writer: out}
	writer := zip.NewWriter(counter)
	if reader.Comment != "" {
		if err := writer.SetComment(reader.Comment); err != nil {
			return err
		}
	}

	found := make(map[string]bool, len(replacements))
	seen := make(map[string]struct{}, len(reader.File))
	for _, source := range reader.File {
		if _, duplicate := seen[source.Name]; duplicate {
			return fmt.Errorf("template contains duplicate ZIP entry %q", source.Name)
		}
		seen[source.Name] = struct{}{}
		if isRuntimeV1SignatureEntry(source.Name) {
			continue
		}

		header := source.FileHeader
		// Raw entries have known sizes. Removing the data-descriptor flag makes
		// every entry's final local size observable before the next header, which
		// is required for exact native-library offset preservation.
		header.Flags &^= 0x8
		data, replace := replacements[source.Name]
		if replace {
			found[source.Name] = true
			header.Flags &^= 0x8
			header.Extra = nil
			if header.Method == zip.Store {
				if err := writer.Flush(); err != nil {
					return fmt.Errorf("flush before aligned replacement %s: %w", source.Name, err)
				}
				header.Extra = runtimeStoredEntryAlignmentExtra(
					counter.count,
					source.Name,
				)
			}
			if writeErr := writeRuntimeReplacement(writer, header, data); writeErr != nil {
				return fmt.Errorf("replace %s: %w", source.Name, writeErr)
			}
			continue
		}

		if target, native := expectedNative[source.Name]; native {
			if err := writer.Flush(); err != nil {
				return fmt.Errorf("flush before aligned native library %s: %w", source.Name, err)
			}
			extraLength := target - (counter.count + 30 + int64(len([]byte(source.Name))))
			if extraLength < 0 || extraLength > 0xffff {
				return fmt.Errorf(
					"cannot preserve native offset for %s: need ZIP extra length %d",
					source.Name,
					extraLength,
				)
			}
			header.Extra = runtimeAlignmentExtra(int(extraLength))
		} else if header.Method == zip.Store {
			if err := writer.Flush(); err != nil {
				return fmt.Errorf("flush before aligned stored entry %s: %w", source.Name, err)
			}
			header.Extra = runtimeStoredEntryAlignmentExtra(
				counter.count,
				source.Name,
			)
		}
		raw, openErr := source.OpenRaw()
		if openErr != nil {
			return fmt.Errorf("open raw %s: %w", source.Name, openErr)
		}
		destination, createErr := writer.CreateRaw(&header)
		if createErr != nil {
			return fmt.Errorf("create raw %s: %w", source.Name, createErr)
		}
		if _, copyErr := io.Copy(destination, raw); copyErr != nil {
			return fmt.Errorf("copy raw %s: %w", source.Name, copyErr)
		}
	}
	for name := range replacements {
		if !found[name] {
			return fmt.Errorf("fixed template entry was not found: %s", name)
		}
	}
	if err := writer.Close(); err != nil {
		return err
	}
	if err := out.Sync(); err != nil {
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	closed = true
	return nil
}

func writeRuntimeReplacement(writer *zip.Writer, header zip.FileHeader, data []byte) error {
	var compressed []byte
	switch header.Method {
	case zip.Store:
		compressed = data
	case zip.Deflate:
		var buffer bytes.Buffer
		compressor, err := flate.NewWriter(&buffer, flate.DefaultCompression)
		if err != nil {
			return err
		}
		if _, err := compressor.Write(data); err != nil {
			_ = compressor.Close()
			return err
		}
		if err := compressor.Close(); err != nil {
			return err
		}
		compressed = buffer.Bytes()
	default:
		return fmt.Errorf("unsupported ZIP compression method %d", header.Method)
	}
	header.CRC32 = crc32.ChecksumIEEE(data)
	header.CompressedSize64 = uint64(len(compressed))
	header.UncompressedSize64 = uint64(len(data))
	if uint64(len(compressed)) <= uint64(^uint32(0)) {
		header.CompressedSize = uint32(len(compressed))
	} else {
		header.CompressedSize = ^uint32(0)
	}
	if uint64(len(data)) <= uint64(^uint32(0)) {
		header.UncompressedSize = uint32(len(data))
	} else {
		header.UncompressedSize = ^uint32(0)
	}
	destination, err := writer.CreateRaw(&header)
	if err != nil {
		return err
	}
	_, err = destination.Write(compressed)
	return err
}

func runtimeAlignmentExtra(length int) []byte {
	if length <= 0 {
		return nil
	}
	result := make([]byte, length)
	if length >= 4 {
		binary.LittleEndian.PutUint16(result[0:2], 0xd935)
		binary.LittleEndian.PutUint16(result[2:4], uint16(length-4))
	}
	return result
}

func runtimeStoredEntryAlignmentExtra(currentOffset int64, name string) []byte {
	const alignment = int64(4)
	dataOffsetWithoutExtra := currentOffset + 30 + int64(len([]byte(name)))
	padding := int((alignment - dataOffsetWithoutExtra%alignment) % alignment)
	if padding == 0 {
		return nil
	}
	// A valid ZIP extra field needs its four-byte ID/size header. Adding four
	// bytes preserves the required modulo while keeping the field parseable.
	return runtimeAlignmentExtra(padding + 4)
}

func nativeLibraryOffsets(path string) (map[string]int64, error) {
	reader, err := zip.OpenReader(path)
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	result := make(map[string]int64)
	for _, file := range reader.File {
		if !isNativeLibraryEntry(file.Name) {
			continue
		}
		if _, duplicate := result[file.Name]; duplicate {
			return nil, fmt.Errorf("duplicate native library %q", file.Name)
		}
		offset, err := file.DataOffset()
		if err != nil {
			return nil, fmt.Errorf("read data offset for %s: %w", file.Name, err)
		}
		result[file.Name] = offset
	}
	return result, nil
}

func isNativeLibraryEntry(name string) bool {
	parts := strings.Split(name, "/")
	return len(parts) == 3 && parts[0] == "lib" && parts[1] != "" && strings.HasSuffix(parts[2], ".so")
}

func verifyNativeOffsets(expected, actual map[string]int64) error {
	if len(actual) != len(expected) {
		return fmt.Errorf("native library count changed from %d to %d", len(expected), len(actual))
	}
	for name, wanted := range expected {
		got, present := actual[name]
		if !present {
			return fmt.Errorf("native library %s is missing", name)
		}
		if wanted%runtimeNativeAlign != 0 {
			return fmt.Errorf("template native library %s offset %d is not 16 KiB aligned", name, wanted)
		}
		if got != wanted {
			return fmt.Errorf("native library %s moved from %d to %d", name, wanted, got)
		}
		if got%runtimeNativeAlign != 0 {
			return fmt.Errorf("native library %s offset %d is not 16 KiB aligned", name, got)
		}
	}
	return nil
}

func readAPKEntry(path, name string) ([]byte, error) {
	reader, err := zip.OpenReader(path)
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	for _, file := range reader.File {
		if file.Name != name {
			continue
		}
		input, err := file.Open()
		if err != nil {
			return nil, err
		}
		defer input.Close()
		return io.ReadAll(input)
	}
	return nil, fmt.Errorf("APK entry was not found: %s", name)
}

func readLimitedAPKEntry(path, name string, maximum int64) ([]byte, error) {
	reader, err := zip.OpenReader(path)
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	for _, file := range reader.File {
		if file.Name != name {
			continue
		}
		if file.FileInfo().IsDir() || file.UncompressedSize64 > uint64(maximum) {
			return nil, fmt.Errorf("APK entry %s exceeds %d bytes", name, maximum)
		}
		input, err := file.Open()
		if err != nil {
			return nil, err
		}
		defer input.Close()
		data, err := io.ReadAll(io.LimitReader(input, maximum+1))
		if err != nil {
			return nil, err
		}
		if int64(len(data)) > maximum {
			return nil, fmt.Errorf("APK entry %s exceeds %d bytes", name, maximum)
		}
		return data, nil
	}
	return nil, fmt.Errorf("APK entry was not found: %s", name)
}

func validateAPKEntryName(value string) (string, error) {
	value = strings.TrimSpace(strings.ReplaceAll(value, "\\", "/"))
	if value == "" || strings.HasPrefix(value, "/") || strings.HasSuffix(value, "/") || strings.ContainsRune(value, 0) {
		return "", fmt.Errorf("unsafe APK path %q", value)
	}
	for _, part := range strings.Split(value, "/") {
		if part == "" || part == "." || part == ".." {
			return "", fmt.Errorf("unsafe APK path %q", value)
		}
	}
	return value, nil
}

func isRuntimeV1SignatureEntry(name string) bool {
	upper := strings.ToUpper(strings.ReplaceAll(name, "\\", "/"))
	if upper == "META-INF/MANIFEST.MF" {
		return true
	}
	return strings.HasPrefix(upper, "META-INF/") &&
		(strings.HasSuffix(upper, ".SF") ||
			strings.HasSuffix(upper, ".RSA") ||
			strings.HasSuffix(upper, ".DSA") ||
			strings.HasSuffix(upper, ".EC"))
}

func fileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("android export: open completed APK for hashing: %w", err)
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", fmt.Errorf("android export: hash completed APK: %w", err)
	}
	return strings.ToLower(hex.EncodeToString(digest.Sum(nil))), nil
}

func exportAndroidError(err error) error {
	return fmt.Errorf("android export: %w", err)
}

type runtimeAXMLStringPool struct {
	strings    []string
	utf8       bool
	chunkStart int
	chunkSize  int
	headerSize int
	styleCount int
	styles     []byte
	prefix     []byte
}

type runtimeAXMLAttribute struct {
	element    string
	name       string
	rawIndex   uint32
	typeID     byte
	valueIndex uint32
	value      uint32
	offset     int
}

func rewriteRuntimeManifest(data []byte, applicationID, label, versionName string, versionCode uint32) ([]byte, error) {
	working := append([]byte(nil), data...)
	pool, err := parseRuntimeStringPool(working)
	if err != nil {
		return nil, err
	}
	attributes, err := parseRuntimeAXMLAttributes(working, pool)
	if err != nil {
		return nil, err
	}

	manifestPackage, err := findRuntimeAttribute(attributes, "manifest", "package")
	if err != nil {
		return nil, err
	}
	oldPackage, packageIndexes, err := runtimeStringAttribute(pool, manifestPackage)
	if err != nil {
		return nil, fmt.Errorf("manifest package: %w", err)
	}
	if !validAndroidApplicationID(oldPackage) {
		return nil, fmt.Errorf("template manifest package %q is invalid", oldPackage)
	}
	if !validAndroidApplicationID(applicationID) {
		return nil, fmt.Errorf("generated application ID %q is invalid", applicationID)
	}

	manifestVersion, err := findRuntimeAttribute(attributes, "manifest", "versionName")
	if err != nil {
		return nil, err
	}
	_, versionIndexes, err := runtimeStringAttribute(pool, manifestVersion)
	if err != nil {
		return nil, fmt.Errorf("manifest versionName: %w", err)
	}
	applicationLabel, err := findRuntimeAttribute(attributes, "application", "label")
	if err != nil {
		return nil, err
	}
	_, labelIndexes, err := runtimeStringAttribute(pool, applicationLabel)
	if err != nil {
		return nil, fmt.Errorf("application label: %w", err)
	}
	manifestVersionCode, err := findRuntimeAttribute(attributes, "manifest", "versionCode")
	if err != nil {
		return nil, err
	}
	if manifestVersionCode.rawIndex != androidNoString ||
		(manifestVersionCode.typeID != androidTypeIntDec && manifestVersionCode.typeID != androidTypeIntHex) {
		return nil, errors.New("manifest versionCode is not an inline integer")
	}
	binary.LittleEndian.PutUint32(working[manifestVersionCode.offset+16:manifestVersionCode.offset+20], versionCode)

	replacements := make(map[uint32]string)
	for _, index := range packageIndexes {
		replacements[index] = applicationID
	}
	for _, index := range versionIndexes {
		replacements[index] = versionName
	}
	for _, index := range labelIndexes {
		replacements[index] = label
	}
	for _, attribute := range attributes {
		if !runtimePackageDerivedAttribute(attribute) {
			continue
		}
		value, indexes, stringErr := runtimeStringAttribute(pool, attribute)
		if stringErr != nil {
			continue
		}
		replacement, changed := replaceRuntimePackagePrefix(value, oldPackage, applicationID)
		if !changed {
			continue
		}
		for _, index := range indexes {
			if existing, present := replacements[index]; present && existing != replacement {
				return nil, fmt.Errorf("string pool index %d requires conflicting replacements", index)
			}
			replacements[index] = replacement
		}
	}

	return rebuildRuntimeStringPool(working, pool, replacements)
}

func validAndroidApplicationID(value string) bool {
	if len(value) < 3 || len(value) > 255 || !strings.Contains(value, ".") {
		return false
	}
	for _, segment := range strings.Split(value, ".") {
		if segment == "" || !((segment[0] >= 'a' && segment[0] <= 'z') || (segment[0] >= 'A' && segment[0] <= 'Z')) {
			return false
		}
		for index := 1; index < len(segment); index++ {
			character := segment[index]
			if !((character >= 'a' && character <= 'z') ||
				(character >= 'A' && character <= 'Z') ||
				(character >= '0' && character <= '9') || character == '_') {
				return false
			}
		}
	}
	return true
}

func parseRuntimeStringPool(data []byte) (*runtimeAXMLStringPool, error) {
	if len(data) < 8 || binary.LittleEndian.Uint16(data[0:2]) != androidXMLType {
		return nil, errors.New("not an Android binary XML document")
	}
	documentSize := int(binary.LittleEndian.Uint32(data[4:8]))
	if documentSize != len(data) {
		return nil, fmt.Errorf("binary XML document size %d does not match file size %d", documentSize, len(data))
	}
	for offset := 8; offset+8 <= documentSize; {
		typeID, headerSize, chunkSize, err := runtimeChunkHeader(data, offset, documentSize)
		if err != nil {
			return nil, err
		}
		if typeID != androidStringPool {
			offset += chunkSize
			continue
		}
		if headerSize < 28 {
			return nil, errors.New("binary XML string pool header is too small")
		}
		stringCount := int(binary.LittleEndian.Uint32(data[offset+8 : offset+12]))
		styleCount := int(binary.LittleEndian.Uint32(data[offset+12 : offset+16]))
		flags := binary.LittleEndian.Uint32(data[offset+16 : offset+20])
		stringsStart := int(binary.LittleEndian.Uint32(data[offset+20 : offset+24]))
		stylesStart := int(binary.LittleEndian.Uint32(data[offset+24 : offset+28]))
		tableEnd := headerSize + (stringCount+styleCount)*4
		if stringCount < 1 || tableEnd > stringsStart || stringsStart >= chunkSize {
			return nil, errors.New("binary XML string pool table is invalid")
		}
		stringsEnd := chunkSize
		var styles []byte
		if styleCount > 0 {
			if stylesStart <= stringsStart || stylesStart > chunkSize {
				return nil, errors.New("binary XML style pool offset is invalid")
			}
			stringsEnd = stylesStart
			styles = append([]byte(nil), data[offset+stylesStart:offset+chunkSize]...)
		} else if stylesStart != 0 {
			return nil, errors.New("binary XML string pool has a styles offset without styles")
		}
		pool := &runtimeAXMLStringPool{
			strings:    make([]string, stringCount),
			utf8:       flags&androidUTF8Flag != 0,
			chunkStart: offset,
			chunkSize:  chunkSize,
			headerSize: headerSize,
			styleCount: styleCount,
			styles:     styles,
			prefix:     append([]byte(nil), data[offset:offset+stringsStart]...),
		}
		for index := 0; index < stringCount; index++ {
			relative := int(binary.LittleEndian.Uint32(data[offset+headerSize+index*4:]))
			absolute := offset + stringsStart + relative
			if absolute < offset+stringsStart || absolute >= offset+stringsEnd {
				return nil, fmt.Errorf("binary XML string index %d has an invalid offset", index)
			}
			value, _, decodeErr := decodeRuntimePoolString(data, absolute, offset+stringsEnd, pool.utf8)
			if decodeErr != nil {
				return nil, fmt.Errorf("decode binary XML string %d: %w", index, decodeErr)
			}
			pool.strings[index] = value
		}
		return pool, nil
	}
	return nil, errors.New("binary XML string pool was not found")
}

func parseRuntimeAXMLAttributes(data []byte, pool *runtimeAXMLStringPool) ([]runtimeAXMLAttribute, error) {
	documentSize := int(binary.LittleEndian.Uint32(data[4:8]))
	attributes := make([]runtimeAXMLAttribute, 0)
	for offset := 8; offset+8 <= documentSize; {
		typeID, headerSize, chunkSize, err := runtimeChunkHeader(data, offset, documentSize)
		if err != nil {
			return nil, err
		}
		if typeID != androidStartElement {
			offset += chunkSize
			continue
		}
		if headerSize < 16 || chunkSize < 36 {
			return nil, errors.New("binary XML start element chunk is too small")
		}
		elementIndex := binary.LittleEndian.Uint32(data[offset+20 : offset+24])
		element, err := pool.runtimeString(elementIndex)
		if err != nil {
			return nil, err
		}
		attributeStart := int(binary.LittleEndian.Uint16(data[offset+24 : offset+26]))
		attributeSize := int(binary.LittleEndian.Uint16(data[offset+26 : offset+28]))
		attributeCount := int(binary.LittleEndian.Uint16(data[offset+28 : offset+30]))
		if attributeSize < 20 {
			return nil, errors.New("binary XML attribute size is invalid")
		}
		first := offset + 16 + attributeStart
		if first < offset || first+attributeCount*attributeSize > offset+chunkSize {
			return nil, errors.New("binary XML attribute table is invalid")
		}
		for index := 0; index < attributeCount; index++ {
			attributeOffset := first + index*attributeSize
			nameIndex := binary.LittleEndian.Uint32(data[attributeOffset+4 : attributeOffset+8])
			name, err := pool.runtimeString(nameIndex)
			if err != nil {
				return nil, err
			}
			attributes = append(attributes, runtimeAXMLAttribute{
				element:    element,
				name:       name,
				rawIndex:   binary.LittleEndian.Uint32(data[attributeOffset+8 : attributeOffset+12]),
				typeID:     data[attributeOffset+15],
				valueIndex: binary.LittleEndian.Uint32(data[attributeOffset+16 : attributeOffset+20]),
				value:      binary.LittleEndian.Uint32(data[attributeOffset+16 : attributeOffset+20]),
				offset:     attributeOffset,
			})
		}
		offset += chunkSize
	}
	return attributes, nil
}

func runtimeChunkHeader(data []byte, offset, documentSize int) (uint16, int, int, error) {
	if offset < 0 || offset+8 > documentSize {
		return 0, 0, 0, io.ErrUnexpectedEOF
	}
	typeID := binary.LittleEndian.Uint16(data[offset : offset+2])
	headerSize := int(binary.LittleEndian.Uint16(data[offset+2 : offset+4]))
	chunkSize := int(binary.LittleEndian.Uint32(data[offset+4 : offset+8]))
	if headerSize < 8 || chunkSize < headerSize || offset+chunkSize > documentSize {
		return 0, 0, 0, fmt.Errorf("invalid binary XML chunk at offset %d", offset)
	}
	return typeID, headerSize, chunkSize, nil
}

func (pool *runtimeAXMLStringPool) runtimeString(index uint32) (string, error) {
	if index >= uint32(len(pool.strings)) {
		return "", fmt.Errorf("binary XML string index %d is out of range", index)
	}
	return pool.strings[index], nil
}

func findRuntimeAttribute(attributes []runtimeAXMLAttribute, element, name string) (runtimeAXMLAttribute, error) {
	var result runtimeAXMLAttribute
	found := false
	for _, attribute := range attributes {
		if attribute.element != element || attribute.name != name {
			continue
		}
		if found {
			return result, fmt.Errorf("attribute %s on %s is not unique", name, element)
		}
		result = attribute
		found = true
	}
	if !found {
		return result, fmt.Errorf("attribute %s was not found on %s", name, element)
	}
	return result, nil
}

func runtimeStringAttribute(pool *runtimeAXMLStringPool, attribute runtimeAXMLAttribute) (string, []uint32, error) {
	indexes := make([]uint32, 0, 2)
	if attribute.rawIndex != androidNoString {
		indexes = append(indexes, attribute.rawIndex)
	}
	if attribute.typeID == androidTypeString {
		if len(indexes) == 0 || indexes[0] != attribute.valueIndex {
			indexes = append(indexes, attribute.valueIndex)
		}
	}
	if len(indexes) == 0 {
		return "", nil, errors.New("attribute is not an inline string")
	}
	value, err := pool.runtimeString(indexes[len(indexes)-1])
	if err != nil {
		return "", nil, err
	}
	for _, index := range indexes[:len(indexes)-1] {
		other, err := pool.runtimeString(index)
		if err != nil {
			return "", nil, err
		}
		if other != value {
			return "", nil, errors.New("raw and typed string values differ")
		}
	}
	return value, indexes, nil
}

func runtimePackageDerivedAttribute(attribute runtimeAXMLAttribute) bool {
	switch attribute.name {
	case "authorities", "permission", "readPermission", "writePermission", "taskAffinity":
		return true
	case "name":
		return attribute.element == "permission" || strings.HasPrefix(attribute.element, "uses-permission")
	default:
		return false
	}
}

func replaceRuntimePackagePrefix(value, oldPackage, newPackage string) (string, bool) {
	if value == oldPackage {
		return newPackage, true
	}
	if strings.HasPrefix(value, oldPackage+".") {
		return newPackage + value[len(oldPackage):], true
	}
	if strings.Contains(value, ";") {
		parts := strings.Split(value, ";")
		changed := false
		for index, part := range parts {
			if part == oldPackage || strings.HasPrefix(part, oldPackage+".") {
				parts[index] = newPackage + part[len(oldPackage):]
				changed = true
			}
		}
		return strings.Join(parts, ";"), changed
	}
	return value, false
}

func rebuildRuntimeStringPool(data []byte, pool *runtimeAXMLStringPool, replacements map[uint32]string) ([]byte, error) {
	encodedStrings := make([][]byte, len(pool.strings))
	offsets := make([]uint32, len(pool.strings))
	stringDataSize := 0
	for index, value := range pool.strings {
		if replacement, present := replacements[uint32(index)]; present {
			value = replacement
		}
		encoded, err := encodeRuntimePoolString(value, pool.utf8)
		if err != nil {
			return nil, fmt.Errorf("encode binary XML string %d: %w", index, err)
		}
		if uint64(stringDataSize) > uint64(^uint32(0)) {
			return nil, errors.New("binary XML string pool is too large")
		}
		offsets[index] = uint32(stringDataSize)
		encodedStrings[index] = encoded
		stringDataSize += len(encoded)
	}
	padding := (4 - stringDataSize%4) % 4
	newChunkSize := len(pool.prefix) + stringDataSize + padding + len(pool.styles)
	if uint64(newChunkSize) > uint64(^uint32(0)) {
		return nil, errors.New("binary XML string pool is too large")
	}
	chunk := make([]byte, 0, newChunkSize)
	chunk = append(chunk, pool.prefix...)
	for index, offset := range offsets {
		binary.LittleEndian.PutUint32(chunk[pool.headerSize+index*4:], offset)
	}
	flags := binary.LittleEndian.Uint32(chunk[16:20]) &^ androidSortedFlag
	binary.LittleEndian.PutUint32(chunk[16:20], flags)
	for _, encoded := range encodedStrings {
		chunk = append(chunk, encoded...)
	}
	chunk = append(chunk, make([]byte, padding)...)
	if pool.styleCount > 0 {
		binary.LittleEndian.PutUint32(chunk[24:28], uint32(len(chunk)))
		chunk = append(chunk, pool.styles...)
	} else {
		binary.LittleEndian.PutUint32(chunk[24:28], 0)
	}
	binary.LittleEndian.PutUint32(chunk[4:8], uint32(len(chunk)))
	result := make([]byte, 0, len(data)-pool.chunkSize+len(chunk))
	result = append(result, data[:pool.chunkStart]...)
	result = append(result, chunk...)
	result = append(result, data[pool.chunkStart+pool.chunkSize:]...)
	binary.LittleEndian.PutUint32(result[4:8], uint32(len(result)))
	return result, nil
}

func decodeRuntimePoolString(data []byte, offset, limit int, utf8Pool bool) (string, int, error) {
	if utf8Pool {
		_, first, err := readRuntimeLength8(data, offset, limit)
		if err != nil {
			return "", 0, err
		}
		byteLength, second, err := readRuntimeLength8(data, offset+first, limit)
		if err != nil {
			return "", 0, err
		}
		start := offset + first + second
		end := start + byteLength
		if end >= limit || data[end] != 0 || !utf8.Valid(data[start:end]) {
			return "", 0, errors.New("invalid UTF-8 string pool entry")
		}
		return string(data[start:end]), end + 1 - offset, nil
	}
	unitLength, prefix, err := readRuntimeLength16(data, offset, limit)
	if err != nil {
		return "", 0, err
	}
	start := offset + prefix
	end := start + unitLength*2
	if end+2 > limit || binary.LittleEndian.Uint16(data[end:end+2]) != 0 {
		return "", 0, errors.New("invalid UTF-16 string pool entry")
	}
	units := make([]uint16, unitLength)
	for index := range units {
		units[index] = binary.LittleEndian.Uint16(data[start+index*2:])
	}
	return string(utf16.Decode(units)), end + 2 - offset, nil
}

func encodeRuntimePoolString(value string, utf8Pool bool) ([]byte, error) {
	units := utf16.Encode([]rune(value))
	if utf8Pool {
		valueBytes := []byte(value)
		unitLength, err := encodeRuntimeLength8(len(units))
		if err != nil {
			return nil, err
		}
		byteLength, err := encodeRuntimeLength8(len(valueBytes))
		if err != nil {
			return nil, err
		}
		result := make([]byte, 0, len(unitLength)+len(byteLength)+len(valueBytes)+1)
		result = append(result, unitLength...)
		result = append(result, byteLength...)
		result = append(result, valueBytes...)
		return append(result, 0), nil
	}
	length, err := encodeRuntimeLength16(len(units))
	if err != nil {
		return nil, err
	}
	result := make([]byte, len(length)+len(units)*2+2)
	copy(result, length)
	for index, unit := range units {
		binary.LittleEndian.PutUint16(result[len(length)+index*2:], unit)
	}
	return result, nil
}

func readRuntimeLength8(data []byte, offset, limit int) (int, int, error) {
	if offset >= limit {
		return 0, 0, io.ErrUnexpectedEOF
	}
	first := int(data[offset])
	if first&0x80 == 0 {
		return first, 1, nil
	}
	if offset+1 >= limit {
		return 0, 0, io.ErrUnexpectedEOF
	}
	return (first&0x7f)<<8 | int(data[offset+1]), 2, nil
}

func readRuntimeLength16(data []byte, offset, limit int) (int, int, error) {
	if offset+2 > limit {
		return 0, 0, io.ErrUnexpectedEOF
	}
	first := int(binary.LittleEndian.Uint16(data[offset:]))
	if first&0x8000 == 0 {
		return first, 2, nil
	}
	if offset+4 > limit {
		return 0, 0, io.ErrUnexpectedEOF
	}
	second := int(binary.LittleEndian.Uint16(data[offset+2:]))
	return (first&0x7fff)<<16 | second, 4, nil
}

func encodeRuntimeLength8(length int) ([]byte, error) {
	if length < 0 || length > 0x7fff {
		return nil, fmt.Errorf("UTF-8 pool length %d is out of range", length)
	}
	if length <= 0x7f {
		return []byte{byte(length)}, nil
	}
	return []byte{byte(length>>8) | 0x80, byte(length)}, nil
}

func encodeRuntimeLength16(length int) ([]byte, error) {
	if length < 0 || length > 0x7fffffff {
		return nil, fmt.Errorf("UTF-16 pool length %d is out of range", length)
	}
	if length <= 0x7fff {
		result := make([]byte, 2)
		binary.LittleEndian.PutUint16(result, uint16(length))
		return result, nil
	}
	result := make([]byte, 4)
	binary.LittleEndian.PutUint16(result, uint16(uint32(length)>>16)|0x8000)
	binary.LittleEndian.PutUint16(result[2:], uint16(length))
	return result, nil
}
