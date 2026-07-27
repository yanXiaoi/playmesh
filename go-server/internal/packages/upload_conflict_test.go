package packages

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"image"
	"image/png"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"go-server/internal/config"
	"go-server/internal/mailer"
	"go-server/internal/store"
	"go-server/internal/version"
)

func TestManifestGameIDUsesUnifiedSafeBounds(t *testing.T) {
	for _, value := range []string{"a", strings.Repeat("a", 64)} {
		_, findings := parseManifest([]byte(
			`{"id":"` + value + `","name":"Game","version":"1.0.0"}`,
		))
		if containsFinding(findings, "main.json.id") {
			t.Fatalf("合法 gameId %q 被拒绝: %#v", value, findings)
		}
	}
	for _, value := range []string{
		"",
		" a ",
		"../escape",
		"a/b",
		strings.Repeat("a", 65),
	} {
		_, findings := parseManifest([]byte(
			`{"id":"` + value + `","name":"Game","version":"1.0.0"}`,
		))
		if !containsFinding(findings, "main.json.id") {
			t.Fatalf("非法 gameId %q 未被拒绝: %#v", value, findings)
		}
	}
}

func TestManifestParserProjectsOnlyKnownFields(t *testing.T) {
	summary, findings := parseManifest([]byte(
		`{"id":"com.example.game","name":"Game","version":"1.0.0",` +
			`"players":{"min":1,"max":2,"extraNested":"ignored"},` +
			`"permissions":["http://ignored.example"],` +
			`"icon":"javascript:ignored","extra":"http://ignored.example"}`,
	))
	if len(findings) != 0 {
		t.Fatalf("未知字段不应触发校验: %#v", findings)
	}
	for _, unknown := range []string{
		`"permissions":["http://ignored.example"]`,
		`"icon":"javascript:ignored"`,
		`"extra":"http://ignored.example"`,
		`"extraNested":"ignored"`,
	} {
		if strings.Contains(summary.JSON, unknown) {
			t.Fatalf("已知字段投影保留了未知字段 %s: %s", unknown, summary.JSON)
		}
	}
	for _, known := range []string{
		`"id":"com.example.game"`,
		`"name":"Game"`,
		`"version":"1.0.0"`,
		`"players":{"max":2,"min":1}`,
	} {
		if !strings.Contains(summary.JSON, known) {
			t.Fatalf("已知字段投影丢失 %s: %s", known, summary.JSON)
		}
	}
}

func TestUserUploadConflictsLeaveNoStoredOrQuarantineResidue(t *testing.T) {
	root := t.TempDir()
	cfg := config.Default()
	cfg.Storage.DatabasePath = filepath.Join(root, "server.db")
	cfg.Storage.GamesDirectory = filepath.Join(root, "games")
	cfg.Storage.QuarantineDirectory = filepath.Join(root, "quarantine")
	cfg.Scanner.Enabled = false
	database, err := store.Open(cfg.Storage, store.Settings{})
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	ctx := context.Background()
	firstOwner, err := database.CreateUser(
		ctx,
		"first@example.com",
		"hash",
		"active",
	)
	if err != nil {
		t.Fatal(err)
	}
	firstOwner, err = database.UpdateDisplayName(
		ctx,
		firstOwner.ID,
		"原样发布者 API Name",
	)
	if err != nil {
		t.Fatal(err)
	}
	secondOwner, err := database.CreateUser(
		ctx,
		"second@example.com",
		"hash",
		"active",
	)
	if err != nil {
		t.Fatal(err)
	}
	service := New(
		cfg,
		database,
		mailer.New(config.Mail{}),
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)

	icon := testRootIcon(t)
	firstFile := buildTestPackageArchive(
		t,
		`{"id":"com.example.conflict","name":"动态游戏名称","author":"包内伪造发布者",`+
			`"version":"1.0.0","remarks":"动态简介","tags":["动态标签"],`+
			`"permissions":["http://ignored.example"],`+
			`"icon":"javascript:ignored","extra":"http://ignored.example"}`,
		icon,
	)
	first, err := service.ProcessUserUpload(
		ctx,
		firstFile,
		"dynamic-game.zip",
		firstOwner,
	)
	_ = firstFile.Close()
	if err != nil {
		t.Fatal(err)
	}
	if first.Name != "动态游戏名称" ||
		first.Author != "原样发布者 API Name" ||
		first.Version != "1.0.0" {
		t.Fatalf("首个上传结果 = %#v", first)
	}
	if first.IconPath == "" {
		t.Fatal("包根 icon.png 未持久化")
	}
	assertNormalizedManifest(t, first)
	assertUploadFileCounts(t, cfg.Storage, 2, 0)

	_, err = processTestPackageWithError(
		t,
		service,
		secondOwner,
		"1.2",
	)
	if !errors.Is(err, store.ErrOwnershipConflict) {
		t.Fatalf("非法版本必须先执行所有权预检，错误 = %v", err)
	}
	assertUploadFileCounts(t, cfg.Storage, 2, 0)

	_, err = processTestPackageWithError(
		t,
		service,
		firstOwner,
		"1.2",
	)
	if !errors.Is(err, version.ErrInvalid) {
		t.Fatalf("所有者非法版本错误 = %v", err)
	}
	assertUploadFileCounts(t, cfg.Storage, 2, 0)

	_, err = processTestPackageWithError(
		t,
		service,
		secondOwner,
		"2.0.0",
	)
	if !errors.Is(err, store.ErrOwnershipConflict) {
		t.Fatalf("其他账号抢占错误 = %v", err)
	}
	assertUploadFileCounts(t, cfg.Storage, 2, 0)

	_, err = processTestPackageWithError(
		t,
		service,
		firstOwner,
		"1.0.0",
	)
	if !errors.Is(err, store.ErrVersionAlreadyExists) {
		t.Fatalf("同版本错误 = %v", err)
	}
	assertUploadFileCounts(t, cfg.Storage, 2, 0)

	_, err = processTestPackageWithError(
		t,
		service,
		firstOwner,
		"0.9.0",
	)
	if !errors.Is(err, store.ErrVersionMustIncrease) {
		t.Fatalf("低版本错误 = %v", err)
	}
	assertUploadFileCounts(t, cfg.Storage, 2, 0)

	firstOwnerGames, err := database.ListUserGames(ctx, firstOwner.ID)
	if err != nil {
		t.Fatal(err)
	}
	secondOwnerGames, err := database.ListUserGames(ctx, secondOwner.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(firstOwnerGames) != 1 || len(secondOwnerGames) != 0 {
		t.Fatalf(
			"冲突后的数据库记录 first=%#v second=%#v",
			firstOwnerGames,
			secondOwnerGames,
		)
	}
}

func containsFinding(findings []string, prefix string) bool {
	for _, finding := range findings {
		if strings.HasPrefix(finding, prefix) {
			return true
		}
	}
	return false
}

func processTestPackage(
	t *testing.T,
	service *Service,
	owner store.User,
	version string,
) store.Game {
	t.Helper()
	game, err := processTestPackageWithError(t, service, owner, version)
	if err != nil {
		t.Fatal(err)
	}
	return game
}

func processTestPackageWithError(
	t *testing.T,
	service *Service,
	owner store.User,
	version string,
) (store.Game, error) {
	t.Helper()
	file := buildTestPackage(t, version)
	defer file.Close()
	return service.ProcessUserUpload(
		context.Background(),
		file,
		"dynamic-game.zip",
		owner,
	)
}

func buildTestPackage(t *testing.T, version string) *os.File {
	t.Helper()
	return buildTestPackageWithManifest(
		t,
		`{"id":"com.example.conflict","name":"动态游戏名称","author":"包内伪造发布者","version":"`+
			version+`","remarks":"动态简介","tags":["动态标签"]}`,
	)
}

func buildTestPackageWithManifest(t *testing.T, manifest string) *os.File {
	t.Helper()
	return buildTestPackageArchive(t, manifest, nil)
}

func buildTestPackageArchive(
	t *testing.T,
	manifest string,
	rootIcon []byte,
) *os.File {
	t.Helper()
	file, err := os.CreateTemp(t.TempDir(), "package-*.zip")
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	entries := map[string][]byte{
		"main.json":      []byte(manifest),
		"app/index.html": []byte("<!doctype html><title>Dynamic Game</title>"),
	}
	if len(rootIcon) > 0 {
		entries["icon.png"] = rootIcon
	}
	for name, content := range entries {
		header := &zip.FileHeader{Name: name, Method: zip.Store}
		entry, err := writer.CreateHeader(header)
		if err != nil {
			_ = file.Close()
			t.Fatal(err)
		}
		if _, err := entry.Write(content); err != nil {
			_ = file.Close()
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	return file
}

func testRootIcon(t *testing.T) []byte {
	t.Helper()
	var output bytes.Buffer
	icon := image.NewRGBA(image.Rect(0, 0, 1, 1))
	icon.Pix = []byte{0x18, 0xA8, 0xC9, 0xFF}
	if err := png.Encode(&output, icon); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}

func assertNormalizedManifest(t *testing.T, game store.Game) {
	t.Helper()
	for _, forbidden := range []string{`"permissions"`, `"icon"`, `"extra"`} {
		if strings.Contains(game.ManifestJSON, forbidden) {
			t.Fatalf("数据库 Manifest 已知字段投影仍包含 %s: %s", forbidden, game.ManifestJSON)
		}
	}
	if !strings.Contains(game.ManifestJSON, `"author":"原样发布者 API Name"`) {
		t.Fatalf("数据库 Manifest 丢失平台发布者: %s", game.ManifestJSON)
	}
	archive, err := zip.OpenReader(game.StoredPath)
	if err != nil {
		t.Fatal(err)
	}
	defer archive.Close()
	manifestEntry := findArchiveEntry(archive.File, "main.json")
	iconEntry := findArchiveEntry(archive.File, "icon.png")
	if manifestEntry == nil || iconEntry == nil {
		t.Fatalf("规范化 ZIP 缺少 main.json 或根 icon.png")
	}
	content, err := readZipEntry(manifestEntry, maxManifestBytes)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{`"permissions"`, `"icon"`, `"extra"`} {
		if strings.Contains(string(content), forbidden) {
			t.Fatalf("规范化 ZIP 已知字段投影仍包含 %s: %s", forbidden, content)
		}
	}
	if !strings.Contains(string(content), `"author":"原样发布者 API Name"`) {
		t.Fatalf("规范化 ZIP 丢失平台发布者: %s", content)
	}
}

func assertUploadFileCounts(
	t *testing.T,
	storage config.Storage,
	wantGames int,
	wantQuarantine int,
) {
	t.Helper()
	countFiles := func(root string) int {
		count := 0
		err := filepath.WalkDir(root, func(
			_ string,
			entry os.DirEntry,
			err error,
		) error {
			if err != nil {
				return err
			}
			if !entry.IsDir() {
				count++
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		return count
	}
	if games := countFiles(storage.GamesDirectory); games != wantGames {
		t.Fatalf("games 文件数 = %d, want %d", games, wantGames)
	}
	if quarantine := countFiles(storage.QuarantineDirectory); quarantine != wantQuarantine {
		t.Fatalf(
			"quarantine 文件数 = %d, want %d",
			quarantine,
			wantQuarantine,
		)
	}
}
