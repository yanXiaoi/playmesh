package packages

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"image/png"
	"io"
	"log/slog"
	"mime/multipart"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"go-server/internal/config"
	"go-server/internal/gameid"
	"go-server/internal/mailer"
	"go-server/internal/store"
	"go-server/internal/version"
)

type RejectedError struct {
	Reason string
	Game   store.Game
}

func (e *RejectedError) Error() string {
	return e.Reason
}

type InputError struct {
	Reason string
}

type BusyError struct{}

func (e *BusyError) Error() string { return "安全扫描任务已满，请稍后重试" }

func (e *InputError) Error() string {
	return e.Reason
}

const (
	maxManifestBytes    int64 = 256 << 10
	maxActiveTextBytes  int64 = 4 << 20
	maxFindingBytes           = 8 << 10
	maxArchivePathBytes       = 512
	maxRootIconBytes          = 2 << 20
	maxRootIconEdge           = 8192
	maxRootIconPixels   int64 = 4 * 1024 * 1024
	maxGameTagCount           = 5
	maxGameTagRunes           = 64
)

var (
	storedArtifactName = regexp.MustCompile(
		`^[1-9][0-9]*-[0-9a-f]{16}-[0-9a-f]{16}\.(zip|png)(\.tmp)?$`,
	)
	quarantineArtifactName = regexp.MustCompile(
		`^(upload|normalized)-[0-9]+\.zip$`,
	)
)

type ScanReport struct {
	Passed        bool     `json:"passed"`
	SHA256        string   `json:"sha256"`
	Antivirus     string   `json:"antivirus"`
	AntivirusInfo string   `json:"antivirusInfo,omitempty"`
	Findings      []string `json:"findings"`
	ScannedAt     int64    `json:"scannedAt"`
}

type manifestSummary struct {
	ID            string
	Name          string
	Author        string
	Version       string
	Remarks       string
	TagsText      string
	JSON          string
	ScannableJSON string
	Icon          []byte
}

// Only fields understood by the current server are projected into the active
// content scanner. The complete manifest is preserved separately so a newer
// SDK can add fields without requiring a simultaneous server release.
var scannableManifestFields = []string{
	"id",
	"name",
	"author",
	"lastModifiedAt",
	"remarks",
	"version",
	"sdkVersion",
	"appSdkVersion",
	"orientation",
	"controllerOrientation",
	"modes",
	"displayModes",
	"players",
	"entries",
	"authority",
	"tags",
}

var scannableManifestObjectFields = map[string][]string{
	"players":   {"min", "max"},
	"entries":   {"game", "controller"},
	"authority": {"entry"},
}

type Service struct {
	config       config.Config
	store        *store.Store
	mailer       *mailer.Mailer
	logger       *slog.Logger
	contentRules []compiledContentRule
	scanSlots    chan struct{}
	mutex        sync.RWMutex
}

type compiledContentRule struct {
	id          string
	description string
	pattern     *regexp.Regexp
	extensions  map[string]struct{}
}

func New(
	cfg config.Config,
	database *store.Store,
	mailService *mailer.Mailer,
	logger *slog.Logger,
) *Service {
	return &Service{
		config: cfg, store: database, mailer: mailService, logger: logger,
		contentRules: compileContentRules(cfg.Scanner.ContentRules),
		scanSlots:    make(chan struct{}, cfg.Storage.MaxConcurrentScans),
	}
}

func compileContentRules(source []config.ContentRule) []compiledContentRule {
	rules := make([]compiledContentRule, 0, len(source))
	for _, rule := range source {
		if !rule.Enabled {
			continue
		}
		extensions := make(map[string]struct{}, len(rule.Extensions))
		for _, extension := range rule.Extensions {
			extensions[extension] = struct{}{}
		}
		rules = append(rules, compiledContentRule{
			id: rule.ID, description: rule.Description,
			pattern: regexp.MustCompile(rule.Pattern), extensions: extensions,
		})
	}
	return rules
}

func (s *Service) UpdateScanner(scanner config.Scanner) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	s.config.Scanner = scanner
	s.contentRules = compileContentRules(scanner.ContentRules)
}

func (s *Service) CleanupDeleting(ctx context.Context) (int, error) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	games, err := s.store.ListDeletingGames(ctx)
	if err != nil {
		return 0, err
	}
	completed := 0
	failures := make([]error, 0)
	for _, game := range games {
		if err := DeleteStoredFiles(
			s.config.Storage.GamesDirectory, game.StoredPath, game.IconPath,
		); err != nil {
			failures = append(failures, fmt.Errorf(
				"清理 deleting 游戏 %d 文件: %w", game.ID, err,
			))
			continue
		}
		if _, err := s.store.CompleteDeletingGame(
			ctx, game.ID, store.SystemReviewActor(),
		); err != nil && !errors.Is(err, store.ErrNotFound) {
			failures = append(failures, fmt.Errorf(
				"完成 deleting 游戏 %d: %w", game.ID, err,
			))
			continue
		}
		completed++
	}
	orphaned, orphanErr := s.cleanupOrphanedFiles(ctx)
	if orphanErr != nil {
		failures = append(failures, orphanErr)
	}
	if orphaned > 0 && s.logger != nil {
		s.logger.Info("orphan artifact cleanup completed", "files", orphaned)
	}
	return completed, errors.Join(failures...)
}

func (s *Service) cleanupOrphanedFiles(ctx context.Context) (int, error) {
	storedPaths, err := s.store.ListStoredFilePaths(ctx)
	if err != nil {
		return 0, fmt.Errorf("list stored file references: %w", err)
	}
	gamesRoot, err := filepath.Abs(filepath.Clean(s.config.Storage.GamesDirectory))
	if err != nil {
		return 0, fmt.Errorf("resolve games directory: %w", err)
	}
	referencedNames := make(map[string]struct{}, len(storedPaths))
	for _, candidate := range storedPaths {
		target, resolveErr := filepath.Abs(filepath.Clean(candidate))
		if resolveErr != nil || !pathWithin(gamesRoot, target) {
			continue
		}
		relative, relativeErr := filepath.Rel(gamesRoot, target)
		if relativeErr == nil && filepath.Dir(relative) == "." {
			referencedNames[relative] = struct{}{}
		}
	}
	gamesRemoved, gamesErr := cleanupGeneratedArtifacts(
		ctx,
		gamesRoot,
		storedArtifactName,
		referencedNames,
	)
	quarantineRemoved, quarantineErr := cleanupGeneratedArtifacts(
		ctx,
		s.config.Storage.QuarantineDirectory,
		quarantineArtifactName,
		nil,
	)
	return gamesRemoved + quarantineRemoved, errors.Join(gamesErr, quarantineErr)
}

func cleanupGeneratedArtifacts(
	ctx context.Context,
	root string,
	namePattern *regexp.Regexp,
	referencedNames map[string]struct{},
) (int, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return 0, fmt.Errorf("scan artifact directory %q: %w", root, err)
	}
	removed := 0
	failures := make([]error, 0)
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			failures = append(failures, err)
			break
		}
		name := entry.Name()
		if !namePattern.MatchString(name) {
			continue
		}
		if _, referenced := referencedNames[name]; referenced {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			failures = append(
				failures,
				fmt.Errorf("inspect orphan artifact %q: %w", name, err),
			)
			continue
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			continue
		}
		target := filepath.Join(root, name)
		if err := os.Remove(target); err != nil && !errors.Is(err, os.ErrNotExist) {
			failures = append(
				failures,
				fmt.Errorf("remove orphan artifact %q: %w", name, err),
			)
			continue
		}
		removed++
	}
	return removed, errors.Join(failures...)
}

func (s *Service) removeTemporaryFile(filePath string, kind string) {
	err := os.Remove(filePath)
	if err == nil || errors.Is(err, os.ErrNotExist) {
		return
	}
	if s.logger != nil {
		s.logger.Warn(
			"temporary upload cleanup failed",
			"kind", kind,
			"file", filepath.Base(filePath),
			"error", err,
		)
	}
}

func (s *Service) logUploadCleanupFailure(stage string, err error) {
	if err == nil || s.logger == nil {
		return
	}
	s.logger.Warn(
		"failed upload artifact cleanup deferred to background retry",
		"stage", stage,
		"error", err,
	)
}

func (s *Service) ProcessUserUpload(
	ctx context.Context,
	file multipart.File,
	filename string,
	user store.User,
) (store.Game, error) {
	select {
	case s.scanSlots <- struct{}{}:
		defer func() { <-s.scanSlots }()
	default:
		return store.Game{}, &BusyError{}
	}
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	filename = filepath.Base(strings.TrimSpace(filename))
	if filename == "." || len(filename) > 255 || strings.ContainsRune(filename, '\x00') {
		return store.Game{}, &InputError{Reason: "上传文件名无效或过长"}
	}
	if !strings.EqualFold(filepath.Ext(filename), ".zip") {
		return store.Game{}, &InputError{Reason: "只接受 .zip 标准游戏包"}
	}
	temp, err := os.CreateTemp(s.config.Storage.QuarantineDirectory, "upload-*.zip")
	if err != nil {
		return store.Game{}, fmt.Errorf("创建隔离文件: %w", err)
	}
	tempPath := temp.Name()
	defer s.removeTemporaryFile(tempPath, "upload quarantine")
	hasher := sha256.New()
	written, copyErr := io.Copy(
		io.MultiWriter(temp, hasher),
		io.LimitReader(file, s.config.Storage.MaxUploadBytes+1),
	)
	closeErr := temp.Close()
	if copyErr != nil {
		return store.Game{}, fmt.Errorf("写入隔离文件: %w", copyErr)
	}
	if closeErr != nil {
		return store.Game{}, closeErr
	}
	hash := hex.EncodeToString(hasher.Sum(nil))
	if written > s.config.Storage.MaxUploadBytes {
		return s.reject(hash, ScanReport{
			Passed: false, SHA256: hash, Antivirus: "not_run",
			Findings:  []string{"压缩包超过上传大小上限"},
			ScannedAt: time.Now().UnixMilli(),
		})
	}

	report := ScanReport{
		SHA256: hash, Findings: make([]string, 0), ScannedAt: time.Now().UnixMilli(),
	}
	antivirusStatus, antivirusInfo, antivirusFinding := s.scanClamAV(ctx, tempPath)
	report.Antivirus = antivirusStatus
	report.AntivirusInfo = antivirusInfo
	if antivirusFinding != "" {
		report.Findings = append(report.Findings, antivirusFinding)
	}

	summary, findings := s.inspectArchive(tempPath)
	report.Findings = append(report.Findings, findings...)
	if summary.ID != "" {
		if err := s.store.CheckOwnership(ctx, summary.ID, user.ID); err != nil {
			return store.Game{}, err
		}
	}
	// 所有权冲突必须优先于版本详情，避免向其他账号泄露当前最高版本。
	// 对已成功解析的 main.json，非法版本使用稳定的 invalid_version 契约，
	// 而不是降级为普通安全扫描拒绝。
	if summary.JSON != "" {
		if _, err := version.Parse(summary.Version); err != nil {
			return store.Game{}, err
		}
	}
	report.Passed = len(report.Findings) == 0
	if !report.Passed {
		return s.reject(hash, report)
	}
	summary.Author = user.DisplayName
	var manifest map[string]any
	if err := json.Unmarshal([]byte(summary.JSON), &manifest); err != nil {
		return store.Game{}, &InputError{Reason: "main.json 无法规范化"}
	}
	manifest["author"] = user.DisplayName
	canonical, _ := json.Marshal(manifest)
	summary.JSON = string(canonical)
	rewrittenPath, err := s.rewriteArchiveManifest(
		tempPath,
		canonical,
		len(summary.Icon) != 0,
	)
	if err != nil {
		return store.Game{}, err
	}
	defer s.removeTemporaryFile(rewrittenPath, "normalized upload")
	normalizedHash, err := fileSHA256(rewrittenPath)
	if err != nil {
		return store.Game{}, err
	}
	archiveInfo, err := os.Stat(rewrittenPath)
	if err != nil {
		return store.Game{}, fmt.Errorf("读取规范化游戏包大小: %w", err)
	}
	report.SHA256 = normalizedHash
	storedPath, err := s.persistArchive(rewrittenPath, normalizedHash)
	if err != nil {
		return store.Game{}, err
	}
	iconPath, err := s.persistIcon(summary.Icon, normalizedHash)
	if err != nil {
		cleanupErr := DeleteStoredFiles(
			s.config.Storage.GamesDirectory, storedPath,
		)
		s.logUploadCleanupFailure("persist icon", cleanupErr)
		return store.Game{}, errors.Join(err, cleanupErr)
	}
	reportJSON, _ := json.Marshal(report)
	game, err := s.store.CreateOwnedGame(ctx, store.CreateGameInput{
		PackageID: summary.ID, Name: summary.Name, Author: summary.Author,
		Version: summary.Version, Remarks: summary.Remarks, TagsText: summary.TagsText,
		OwnerUserID: user.ID, Status: store.StatusPending, OriginalFilename: filename,
		StoredPath: storedPath, PackageSizeBytes: archiveInfo.Size(), IconPath: iconPath,
		ManifestJSON: summary.JSON, ScanStatus: "clean",
		ScanReport: string(reportJSON),
	})
	if err != nil {
		cleanupErr := DeleteStoredFiles(
			s.config.Storage.GamesDirectory, storedPath, iconPath,
		)
		s.logUploadCleanupFailure("persist database record", cleanupErr)
		return store.Game{}, errors.Join(err, cleanupErr)
	}
	return game, nil
}

func (s *Service) reject(hash string, report ScanReport) (store.Game, error) {
	report.Passed = false
	reason := truncateText(strings.Join(report.Findings, "；"), maxFindingBytes)
	if reason == "" {
		reason = "安全扫描未通过"
	}
	_ = hash
	return store.Game{}, &RejectedError{Reason: reason}
}

func (s *Service) scanClamAV(
	parent context.Context,
	filePath string,
) (status string, detail string, finding string) {
	if !s.config.Scanner.Enabled {
		return "disabled", "ClamAV 已通过 PLAYMESH_CLAMAV_ENABLED 关闭", ""
	}
	timeout := time.Duration(s.config.Scanner.TimeoutSeconds) * time.Second
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	// #nosec G204 -- Validate only accepts clamscan(.exe), arguments are
	// fixed, the archive path is server-generated, and no shell is used.
	command := exec.CommandContext(
		ctx,
		s.config.Scanner.ClamScanPath,
		"--infected",
		"--no-summary",
		filePath,
	)
	output, err := command.CombinedOutput()
	detail = strings.TrimSpace(string(output))
	if err == nil {
		return "clean", detail, ""
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) && exitError.ExitCode() == 1 {
		return "infected", detail, "ClamAV 检测到恶意内容"
	}
	if !s.config.Scanner.Required && errors.Is(err, exec.ErrNotFound) {
		return "skipped", err.Error(), ""
	}
	if ctx.Err() == context.DeadlineExceeded {
		return "error", detail, "ClamAV 扫描超时"
	}
	return "error", strings.TrimSpace(detail + " " + err.Error()), "ClamAV 扫描不可用或执行失败"
}

func (s *Service) inspectArchive(filePath string) (manifestSummary, []string) {
	info, err := os.Stat(filePath)
	if err != nil {
		return manifestSummary{}, []string{"无法读取隔离文件"}
	}
	reader, err := zip.OpenReader(filePath)
	if err != nil {
		return manifestSummary{}, []string{"文件不是有效 ZIP 压缩包"}
	}
	defer reader.Close()
	findings := make([]string, 0)
	if len(reader.File) > s.config.Storage.MaxFiles {
		return manifestSummary{}, []string{"ZIP 条目数量超过上限"}
	}
	seen := make(map[string]struct{})
	var expanded uint64
	var manifestBytes []byte
	for _, entry := range reader.File {
		if len(findings) >= 32 {
			break
		}
		name, valid := safeArchivePath(entry.Name)
		if !valid {
			findings = append(findings, "ZIP 包含不安全路径: "+reportName(entry.Name))
			continue
		}
		collisionKey := strings.ToLower(name)
		if _, exists := seen[collisionKey]; exists {
			findings = append(findings, "ZIP 包含重复路径: "+name)
			continue
		}
		seen[collisionKey] = struct{}{}
		if entry.Flags&0x1 != 0 {
			findings = append(findings, "ZIP 包含加密文件: "+name)
			continue
		}
		if !allowedRoot(name) {
			findings = append(findings, "游戏包根目录包含未允许内容: "+name)
			continue
		}
		if isReservedAppPath(name) {
			findings = append(findings, "游戏包 app/ 一级目录使用平台保留名称: "+name)
			continue
		}
		if entry.FileInfo().IsDir() {
			continue
		}
		if entry.Mode()&os.ModeSymlink != 0 || !entry.Mode().IsRegular() {
			findings = append(findings, "ZIP 包含符号链接或特殊文件: "+name)
			continue
		}
		uncompressed := entry.UncompressedSize64
		compressed := entry.CompressedSize64
		// #nosec G115 -- Config.Validate requires all three limits to be
		// positive int64 values before Service is constructed.
		maxFile := uint64(s.config.Storage.MaxFileBytes)
		// #nosec G115 -- see the validated positive-limit invariant above.
		maxExpanded := uint64(s.config.Storage.MaxExpandedBytes)
		if uncompressed > maxExpanded || expanded > maxExpanded-uncompressed {
			findings = append(findings, "ZIP 展开后总大小超过上限")
			break
		}
		expanded += uncompressed
		if uncompressed > maxFile {
			findings = append(findings, "单文件展开大小超过上限: "+name)
		}
		// #nosec G115 -- see the validated positive-limit invariant above.
		maxRatio := uint64(s.config.Storage.MaxCompressionRatio)
		ratioExceeded := compressed > 0 &&
			(uncompressed/compressed > maxRatio ||
				uncompressed/compressed == maxRatio &&
					uncompressed%compressed != 0)
		if compressed == 0 && uncompressed > 0 || ratioExceeded {
			findings = append(findings, "可疑压缩比: "+name)
		}
		extension := strings.ToLower(path.Ext(name))
		if name == "icon.png" {
			// 图标不是可执行内容，解码失败或超限时按协议忽略而不拒绝整个包。
			continue
		}
		if name == "main.json" || isActiveText(extension) {
			readLimit := maxActiveTextBytes
			if name == "main.json" {
				readLimit = maxManifestBytes
			}
			content, err := readZipEntry(entry, readLimit)
			if err != nil {
				findings = append(findings, "活动文本或清单超过安全读取限制: "+name)
				continue
			}
			if name == "main.json" {
				manifestBytes = content
				continue
			}
			for _, issue := range s.scanActiveContent(name, content) {
				findings = append(findings, issue)
				if len(findings) >= 32 {
					break
				}
			}
		}
	}
	if info.Size() == 0 {
		findings = append(findings, "ZIP 文件为空")
	}
	if len(manifestBytes) == 0 {
		findings = append(findings, "ZIP 根目录缺少 main.json")
		return manifestSummary{}, uniqueStrings(findings)
	}
	summary, manifestFindings := parseManifest(manifestBytes)
	if summary.JSON != "" {
		manifestFindings = append(
			manifestFindings,
			validateDeclaredHTMLGameEntry(summary.JSON, reader.File)...,
		)
		manifestFindings = append(
			manifestFindings,
			s.scanActiveContent("main.json", []byte(summary.ScannableJSON))...,
		)
		manifestFindings = append(
			manifestFindings,
			s.scanManifestEntryQueries(summary.JSON)...,
		)
	}
	if iconEntry := findArchiveEntry(reader.File, "icon.png"); iconEntry != nil {
		if content, err := readZipEntry(iconEntry, maxRootIconBytes); err == nil &&
			isSafeRootIcon(content) {
			summary.Icon = content
		}
	}
	findings = append(findings, manifestFindings...)
	return summary, uniqueStrings(findings)
}

func isSafeRootIcon(content []byte) bool {
	if len(content) == 0 || int64(len(content)) > maxRootIconBytes {
		return false
	}
	decoded, err := png.DecodeConfig(bytes.NewReader(content))
	if err != nil || decoded.Width < 1 || decoded.Height < 1 ||
		decoded.Width > maxRootIconEdge || decoded.Height > maxRootIconEdge ||
		int64(decoded.Width)*int64(decoded.Height) > maxRootIconPixels {
		return false
	}
	_, err = png.Decode(bytes.NewReader(content))
	return err == nil
}

func (s *Service) persistArchive(source string, hash string) (string, error) {
	random, err := randomHex(8)
	if err != nil {
		return "", err
	}
	finalName := fmt.Sprintf(
		"%d-%s-%s.zip", time.Now().UnixMilli(), shortHash(hash), random,
	)
	tempName := finalName + ".tmp"
	quarantineRoot, err := os.OpenRoot(s.config.Storage.QuarantineDirectory)
	if err != nil {
		return "", err
	}
	defer quarantineRoot.Close()
	input, err := quarantineRoot.Open(filepath.Base(source))
	if err != nil {
		return "", err
	}
	defer input.Close()
	gamesRoot, err := os.OpenRoot(s.config.Storage.GamesDirectory)
	if err != nil {
		return "", err
	}
	defer gamesRoot.Close()
	output, err := gamesRoot.OpenFile(
		tempName, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600,
	)
	if err != nil {
		return "", err
	}
	cleanup := func() error {
		closeErr := output.Close()
		if errors.Is(closeErr, os.ErrClosed) {
			closeErr = nil
		}
		removeErr := gamesRoot.Remove(tempName)
		if errors.Is(removeErr, os.ErrNotExist) {
			removeErr = nil
		}
		return errors.Join(closeErr, removeErr)
	}
	if _, err := io.Copy(output, input); err != nil {
		return "", errors.Join(err, cleanup())
	}
	if err := output.Sync(); err != nil {
		return "", errors.Join(err, cleanup())
	}
	if err := output.Close(); err != nil {
		removeErr := gamesRoot.Remove(tempName)
		if errors.Is(removeErr, os.ErrNotExist) {
			removeErr = nil
		}
		return "", errors.Join(err, removeErr)
	}
	if err := gamesRoot.Rename(tempName, finalName); err != nil {
		removeErr := gamesRoot.Remove(tempName)
		if errors.Is(removeErr, os.ErrNotExist) {
			removeErr = nil
		}
		return "", errors.Join(err, removeErr)
	}
	return filepath.Join(s.config.Storage.GamesDirectory, finalName), nil
}

func (s *Service) persistIcon(content []byte, hash string) (string, error) {
	if len(content) == 0 {
		return "", nil
	}
	random, err := randomHex(8)
	if err != nil {
		return "", err
	}
	finalName := fmt.Sprintf("%d-%s-%s.png", time.Now().UnixMilli(), shortHash(hash), random)
	tempName := finalName + ".tmp"
	root, err := os.OpenRoot(s.config.Storage.GamesDirectory)
	if err != nil {
		return "", err
	}
	defer root.Close()
	output, err := root.OpenFile(tempName, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return "", err
	}
	cleanup := func() error {
		closeErr := output.Close()
		if errors.Is(closeErr, os.ErrClosed) {
			closeErr = nil
		}
		removeErr := root.Remove(tempName)
		if errors.Is(removeErr, os.ErrNotExist) {
			removeErr = nil
		}
		return errors.Join(closeErr, removeErr)
	}
	if _, err := output.Write(content); err != nil {
		return "", errors.Join(err, cleanup())
	}
	if err := output.Sync(); err != nil {
		return "", errors.Join(err, cleanup())
	}
	if err := output.Close(); err != nil {
		removeErr := root.Remove(tempName)
		if errors.Is(removeErr, os.ErrNotExist) {
			removeErr = nil
		}
		return "", errors.Join(err, removeErr)
	}
	if err := root.Rename(tempName, finalName); err != nil {
		removeErr := root.Remove(tempName)
		if errors.Is(removeErr, os.ErrNotExist) {
			removeErr = nil
		}
		return "", errors.Join(err, removeErr)
	}
	return filepath.Join(s.config.Storage.GamesDirectory, finalName), nil
}

func (s *Service) rewriteArchiveManifest(
	source string,
	manifest []byte,
	keepRootIcon bool,
) (string, error) {
	reader, err := zip.OpenReader(source)
	if err != nil {
		return "", err
	}
	defer reader.Close()
	output, err := os.CreateTemp(s.config.Storage.QuarantineDirectory, "normalized-*.zip")
	if err != nil {
		return "", err
	}
	outputPath := output.Name()
	cleanup := func() error {
		closeErr := output.Close()
		if errors.Is(closeErr, os.ErrClosed) {
			closeErr = nil
		}
		removeErr := os.Remove(outputPath)
		if errors.Is(removeErr, os.ErrNotExist) {
			removeErr = nil
		}
		return errors.Join(closeErr, removeErr)
	}
	writer := zip.NewWriter(output)
	for _, entry := range reader.File {
		if entry.Name == "icon.png" && !keepRootIcon {
			continue
		}
		header := entry.FileHeader
		target, err := writer.CreateHeader(&header)
		if err != nil {
			return "", errors.Join(err, cleanup())
		}
		if entry.Name == "main.json" {
			if _, err := target.Write(manifest); err != nil {
				return "", errors.Join(err, cleanup())
			}
			continue
		}
		input, err := entry.Open()
		if err != nil {
			return "", errors.Join(err, cleanup())
		}
		_, copyErr := io.Copy(target, input)
		closeErr := input.Close()
		if copyErr != nil || closeErr != nil {
			if copyErr != nil {
				return "", errors.Join(copyErr, cleanup())
			}
			return "", errors.Join(closeErr, cleanup())
		}
	}
	if err := writer.Close(); err != nil {
		return "", errors.Join(err, cleanup())
	}
	if err := output.Sync(); err != nil {
		return "", errors.Join(err, cleanup())
	}
	if err := output.Close(); err != nil {
		removeErr := os.Remove(outputPath)
		if errors.Is(removeErr, os.ErrNotExist) {
			removeErr = nil
		}
		return "", errors.Join(err, removeErr)
	}
	return outputPath, nil
}

func safeArchivePath(name string) (string, bool) {
	if name == "" || len(name) > maxArchivePathBytes || strings.ContainsRune(name, '\x00') ||
		strings.Contains(name, "\\") || strings.HasPrefix(name, "/") ||
		strings.Contains(name, "%") {
		return "", false
	}
	cleaned := path.Clean(name)
	if cleaned == "." || cleaned != strings.TrimSuffix(name, "/") ||
		cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return "", false
	}
	for _, segment := range strings.Split(cleaned, "/") {
		if segment == "" || len(segment) > 255 || strings.HasPrefix(segment, ".") ||
			strings.Contains(segment, ":") || strings.TrimRight(segment, ". ") != segment ||
			hasControlCharacter(segment) || isWindowsDeviceName(segment) {
			return "", false
		}
	}
	return cleaned, true
}

func allowedRoot(name string) bool {
	return name == "main.json" || name == "capabilities.json" || name == "icon.png" ||
		name == "app" || strings.HasPrefix(name, "app/")
}

func isReservedAppPath(name string) bool {
	segments := strings.Split(name, "/")
	if len(segments) < 2 || !strings.EqualFold(segments[0], "app") {
		return false
	}
	return strings.EqualFold(segments[1], "playmesh") ||
		strings.EqualFold(segments[1], "bucket")
}

func findArchiveEntry(entries []*zip.File, name string) *zip.File {
	for _, entry := range entries {
		if entry.Name == name && !entry.FileInfo().IsDir() {
			return entry
		}
	}
	return nil
}

func isActiveText(extension string) bool {
	switch extension {
	case ".html", ".htm", ".js", ".mjs", ".css", ".svg":
		return true
	default:
		return false
	}
}

func isUsableHTMLText(content []byte) bool {
	content = bytes.TrimPrefix(content, []byte{0xef, 0xbb, 0xbf})
	return utf8.Valid(content) &&
		!bytes.ContainsRune(content, '\x00') &&
		len(bytes.TrimSpace(content)) > 0
}

func validateDeclaredHTMLGameEntry(
	canonicalManifest string,
	archiveEntries []*zip.File,
) []string {
	var manifest map[string]any
	if err := json.Unmarshal([]byte(canonicalManifest), &manifest); err != nil {
		return nil
	}
	entries, ok := manifest["entries"].(map[string]any)
	if !ok {
		return []string{"main.json.entries.game 缺失或不是字符串"}
	}
	rawEntry, ok := entries["game"].(string)
	if !ok || strings.TrimSpace(rawEntry) != rawEntry || rawEntry == "" {
		return []string{"main.json.entries.game 缺失或不是字符串"}
	}
	entryPath, _, _ := strings.Cut(rawEntry, "?")
	if strings.ToLower(path.Ext(entryPath)) != ".html" {
		return []string{"main.json.entries.game 必须声明 HTML 网页入口"}
	}
	physicalPath := "app/" + entryPath
	entry := findArchiveEntry(archiveEntries, physicalPath)
	if entry == nil {
		return []string{"main.json.entries.game 对应网页入口不存在: " + physicalPath}
	}
	content, err := readZipEntry(entry, maxActiveTextBytes)
	if err != nil || !isUsableHTMLText(content) {
		return []string{"main.json.entries.game 对应入口不是非空 UTF-8 网页文本: " + physicalPath}
	}
	return nil
}

func hasControlCharacter(value string) bool {
	for _, character := range value {
		if character < 0x20 || character == 0x7f {
			return true
		}
	}
	return false
}

func isWindowsDeviceName(value string) bool {
	base := strings.ToUpper(strings.SplitN(value, ".", 2)[0])
	switch base {
	case "CON", "PRN", "AUX", "NUL":
		return true
	}
	if len(base) == 4 && (strings.HasPrefix(base, "COM") ||
		strings.HasPrefix(base, "LPT")) && base[3] >= '1' && base[3] <= '9' {
		return true
	}
	return false
}

func readZipEntry(entry *zip.File, limit int64) ([]byte, error) {
	if limit < 0 || entry.UncompressedSize64 > uint64(limit) {
		return nil, errors.New("文件过大")
	}
	reader, err := entry.Open()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	content, err := io.ReadAll(io.LimitReader(reader, limit+1))
	if err != nil || int64(len(content)) > limit {
		return nil, errors.New("文件读取超过限制")
	}
	return content, nil
}

func (s *Service) scanActiveContent(name string, content []byte) []string {
	text := string(content)
	findings := make([]string, 0)
	extension := strings.ToLower(path.Ext(name))
	for _, rule := range s.contentRules {
		if len(rule.extensions) > 0 {
			if _, applies := rule.extensions[extension]; !applies {
				continue
			}
		}
		if rule.pattern.MatchString(text) {
			findings = append(findings,
				rule.description+" ["+rule.id+"]: "+name)
		}
	}
	return findings
}

func parseManifest(content []byte) (manifestSummary, []string) {
	var manifest map[string]any
	if err := json.Unmarshal(content, &manifest); err != nil {
		return manifestSummary{}, []string{"main.json 不是有效 JSON"}
	}
	canonical, _ := json.Marshal(manifest)
	scannable, _ := json.Marshal(projectScannableManifest(manifest))
	summary := manifestSummary{
		ID: exactStringField(manifest, "id"), Name: stringField(manifest, "name"),
		Author: stringField(manifest, "author"), Version: exactStringField(manifest, "version"),
		Remarks: stringField(manifest, "remarks"), JSON: string(canonical),
		ScannableJSON: string(scannable),
	}
	findings := make([]string, 0)
	if !gameid.Valid(summary.ID) {
		findings = append(findings, "main.json.id 缺失或格式无效")
	}
	if summary.Name == "" || len([]rune(summary.Name)) > 120 {
		findings = append(findings, "main.json.name 缺失或过长")
	}
	if _, err := version.Parse(summary.Version); err != nil {
		findings = append(findings, "main.json.version 必须是无前缀的 MAJOR.MINOR.PATCH")
	}
	tags, _ := manifest["tags"].([]any)
	tagValues := make([]string, 0, len(tags))
	for _, value := range tags {
		if text, ok := value.(string); ok && text != "" &&
			len([]rune(text)) <= maxGameTagRunes && len(tagValues) < maxGameTagCount {
			tagValues = append(tagValues, text)
		}
	}
	summary.TagsText = strings.Join(tagValues, ",")
	return summary, findings
}

// scanManifestEntryQueries keeps the encoded-content security check for entry
// query strings without treating the current manifest shape as an upload
// contract. Missing fields, new SDK versions and future entry structures are
// intentionally left to the consuming client, which owns runtime compatibility.
func (s *Service) scanManifestEntryQueries(canonicalManifest string) []string {
	var manifest map[string]any
	if err := json.Unmarshal([]byte(canonicalManifest), &manifest); err != nil {
		return nil
	}
	findings := make([]string, 0)
	entries, ok := manifest["entries"].(map[string]any)
	if !ok {
		return findings
	}
	for _, field := range []string{"game", "controller"} {
		entry, ok := entries[field].(string)
		if !ok {
			continue
		}
		_, rawQuery, hasQuery := strings.Cut(entry, "?")
		if !hasQuery || rawQuery == "" {
			continue
		}
		findings = append(
			findings,
			s.scanManifestHTMLQuery(
				"main.json.entries."+field,
				rawQuery,
			)...,
		)
	}
	return uniqueStrings(findings)
}

func (s *Service) scanManifestHTMLQuery(
	pathName string,
	rawQuery string,
) []string {
	if rawQuery == "" {
		return nil
	}
	findings := make([]string, 0)
	current := rawQuery
	// Each successful percent decode shortens the text. The entry length limit
	// therefore gives this loop a strict upper bound while still detecting any
	// number of encoding layers that can fit in main.json.
	for layer := 0; layer <= len(rawQuery); layer++ {
		for _, rule := range s.contentRules {
			if len(rule.extensions) > 0 {
				if _, applies := rule.extensions[".html"]; !applies {
					continue
				}
			}
			if rule.pattern.MatchString(current) {
				findings = append(
					findings,
					rule.description+" ["+rule.id+"]: "+
						pathName+" 查询参数",
				)
			}
		}
		decoded := unescapeQueryLayer(current)
		if decoded == current {
			break
		}
		current = decoded
	}
	return uniqueStrings(findings)
}

func unescapeQueryLayer(value string) string {
	var output strings.Builder
	output.Grow(len(value))
	changed := false
	for index := 0; index < len(value); {
		switch {
		case value[index] == '%' && index+2 < len(value):
			high, highOK := hexNibble(value[index+1])
			low, lowOK := hexNibble(value[index+2])
			if highOK && lowOK {
				output.WriteByte(high<<4 | low)
				index += 3
				changed = true
				continue
			}
			output.WriteByte(value[index])
			index++
		case value[index] == '+':
			output.WriteByte(' ')
			index++
			changed = true
		default:
			output.WriteByte(value[index])
			index++
		}
	}
	if !changed {
		return value
	}
	return output.String()
}

func hexNibble(value byte) (byte, bool) {
	switch {
	case value >= '0' && value <= '9':
		return value - '0', true
	case value >= 'a' && value <= 'f':
		return value - 'a' + 10, true
	case value >= 'A' && value <= 'F':
		return value - 'A' + 10, true
	default:
		return 0, false
	}
}

func projectScannableManifest(source map[string]any) map[string]any {
	projected := make(map[string]any, len(scannableManifestFields))
	for _, field := range scannableManifestFields {
		value, exists := source[field]
		if !exists {
			continue
		}
		if objectFields, nested := scannableManifestObjectFields[field]; nested {
			value = projectScannableManifestObject(value, objectFields)
		}
		projected[field] = value
	}
	return projected
}

func projectScannableManifestObject(value any, fields []string) any {
	source, ok := value.(map[string]any)
	if !ok {
		return value
	}
	projected := make(map[string]any, len(fields))
	for _, field := range fields {
		if fieldValue, exists := source[field]; exists {
			projected[field] = fieldValue
		}
	}
	return projected
}

func stringField(object map[string]any, name string) string {
	value, _ := object[name].(string)
	return strings.TrimSpace(value)
}

func exactStringField(object map[string]any, name string) string {
	value, _ := object[name].(string)
	return value
}

func randomHex(size int) (string, error) {
	value := make([]byte, size)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
}

func fileSHA256(filePath string) (string, error) {
	input, err := os.Open(filePath)
	if err != nil {
		return "", err
	}
	defer input.Close()
	hasher := sha256.New()
	if _, err := io.Copy(hasher, input); err != nil {
		return "", err
	}
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func shortHash(value string) string {
	if len(value) > 16 {
		return value[:16]
	}
	if value == "" {
		random, _ := randomHex(8)
		return random
	}
	return value
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]struct{})
	result := make([]string, 0, len(values))
	for _, value := range values {
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func reportName(value string) string {
	return truncateText(strings.ReplaceAll(value, "\x00", "�"), 200)
}

func truncateText(value string, maximum int) string {
	if len(value) <= maximum {
		return value
	}
	return value[:maximum] + "…"
}

// ResolveStoredArchive treats database paths as untrusted input. It resolves
// symlinks and requires the target to remain a regular ZIP below gamesRoot.
func ResolveStoredArchive(gamesRoot, candidate string) (string, error) {
	return resolveStoredFile(gamesRoot, candidate, ".zip")
}

func ResolveStoredIcon(gamesRoot, candidate string) (string, error) {
	return resolveStoredFile(gamesRoot, candidate, ".png")
}

func DeleteStoredFiles(gamesRoot string, candidates ...string) error {
	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		var resolved string
		var err error
		switch strings.ToLower(filepath.Ext(candidate)) {
		case ".zip":
			resolved, err = ResolveStoredArchive(gamesRoot, candidate)
		case ".png":
			resolved, err = ResolveStoredIcon(gamesRoot, candidate)
		default:
			err = errors.New("存储文件扩展名无效")
		}
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if err := os.Remove(resolved); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

func resolveStoredFile(gamesRoot, candidate string, extension string) (string, error) {
	if strings.TrimSpace(candidate) == "" {
		return "", errors.New("存储路径为空")
	}
	root, err := filepath.Abs(filepath.Clean(gamesRoot))
	if err != nil {
		return "", err
	}
	target, err := filepath.Abs(filepath.Clean(candidate))
	if err != nil || !pathWithin(root, target) {
		return "", errors.New("游戏包路径越过存储目录")
	}
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	target, err = filepath.EvalSymlinks(target)
	if errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if err != nil || !pathWithin(root, target) {
		return "", errors.New("游戏包符号链接越过存储目录")
	}
	info, err := os.Lstat(target)
	if errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return "", errors.New("游戏包不是常规文件")
	}
	if !strings.EqualFold(filepath.Ext(target), extension) {
		return "", errors.New("存储文件扩展名无效")
	}
	return target, nil
}

func pathWithin(root, target string) bool {
	relative, err := filepath.Rel(root, target)
	if err != nil || filepath.IsAbs(relative) {
		return false
	}
	return relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}
