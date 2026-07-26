package packages

import (
	"archive/zip"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime/multipart"
	"net/mail"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"go-server/internal/config"
	"go-server/internal/mailer"
	"go-server/internal/store"
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

func (e *InputError) Error() string {
	return e.Reason
}

const (
	maxManifestBytes    int64 = 256 << 10
	maxActiveTextBytes  int64 = 4 << 20
	maxFindingBytes           = 8 << 10
	maxArchivePathBytes       = 512
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
	ID       string
	Name     string
	Author   string
	Version  string
	Remarks  string
	TagsText string
	JSON     string
}

type Service struct {
	config       config.Config
	store        *store.Store
	mailer       *mailer.Mailer
	logger       *slog.Logger
	contentRules []compiledContentRule
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

func (s *Service) ProcessUpload(
	ctx context.Context,
	file multipart.File,
	filename string,
	email string,
) (store.Game, error) {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	filename = filepath.Base(strings.TrimSpace(filename))
	if filename == "." || len(filename) > 255 || strings.ContainsRune(filename, '\x00') {
		return store.Game{}, &InputError{Reason: "上传文件名无效或过长"}
	}
	email = strings.TrimSpace(email)
	address, err := mail.ParseAddress(email)
	if err != nil || address.Address != email || len(email) > 320 {
		return store.Game{}, &InputError{Reason: "必须填写有效邮箱"}
	}
	if !strings.EqualFold(filepath.Ext(filename), ".zip") {
		return store.Game{}, &InputError{Reason: "只接受 .zip 标准游戏包"}
	}
	temp, err := os.CreateTemp(s.config.Storage.QuarantineDirectory, "upload-*.zip")
	if err != nil {
		return store.Game{}, fmt.Errorf("创建隔离文件: %w", err)
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
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
		return s.reject(ctx, filename, email, hash, manifestSummary{}, ScanReport{
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
	report.Passed = len(report.Findings) == 0
	if !report.Passed {
		return s.reject(ctx, filename, email, hash, summary, report)
	}

	storedPath, err := s.persistArchive(tempPath, hash)
	if err != nil {
		return store.Game{}, err
	}
	reportJSON, _ := json.Marshal(report)
	game, err := s.store.CreateGame(ctx, store.CreateGameInput{
		PackageID: summary.ID, Name: summary.Name, Author: summary.Author,
		Version: summary.Version, Remarks: summary.Remarks, TagsText: summary.TagsText,
		Email: email, Status: store.StatusPending, OriginalFilename: filename,
		StoredPath: storedPath, ManifestJSON: summary.JSON, ScanStatus: "clean",
		ScanReport: string(reportJSON),
	})
	if err != nil {
		_ = os.Remove(storedPath)
		return store.Game{}, err
	}
	return game, nil
}

func (s *Service) reject(
	ctx context.Context,
	filename string,
	email string,
	hash string,
	summary manifestSummary,
	report ScanReport,
) (store.Game, error) {
	report.Passed = false
	reason := truncateText(strings.Join(report.Findings, "；"), maxFindingBytes)
	if reason == "" {
		reason = "安全扫描未通过"
	}
	if summary.ID == "" {
		summary.ID = "rejected-" + shortHash(hash)
	}
	if summary.Name == "" {
		summary.Name = "未通过安全扫描的上传"
	}
	if summary.Version == "" {
		summary.Version = "unknown"
	}
	if summary.JSON == "" {
		summary.JSON = "{}"
	}
	reportJSON, _ := json.Marshal(report)
	game, err := s.store.CreateGame(ctx, store.CreateGameInput{
		PackageID: summary.ID, Name: summary.Name, Author: summary.Author,
		Version: summary.Version, Remarks: summary.Remarks, TagsText: summary.TagsText,
		Email: email, Status: store.StatusRejected, OriginalFilename: filename,
		ManifestJSON: summary.JSON, ScanStatus: "rejected",
		ScanReport: string(reportJSON), RejectionReason: reason,
	})
	if err != nil {
		return store.Game{}, err
	}
	if s.config.Mail.SendReviewFailures && s.mailer.Enabled() {
		if err := s.mailer.SendReviewResult(email, summary.Name, false, reason); err != nil {
			s.logger.Warn("发送安全扫描拒绝邮件失败",
				"gameId", game.ID, "error", err)
		}
	}
	return game, &RejectedError{Reason: reason, Game: game}
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
		if !allowedExtension(extension) {
			findings = append(findings, "不允许的文件类型: "+name)
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
	findings = append(findings, manifestFindings...)
	return summary, uniqueStrings(findings)
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
	cleanup := func() {
		_ = output.Close()
		_ = gamesRoot.Remove(tempName)
	}
	if _, err := io.Copy(output, input); err != nil {
		cleanup()
		return "", err
	}
	if err := output.Sync(); err != nil {
		cleanup()
		return "", err
	}
	if err := output.Close(); err != nil {
		_ = gamesRoot.Remove(tempName)
		return "", err
	}
	if err := gamesRoot.Rename(tempName, finalName); err != nil {
		_ = gamesRoot.Remove(tempName)
		return "", err
	}
	return filepath.Join(s.config.Storage.GamesDirectory, finalName), nil
}

func safeArchivePath(name string) (string, bool) {
	if name == "" || len(name) > maxArchivePathBytes || strings.ContainsRune(name, '\x00') ||
		strings.Contains(name, "\\") || strings.HasPrefix(name, "/") {
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
	return name == "main.json" || name == "capabilities.json" ||
		name == "app" || strings.HasPrefix(name, "app/")
}

func allowedExtension(extension string) bool {
	_, ok := map[string]struct{}{
		".html": {}, ".htm": {}, ".js": {}, ".mjs": {}, ".css": {},
		".json": {}, ".txt": {}, ".md": {}, ".map": {},
		".png": {}, ".jpg": {}, ".jpeg": {}, ".gif": {}, ".webp": {},
		".svg": {}, ".ico": {}, ".bmp": {},
		".mp3": {}, ".ogg": {}, ".wav": {}, ".m4a": {}, ".aac": {},
		".mp4": {}, ".webm": {},
		".woff": {}, ".woff2": {}, ".ttf": {}, ".otf": {},
	}[extension]
	return ok
}

func isActiveText(extension string) bool {
	switch extension {
	case ".html", ".htm", ".js", ".mjs", ".css", ".svg":
		return true
	default:
		return false
	}
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
	summary := manifestSummary{
		ID: stringField(manifest, "id"), Name: stringField(manifest, "name"),
		Author: stringField(manifest, "author"), Version: stringField(manifest, "version"),
		Remarks: stringField(manifest, "remarks"), JSON: string(canonical),
	}
	findings := make([]string, 0)
	if !regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$`).MatchString(summary.ID) {
		findings = append(findings, "main.json.id 缺失或格式无效")
	}
	if summary.Name == "" || len([]rune(summary.Name)) > 120 {
		findings = append(findings, "main.json.name 缺失或过长")
	}
	if summary.Version == "" || len(summary.Version) > 64 {
		findings = append(findings, "main.json.version 缺失或过长")
	}
	if len([]rune(summary.Author)) > 120 {
		findings = append(findings, "main.json.author 过长")
	}
	if len([]rune(summary.Remarks)) > 2000 {
		findings = append(findings, "main.json.remarks 过长")
	}
	tags, _ := manifest["tags"].([]any)
	if len(tags) > 64 {
		findings = append(findings, "main.json.tags 数量超过上限")
	}
	tagValues := make([]string, 0, len(tags))
	for _, value := range tags {
		if text, ok := value.(string); ok && text != "" &&
			len([]rune(text)) <= 64 && len(tagValues) < 64 {
			tagValues = append(tagValues, text)
		} else if ok && len([]rune(text)) > 64 {
			findings = append(findings, "main.json.tags 含有过长标签")
		}
	}
	summary.TagsText = strings.Join(tagValues, ",")
	return summary, findings
}

func stringField(object map[string]any, name string) string {
	value, _ := object[name].(string)
	return strings.TrimSpace(value)
}

func randomHex(size int) (string, error) {
	value := make([]byte, size)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
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
	if strings.TrimSpace(candidate) == "" {
		return "", errors.New("游戏包路径为空")
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
	if err != nil || !pathWithin(root, target) {
		return "", errors.New("游戏包符号链接越过存储目录")
	}
	info, err := os.Lstat(target)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return "", errors.New("游戏包不是常规文件")
	}
	if !strings.EqualFold(filepath.Ext(target), ".zip") {
		return "", errors.New("游戏包扩展名无效")
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
