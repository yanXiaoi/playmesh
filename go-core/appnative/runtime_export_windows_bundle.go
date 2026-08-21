package appnative

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"

	"go-core/runtimecrypto"

	_ "embed"
)

const (
	windowsRuntimeGameEntry       = "data/flutter_assets/assets/runtime/game.pmp"
	windowsRuntimeConfigEntry     = "data/flutter_assets/assets/runtime/runtime-config.json"
	windowsRuntimeContractEntry   = "data/flutter_assets/assets/runtime/runtime-contract.json"
	windowsRuntimeExecutableEntry = "playmesh-runtime.exe"

	windowsRuntimePackageScheme = runtimecrypto.WindowsScheme
	windowsRuntimeOAEPLabel     = runtimecrypto.WindowsOAEPLabel

	windowsRuntimeMaxFiles       = 20_000
	windowsRuntimeMaxBytes       = uint64(512 << 20)
	windowsRuntimeEnvelopeBytes  = 4 + 12 + 16
	windowsRuntimeContractMax    = 4 << 10
	windowsRuntimeConfigMaxBytes = 4 << 10
)

var windowsRuntimeRequiredEntries = []string{
	windowsRuntimeExecutableEntry,
	"playmesh-core.exe",
	"flutter_windows.dll",
	"WebView2Loader.dll",
	"playmesh-runtime-crypto.dll",
	"data/app.so",
	"data/icudtl.dat",
}

// windowsRuntimePublicKeyDER deliberately contains only the public key. Tests
// call the internal export function with an ephemeral test key and never depend
// on the production private key.
//
//go:embed windows_runtime_public_key.der
var windowsRuntimePublicKeyDER []byte

type windowsRuntimeExportRequest struct {
	TemplateZipPath      string `json:"templateZipPath"`
	ClearGamePackagePath string `json:"clearGamePackagePath"`
	OutputZipPath        string `json:"outputZipPath"`
	ExecutableName       string `json:"executableName"`
	Label                string `json:"label"`
	VersionName          string `json:"versionName"`
	IconPath             string `json:"iconPath,omitempty"`
}

type windowsRuntimeExportReport struct {
	SchemaVersion          int      `json:"schemaVersion"`
	Kind                   string   `json:"kind"`
	OutputPath             string   `json:"outputPath"`
	SizeBytes              int64    `json:"sizeBytes"`
	SHA256                 string   `json:"sha256"`
	ClearGameSize          int64    `json:"clearGameSize"`
	ClearGameSHA256        string   `json:"clearGameSha256"`
	EncryptedGameSize      int64    `json:"encryptedGameSize"`
	RuntimePublicKeySHA256 string   `json:"runtimePublicKeySha256"`
	PackageKeyID           string   `json:"packageKeyId"`
	ReplacedEntries        []string `json:"replacedEntries"`
	RuntimePackageCodec    string   `json:"runtimePackageCodec"`
}

type windowsRuntimeContract struct {
	SchemaVersion int `json:"schemaVersion"`
	// Android is required in the shared cross-platform contract but is
	// validated by the Android exporter against its independent RSA key.
	Android json.RawMessage `json:"android"`
	Windows struct {
		PackageKeyScheme string `json:"packageKeyScheme"`
		PublicKeySHA256  string `json:"publicKeySha256"`
	} `json:"windows"`
}

type windowsRuntimePackageConfig struct {
	SchemaVersion int `json:"schemaVersion"`
	Package       struct {
		Asset string `json:"asset"`
		Codec string `json:"codec"`
		KeyID string `json:"keyId"`
	} `json:"package"`
}

type windowsOuterValidation struct {
	entries map[string]*zip.File
}

type windowsRuntimePackageEncryptor func(
	clear []byte,
	publicKeyDER []byte,
	scheme string,
	label string,
) (*runtimecrypto.EncryptResult, error)

type windowsRuntimeExecutablePatcher func(
	executable []byte,
	executableName string,
	label string,
	versionName string,
	iconPNG []byte,
) ([]byte, error)

// ExportWindowsRuntime encrypts and injects a clear Playmesh game ZIP into a
// compiled Windows Runtime bundle. The template's compressed entries are copied
// verbatim except for the renamed/customized launcher, game.pmp, and
// runtime-config.json. The completed bundle is validated and atomically
// published; an existing output is never overwritten.
//
// The string-only API is intentionally compatible with gomobile bindings.
func ExportWindowsRuntime(requestJSON string) (string, error) {
	return exportWindowsRuntimeWithEncryptor(
		requestJSON,
		windowsRuntimePublicKeyDER,
		runtimecrypto.EncryptPME1,
		customizeWindowsRuntimeExecutable,
	)
}

func exportWindowsRuntimeWithEncryptor(
	requestJSON string,
	publicKeyDER []byte,
	encryptPackage windowsRuntimePackageEncryptor,
	patchExecutable windowsRuntimeExecutablePatcher,
) (string, error) {
	publicKeyFingerprint, err := windowsRuntimePublicKeyFingerprint(publicKeyDER)
	if err != nil {
		return "", err
	}
	if encryptPackage == nil {
		return "", errors.New("runtime export: private Runtime crypto provider is unavailable")
	}
	if patchExecutable == nil {
		return "", errors.New("runtime export: Windows executable patcher is unavailable")
	}

	request, err := decodeWindowsRuntimeExportRequest(requestJSON)
	if err != nil {
		return "", err
	}
	templatePath, err := resolveWindowsExportInput(request.TemplateZipPath, "fixed outer ZIP")
	if err != nil {
		return "", err
	}
	gamePath, err := resolveWindowsExportInput(request.ClearGamePackagePath, "clear game ZIP")
	if err != nil {
		return "", err
	}
	outputPath, err := resolveWindowsExportOutput(request.OutputZipPath)
	if err != nil {
		return "", err
	}
	if sameRuntimeExportPath(templatePath, gamePath) ||
		sameRuntimeExportPath(templatePath, outputPath) ||
		sameRuntimeExportPath(gamePath, outputPath) {
		return "", errors.New("runtime export: template, game, and output paths must be distinct")
	}
	var iconPNG []byte
	if request.IconPath != "" {
		iconPath, resolveErr := resolveWindowsExportInput(request.IconPath, "icon PNG")
		if resolveErr != nil {
			return "", resolveErr
		}
		if sameRuntimeExportPath(iconPath, templatePath) ||
			sameRuntimeExportPath(iconPath, gamePath) ||
			sameRuntimeExportPath(iconPath, outputPath) {
			return "", errors.New("runtime export: icon PNG path must differ from every ZIP path")
		}
		iconPNG, err = readLimitedFile(iconPath, windowsRuntimeMaxIconPNG, "icon PNG")
		if err != nil {
			return "", err
		}
		defer clear(iconPNG)
	}

	template, err := zip.OpenReader(templatePath)
	if err != nil {
		return "", fmt.Errorf("runtime export: open fixed Windows ZIP: %w", err)
	}
	defer template.Close()
	outerValidation, err := validateWindowsOuterArchive(
		&template.Reader,
		publicKeyFingerprint,
		windowsRuntimeExecutableEntry,
	)
	if err != nil {
		return "", err
	}
	for existingName := range outerValidation.entries {
		if existingName != windowsRuntimeExecutableEntry &&
			strings.EqualFold(existingName, request.ExecutableName) {
			return "", fmt.Errorf(
				"runtime export: executableName collides with fixed bundle entry %q",
				existingName,
			)
		}
	}
	templateExecutable, err := readLimitedZipEntry(
		outerValidation.entries[windowsRuntimeExecutableEntry],
		windowsRuntimeMaxExecutableBytes+1,
	)
	if err != nil {
		return "", fmt.Errorf("runtime export: read fixed Windows executable: %w", err)
	}
	defer clear(templateExecutable)
	patchedExecutable, err := patchExecutable(
		templateExecutable,
		request.ExecutableName,
		request.Label,
		request.VersionName,
		iconPNG,
	)
	if err != nil {
		return "", fmt.Errorf("runtime export: customize Windows executable: %w", err)
	}
	if len(patchedExecutable) == 0 || len(patchedExecutable) > windowsRuntimeMaxExecutableBytes {
		clear(patchedExecutable)
		return "", errors.New("runtime export: customized Windows executable has an invalid size")
	}
	defer clear(patchedExecutable)
	gameSize, gameSHA256, err := validateClearGameZIP(gamePath)
	if err != nil {
		return "", err
	}
	clearGame, err := readWindowsClearGame(gamePath, gameSize, gameSHA256)
	if err != nil {
		return "", err
	}
	defer clear(clearGame)

	encryption, err := encryptPackage(
		clearGame,
		publicKeyDER,
		windowsRuntimePackageScheme,
		windowsRuntimeOAEPLabel,
	)
	if err != nil {
		return "", fmt.Errorf("runtime export: encrypt Windows game package: %w", err)
	}
	if err := validateWindowsRuntimeEncryptionResult(
		encryption,
		publicKeyFingerprint,
		gameSize,
	); err != nil {
		return "", err
	}
	encryptedGame := encryption.Envelope
	packageKeyID := encryption.KeyID
	defer clear(encryptedGame)
	runtimeConfig, err := encodeWindowsRuntimePackageConfig(packageKeyID)
	if err != nil {
		return "", err
	}

	temporary, err := os.CreateTemp(filepath.Dir(outputPath), ".playmesh-runtime-export-*.zip")
	if err != nil {
		return "", fmt.Errorf("runtime export: create temporary Windows ZIP: %w", err)
	}
	temporaryPath := temporary.Name()
	temporaryClosed := false
	defer func() {
		if !temporaryClosed {
			_ = temporary.Close()
		}
		_ = os.Remove(temporaryPath)
	}()

	writer := zip.NewWriter(temporary)
	for _, entry := range template.File {
		switch entry.Name {
		case windowsRuntimeExecutableEntry:
			header := replacementWindowsHeader(entry)
			header.Name = request.ExecutableName
			if err := writeWindowsReplacementHeader(
				writer,
				header,
				bytes.NewReader(patchedExecutable),
			); err != nil {
				_ = writer.Close()
				return "", err
			}
		case windowsRuntimeGameEntry:
			if err := writeWindowsReplacement(writer, entry, bytes.NewReader(encryptedGame)); err != nil {
				_ = writer.Close()
				return "", err
			}
		case windowsRuntimeConfigEntry:
			if err := writeWindowsReplacement(writer, entry, bytes.NewReader(runtimeConfig)); err != nil {
				_ = writer.Close()
				return "", err
			}
		default:
			if err := writer.Copy(entry); err != nil {
				_ = writer.Close()
				return "", fmt.Errorf("runtime export: raw-copy %q: %w", entry.Name, err)
			}
		}
	}
	if err := writer.Close(); err != nil {
		return "", fmt.Errorf("runtime export: finalize temporary Windows ZIP: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		return "", fmt.Errorf("runtime export: flush temporary Windows ZIP: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return "", fmt.Errorf("runtime export: close temporary Windows ZIP: %w", err)
	}
	temporaryClosed = true

	if err := validateExportedWindowsRuntime(
		temporaryPath,
		publicKeyFingerprint,
		request.ExecutableName,
		patchedExecutable,
		encryptedGame,
		runtimeConfig,
	); err != nil {
		return "", err
	}
	outputSize, outputSHA256, err := regularFileSHA256(temporaryPath)
	if err != nil {
		return "", fmt.Errorf("runtime export: hash completed Windows ZIP: %w", err)
	}
	// A same-directory hard link publishes the already-flushed file atomically
	// and can never replace an output created after the initial existence check.
	if err := os.Link(temporaryPath, outputPath); err != nil {
		return "", fmt.Errorf("runtime export: publish completed Windows ZIP: %w", err)
	}

	report := windowsRuntimeExportReport{
		SchemaVersion:          1,
		Kind:                   "windows-runtime-zip",
		OutputPath:             outputPath,
		SizeBytes:              outputSize,
		SHA256:                 outputSHA256,
		ClearGameSize:          gameSize,
		ClearGameSHA256:        gameSHA256,
		EncryptedGameSize:      int64(len(encryptedGame)),
		RuntimePublicKeySHA256: publicKeyFingerprint,
		PackageKeyID:           packageKeyID,
		ReplacedEntries: []string{
			windowsRuntimeExecutableEntry + "->" + request.ExecutableName,
			windowsRuntimeGameEntry,
			windowsRuntimeConfigEntry,
		},
		RuntimePackageCodec: runtimecrypto.CodecAESGCMV1,
	}
	encoded, err := json.Marshal(report)
	if err != nil {
		return "", fmt.Errorf("runtime export: encode Windows export report: %w", err)
	}
	return string(encoded), nil
}

func windowsRuntimePublicKeyFingerprint(publicKeyDER []byte) (string, error) {
	if len(publicKeyDER) == 0 || len(publicKeyDER) > 8<<10 {
		return "", errors.New("runtime export: Windows Runtime SPKI public key is not embedded or has an invalid size")
	}
	digest := sha256.Sum256(publicKeyDER)
	return base64.RawURLEncoding.EncodeToString(digest[:]), nil
}

func encodeWindowsRuntimePackageConfig(packageKeyID string) ([]byte, error) {
	config := windowsRuntimePackageConfig{SchemaVersion: 1}
	config.Package.Asset = "assets/runtime/game.pmp"
	config.Package.Codec = runtimecrypto.CodecAESGCMV1
	config.Package.KeyID = packageKeyID
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("runtime export: encode runtime-config.json: %w", err)
	}
	data = append(data, '\n')
	if len(data) > windowsRuntimeConfigMaxBytes {
		return nil, errors.New("runtime export: generated runtime config exceeds size limit")
	}
	return data, nil
}

func decodeWindowsRuntimeExportRequest(requestJSON string) (windowsRuntimeExportRequest, error) {
	var request windowsRuntimeExportRequest
	decoder := json.NewDecoder(strings.NewReader(requestJSON))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return request, fmt.Errorf("runtime export: decode Windows request JSON: %w", err)
	}
	if err := ensureWindowsRequestJSONEOF(decoder); err != nil {
		return request, err
	}
	if strings.TrimSpace(request.TemplateZipPath) == "" ||
		strings.TrimSpace(request.ClearGamePackagePath) == "" ||
		strings.TrimSpace(request.OutputZipPath) == "" ||
		strings.TrimSpace(request.ExecutableName) == "" ||
		strings.TrimSpace(request.Label) == "" ||
		strings.TrimSpace(request.VersionName) == "" {
		return request, errors.New("runtime export: templateZipPath, clearGamePackagePath, outputZipPath, executableName, label, and versionName are required")
	}
	if err := validateWindowsRuntimeExecutableName(request.ExecutableName); err != nil {
		return request, err
	}
	if err := validateWindowsRuntimeLabel(request.Label); err != nil {
		return request, err
	}
	if _, err := parseWindowsRuntimeVersion(request.VersionName); err != nil {
		return request, err
	}
	return request, nil
}

func ensureWindowsRequestJSONEOF(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); err == io.EOF {
		return nil
	} else if err != nil {
		return fmt.Errorf("runtime export: decode trailing request JSON: %w", err)
	}
	return errors.New("runtime export: request must contain exactly one JSON document")
}

func validateClearGameZIP(gamePath string) (int64, string, error) {
	archive, err := zip.OpenReader(gamePath)
	if err != nil {
		return 0, "", fmt.Errorf("runtime export: clear game is not a valid ZIP: %w", err)
	}
	defer archive.Close()
	if len(archive.File) > windowsRuntimeMaxFiles {
		return 0, "", fmt.Errorf("runtime export: clear game ZIP contains too many entries: %d", len(archive.File))
	}
	seen := make(map[string]struct{}, len(archive.File))
	hasMain := false
	var uncompressedBytes uint64
	for _, entry := range archive.File {
		if err := validateRuntimeArchiveName(entry.Name); err != nil {
			return 0, "", fmt.Errorf("runtime export: invalid clear game entry %q: %w", entry.Name, err)
		}
		if _, exists := seen[entry.Name]; exists {
			return 0, "", fmt.Errorf("runtime export: duplicate clear game entry %q", entry.Name)
		}
		seen[entry.Name] = struct{}{}
		if entry.UncompressedSize64 > windowsRuntimeMaxBytes-uncompressedBytes {
			return 0, "", errors.New("runtime export: clear game ZIP exceeds the 512 MiB uncompressed limit")
		}
		uncompressedBytes += entry.UncompressedSize64
		if entry.Name == "main.json" && !entry.FileInfo().IsDir() {
			hasMain = true
		}
		if !entry.FileInfo().IsDir() {
			reader, err := entry.Open()
			if err != nil {
				return 0, "", fmt.Errorf("runtime export: open clear game entry %q: %w", entry.Name, err)
			}
			_, copyErr := io.Copy(io.Discard, reader)
			closeErr := reader.Close()
			if copyErr != nil {
				return 0, "", fmt.Errorf("runtime export: verify clear game entry %q: %w", entry.Name, copyErr)
			}
			if closeErr != nil {
				return 0, "", fmt.Errorf("runtime export: close clear game entry %q: %w", entry.Name, closeErr)
			}
		}
	}
	if !hasMain {
		return 0, "", errors.New("runtime export: clear game ZIP is missing root main.json")
	}
	size, digest, err := regularFileSHA256(gamePath)
	if err != nil {
		return 0, "", fmt.Errorf("runtime export: hash clear game ZIP: %w", err)
	}
	if uint64(size) > windowsRuntimeMaxBytes {
		return 0, "", errors.New("runtime export: clear game ZIP exceeds the 512 MiB package limit")
	}
	return size, digest, nil
}

func readWindowsClearGame(gamePath string, expectedSize int64, expectedSHA256 string) ([]byte, error) {
	data, err := os.ReadFile(gamePath)
	if err != nil {
		return nil, fmt.Errorf("runtime export: read clear game ZIP: %w", err)
	}
	if int64(len(data)) != expectedSize {
		clear(data)
		return nil, errors.New("runtime export: clear game ZIP changed during export")
	}
	digest := sha256.Sum256(data)
	actualSHA256 := hex.EncodeToString(digest[:])
	if subtle.ConstantTimeCompare([]byte(actualSHA256), []byte(expectedSHA256)) != 1 {
		clear(data)
		return nil, errors.New("runtime export: clear game ZIP changed during export")
	}
	return data, nil
}

func validateWindowsRuntimeEncryptionResult(
	result *runtimecrypto.EncryptResult,
	publicKeyFingerprint string,
	clearGameSize int64,
) error {
	if result == nil ||
		result.Codec != runtimecrypto.CodecAESGCMV1 ||
		result.Scheme != windowsRuntimePackageScheme ||
		clearGameSize < 0 ||
		int64(len(result.Envelope)) != clearGameSize+windowsRuntimeEnvelopeBytes ||
		len(result.Envelope) < windowsRuntimeEnvelopeBytes ||
		!bytes.Equal(result.Envelope[:4], []byte("PME1")) {
		return errors.New("runtime export: private Runtime crypto provider returned an invalid PME1 result")
	}
	if subtle.ConstantTimeCompare(
		[]byte(result.PublicKeySHA256),
		[]byte(publicKeyFingerprint),
	) != 1 {
		return errors.New("runtime export: private Runtime crypto provider returned the wrong public key fingerprint")
	}
	parts := strings.Split(result.KeyID, ":")
	if len(parts) != 3 || parts[0] != windowsRuntimePackageScheme ||
		subtle.ConstantTimeCompare([]byte(parts[1]), []byte(publicKeyFingerprint)) != 1 {
		return errors.New("runtime export: private Runtime crypto provider returned an invalid keyId")
	}
	wrappedKey, err := base64.RawURLEncoding.Strict().DecodeString(parts[2])
	if err != nil || len(wrappedKey) != 3072/8 ||
		base64.RawURLEncoding.EncodeToString(wrappedKey) != parts[2] {
		clear(wrappedKey)
		return errors.New("runtime export: private Runtime crypto provider returned an invalid wrapped key")
	}
	clear(wrappedKey)
	return nil
}

func validateWindowsOuterArchive(
	archive *zip.Reader,
	publicKeyFingerprint string,
	executableEntryName string,
) (*windowsOuterValidation, error) {
	if len(archive.File) > windowsRuntimeMaxFiles {
		return nil, fmt.Errorf(
			"runtime export: fixed Windows ZIP contains too many entries: %d",
			len(archive.File),
		)
	}
	entries := make(map[string]*zip.File, len(archive.File))
	caseFoldedEntries := make(map[string]string, len(archive.File))
	for _, entry := range archive.File {
		if err := validateRuntimeArchiveName(entry.Name); err != nil {
			return nil, fmt.Errorf("runtime export: invalid fixed Windows ZIP entry %q: %w", entry.Name, err)
		}
		if entry.Mode()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("runtime export: fixed Windows ZIP contains symlink entry %q", entry.Name)
		}
		if _, exists := entries[entry.Name]; exists {
			return nil, fmt.Errorf("runtime export: fixed Windows ZIP contains duplicate entry %q", entry.Name)
		}
		foldedName := strings.ToLower(entry.Name)
		if existing, exists := caseFoldedEntries[foldedName]; exists {
			return nil, fmt.Errorf(
				"runtime export: fixed Windows ZIP contains case-insensitive duplicate entries %q and %q",
				existing,
				entry.Name,
			)
		}
		entries[entry.Name] = entry
		caseFoldedEntries[foldedName] = entry.Name
	}
	requiredEntries := append([]string{}, windowsRuntimeRequiredEntries...)
	requiredEntries[0] = executableEntryName
	for _, required := range append(requiredEntries, windowsRuntimeGameEntry, windowsRuntimeConfigEntry) {
		entry, exists := entries[required]
		if !exists || entry.FileInfo().IsDir() {
			return nil, fmt.Errorf("runtime export: fixed Windows ZIP is missing required file %q", required)
		}
	}
	contractEntry, exists := entries[windowsRuntimeContractEntry]
	if !exists || contractEntry.FileInfo().IsDir() {
		return nil, fmt.Errorf(
			"runtime export: fixed Windows Runtime must be updated: missing encryption contract %q",
			windowsRuntimeContractEntry,
		)
	}
	if err := validateWindowsRuntimeContract(contractEntry, publicKeyFingerprint); err != nil {
		return nil, err
	}
	return &windowsOuterValidation{entries: entries}, nil
}

func validateWindowsRuntimeContract(entry *zip.File, publicKeyFingerprint string) error {
	data, err := readLimitedZipEntry(entry, windowsRuntimeContractMax+1)
	if err != nil {
		return fmt.Errorf("runtime export: fixed Windows Runtime must be updated: read encryption contract: %w", err)
	}
	var contract windowsRuntimeContract
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&contract); err != nil {
		return fmt.Errorf("runtime export: fixed Windows Runtime must be updated: invalid encryption contract: %w", err)
	}
	if err := ensureWindowsRequestJSONEOF(decoder); err != nil {
		return fmt.Errorf("runtime export: fixed Windows Runtime must be updated: invalid encryption contract: %w", err)
	}
	if contract.SchemaVersion != 1 || contract.Windows.PackageKeyScheme != windowsRuntimePackageScheme {
		return fmt.Errorf(
			"runtime export: fixed Windows Runtime must be updated: unsupported encryption contract schemaVersion=%d packageKeyScheme=%q",
			contract.SchemaVersion,
			contract.Windows.PackageKeyScheme,
		)
	}
	if subtle.ConstantTimeCompare(
		[]byte(contract.Windows.PublicKeySHA256),
		[]byte(publicKeyFingerprint),
	) != 1 {
		return errors.New("runtime export: fixed Windows Runtime must be updated: encryption publicKeySha256 does not match the exporter key")
	}
	return nil
}

func validateExportedWindowsRuntime(
	filePath string,
	publicKeyFingerprint string,
	executableName string,
	expectedExecutable []byte,
	expectedEncryptedGame []byte,
	expectedConfig []byte,
) error {
	archive, err := zip.OpenReader(filePath)
	if err != nil {
		return fmt.Errorf("runtime export: reopen completed Windows ZIP: %w", err)
	}
	defer archive.Close()
	validation, err := validateWindowsOuterArchive(
		&archive.Reader,
		publicKeyFingerprint,
		executableName,
	)
	if err != nil {
		return err
	}
	if executableName != windowsRuntimeExecutableEntry {
		if _, exists := validation.entries[windowsRuntimeExecutableEntry]; exists {
			return errors.New("runtime export: completed Windows ZIP still contains the template executable name")
		}
	}
	executableEntry := validation.entries[executableName]
	if executableEntry.UncompressedSize64 != uint64(len(expectedExecutable)) {
		return errors.New("runtime export: customized Windows executable size does not match")
	}
	executableDigest, err := zipEntrySHA256(executableEntry)
	if err != nil {
		return fmt.Errorf("runtime export: verify customized Windows executable: %w", err)
	}
	expectedExecutableDigest := sha256.Sum256(expectedExecutable)
	if subtle.ConstantTimeCompare(
		[]byte(executableDigest),
		[]byte(hex.EncodeToString(expectedExecutableDigest[:])),
	) != 1 {
		return errors.New("runtime export: customized Windows executable does not match the patcher result")
	}
	gameEntry := validation.entries[windowsRuntimeGameEntry]
	if gameEntry.UncompressedSize64 != uint64(len(expectedEncryptedGame)) {
		return errors.New("runtime export: injected encrypted game size does not match the private provider result")
	}
	gameDigest, err := zipEntrySHA256(gameEntry)
	if err != nil {
		return fmt.Errorf("runtime export: verify encrypted game: %w", err)
	}
	expectedGameDigest := sha256.Sum256(expectedEncryptedGame)
	expectedGameSHA256 := hex.EncodeToString(expectedGameDigest[:])
	if subtle.ConstantTimeCompare([]byte(gameDigest), []byte(expectedGameSHA256)) != 1 {
		return errors.New("runtime export: injected encrypted game does not match the private provider result")
	}
	config, err := readLimitedZipEntry(validation.entries[windowsRuntimeConfigEntry], windowsRuntimeConfigMaxBytes+1)
	if err != nil {
		return fmt.Errorf("runtime export: verify runtime config: %w", err)
	}
	if !bytes.Equal(config, expectedConfig) {
		return errors.New("runtime export: injected runtime config does not match the generated package config")
	}
	return nil
}

func writeWindowsReplacement(writer *zip.Writer, template *zip.File, source io.Reader) error {
	header := replacementWindowsHeader(template)
	return writeWindowsReplacementHeader(writer, header, source)
}

func writeWindowsReplacementHeader(
	writer *zip.Writer,
	header zip.FileHeader,
	source io.Reader,
) error {
	destination, err := writer.CreateHeader(&header)
	if err != nil {
		return fmt.Errorf("runtime export: create replacement %q: %w", header.Name, err)
	}
	if _, err := io.Copy(destination, source); err != nil {
		return fmt.Errorf("runtime export: write replacement %q: %w", header.Name, err)
	}
	return nil
}

func replacementWindowsHeader(template *zip.File) zip.FileHeader {
	header := template.FileHeader
	header.CRC32 = 0
	header.CompressedSize = 0
	header.CompressedSize64 = 0
	header.UncompressedSize = 0
	header.UncompressedSize64 = 0
	header.Extra = nil
	return header
}

func validateRuntimeArchiveName(name string) error {
	if name == "" || strings.Contains(name, "\\") || strings.HasPrefix(name, "/") {
		return errors.New("unsafe archive path")
	}
	trimmed := strings.TrimSuffix(name, "/")
	if trimmed == "" || path.Clean(trimmed) != trimmed || trimmed == ".." || strings.HasPrefix(trimmed, "../") {
		return errors.New("unsafe archive path")
	}
	first := trimmed
	if slash := strings.IndexByte(first, '/'); slash >= 0 {
		first = first[:slash]
	}
	if strings.Contains(first, ":") {
		return errors.New("unsafe archive path")
	}
	return nil
}

func resolveWindowsExportInput(value, label string) (string, error) {
	if strings.TrimSpace(value) == "" {
		return "", fmt.Errorf("runtime export: %s path is required", label)
	}
	resolved, err := filepath.Abs(filepath.Clean(value))
	if err != nil {
		return "", fmt.Errorf("runtime export: resolve %s path: %w", label, err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", fmt.Errorf("runtime export: stat %s: %w", label, err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("runtime export: %s is not a regular file", label)
	}
	return resolved, nil
}

func resolveWindowsExportOutput(value string) (string, error) {
	if strings.TrimSpace(value) == "" {
		return "", errors.New("runtime export: output path is required")
	}
	resolved, err := filepath.Abs(filepath.Clean(value))
	if err != nil {
		return "", fmt.Errorf("runtime export: resolve output path: %w", err)
	}
	if info, err := os.Stat(resolved); err == nil {
		if info.Mode().IsRegular() {
			return "", fmt.Errorf("runtime export: output already exists: %w", os.ErrExist)
		}
		return "", errors.New("runtime export: output path exists and is not a regular file")
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", fmt.Errorf("runtime export: stat output path: %w", err)
	}
	parent, err := os.Stat(filepath.Dir(resolved))
	if err != nil {
		return "", fmt.Errorf("runtime export: stat output directory: %w", err)
	}
	if !parent.IsDir() {
		return "", errors.New("runtime export: output parent is not a directory")
	}
	return resolved, nil
}

func sameRuntimeExportPath(left, right string) bool {
	return left == right || strings.EqualFold(left, right)
}

func regularFileSHA256(filePath string) (int64, string, error) {
	file, err := os.Open(filePath)
	if err != nil {
		return 0, "", err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return 0, "", err
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return 0, "", err
	}
	return info.Size(), strings.ToLower(hex.EncodeToString(hash.Sum(nil))), nil
}

func zipEntrySHA256(entry *zip.File) (string, error) {
	reader, err := entry.Open()
	if err != nil {
		return "", err
	}
	defer reader.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, reader); err != nil {
		return "", err
	}
	return strings.ToLower(hex.EncodeToString(hash.Sum(nil))), nil
}

func readLimitedZipEntry(entry *zip.File, limit int64) ([]byte, error) {
	reader, err := entry.Open()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	data, err := io.ReadAll(io.LimitReader(reader, limit))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) >= limit {
		return nil, errors.New("ZIP entry exceeds expected size")
	}
	return data, nil
}
