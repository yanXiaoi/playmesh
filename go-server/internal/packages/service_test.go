package packages

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/png"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"go-server/internal/config"
	"go-server/internal/mailer"
	"go-server/internal/store"
)

func TestSafeRootIconRequiresCompletePngDecode(t *testing.T) {
	var encoded bytes.Buffer
	icon := image.NewRGBA(image.Rect(0, 0, 1, 1))
	icon.Pix = []byte{0x18, 0xA8, 0xC9, 0xFF}
	if err := png.Encode(&encoded, icon); err != nil {
		t.Fatal(err)
	}
	valid := encoded.Bytes()
	if !isSafeRootIcon(valid) {
		t.Fatal("complete PNG must be accepted")
	}
	if len(valid) < 33 {
		t.Fatalf("unexpected encoded PNG length: %d", len(valid))
	}
	configOnly := valid[:33]
	if _, err := png.DecodeConfig(bytes.NewReader(configOnly)); err != nil {
		t.Fatalf("test fixture must contain a valid PNG header: %v", err)
	}
	if isSafeRootIcon(configOnly) {
		t.Fatal("header-only PNG must be ignored because full decode fails")
	}
}

func TestDeleteStoredFilesRemovesFilesAndIsRetrySafe(t *testing.T) {
	root := t.TempDir()
	archive := filepath.Join(root, "game.zip")
	if err := os.WriteFile(archive, []byte("archive"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := DeleteStoredFiles(root, archive); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(archive); !os.IsNotExist(err) {
		t.Fatalf("删除后原文件仍可见: %v", err)
	}
	if err := DeleteStoredFiles(root, archive); err != nil {
		t.Fatal(err)
	}
}

func TestCleanupDeletingRetriesPersistedRecords(t *testing.T) {
	root := t.TempDir()
	storage := config.Storage{
		DatabasePath:        filepath.Join(root, "server.db"),
		GamesDirectory:      filepath.Join(root, "games"),
		QuarantineDirectory: filepath.Join(root, "quarantine"),
		MaxConcurrentScans:  1,
	}
	database, err := store.Open(storage, store.Settings{})
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	ctx := context.Background()
	owner, err := database.CreateUser(ctx, "owner@example.com", "hash", "active")
	if err != nil {
		t.Fatal(err)
	}
	archive := filepath.Join(storage.GamesDirectory, "game.zip")
	if err := os.WriteFile(archive, []byte("archive"), 0o600); err != nil {
		t.Fatal(err)
	}
	game, err := database.CreateOwnedGame(ctx, store.CreateGameInput{
		PackageID: "com.example.cleanup", Name: "Cleanup", Author: "Owner",
		Version: "1.0.0", OwnerUserID: owner.ID, Status: store.StatusPending,
		OriginalFilename: "game.zip", StoredPath: archive,
		ManifestJSON: `{"id":"com.example.cleanup","version":"1.0.0"}`,
		ScanStatus:   "clean", ScanReport: "{}",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.BeginDeleteOwnedGame(
		ctx, game.ID, store.UserReviewActor(owner.ID),
	); err != nil {
		t.Fatal(err)
	}
	service := New(
		config.Config{Storage: storage}, database, mailer.New(config.Mail{}),
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
	completed, err := service.CleanupDeleting(ctx)
	if err != nil || completed != 1 {
		t.Fatalf("后台清理 completed=%d err=%v", completed, err)
	}
	if _, err := database.GetGame(ctx, game.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("后台清理后记录仍存在: %v", err)
	}
	if _, err := os.Stat(archive); !os.IsNotExist(err) {
		t.Fatalf("后台清理后文件仍存在: %v", err)
	}
}

func TestCleanupDeletingRemovesOnlyUnreferencedGeneratedArtifacts(t *testing.T) {
	root := t.TempDir()
	storage := config.Storage{
		DatabasePath:        filepath.Join(root, "server.db"),
		GamesDirectory:      filepath.Join(root, "games"),
		QuarantineDirectory: filepath.Join(root, "quarantine"),
		MaxConcurrentScans:  1,
	}
	database, err := store.Open(storage, store.Settings{})
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	ctx := context.Background()
	owner, err := database.CreateUser(ctx, "owner@example.com", "hash", "active")
	if err != nil {
		t.Fatal(err)
	}
	referencedArchive := filepath.Join(
		storage.GamesDirectory,
		"1710000000000-aaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb.zip",
	)
	referencedIcon := filepath.Join(
		storage.GamesDirectory,
		"1710000000001-aaaaaaaaaaaaaaaa-cccccccccccccccc.png",
	)
	for _, filePath := range []string{referencedArchive, referencedIcon} {
		if err := os.WriteFile(filePath, []byte("referenced"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := database.CreateOwnedGame(ctx, store.CreateGameInput{
		PackageID: "com.example.referenced", Name: "Referenced", Author: "Owner",
		Version: "1.0.0", OwnerUserID: owner.ID, Status: store.StatusPending,
		OriginalFilename: "game.zip", StoredPath: referencedArchive,
		IconPath:     referencedIcon,
		ManifestJSON: `{"id":"com.example.referenced","version":"1.0.0"}`,
		ScanStatus:   "clean", ScanReport: "{}",
	}); err != nil {
		t.Fatal(err)
	}
	orphaned := []string{
		filepath.Join(
			storage.GamesDirectory,
			"1710000000002-dddddddddddddddd-eeeeeeeeeeeeeeee.zip",
		),
		filepath.Join(
			storage.GamesDirectory,
			"1710000000003-dddddddddddddddd-ffffffffffffffff.png",
		),
		filepath.Join(
			storage.GamesDirectory,
			"1710000000004-dddddddddddddddd-1111111111111111.zip.tmp",
		),
		filepath.Join(storage.QuarantineDirectory, "upload-12345.zip"),
		filepath.Join(storage.QuarantineDirectory, "normalized-67890.zip"),
	}
	preserved := []string{
		referencedArchive,
		referencedIcon,
		filepath.Join(storage.GamesDirectory, "operator-file.zip"),
		filepath.Join(
			storage.GamesDirectory,
			"1710000000005-DDDDDDDDDDDDDDDD-2222222222222222.zip",
		),
		filepath.Join(storage.QuarantineDirectory, "operator-file.zip"),
	}
	for _, filePath := range append(orphaned, preserved[2:]...) {
		if err := os.WriteFile(filePath, []byte("artifact"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	generatedDirectory := filepath.Join(
		storage.GamesDirectory,
		"1710000000006-dddddddddddddddd-3333333333333333.zip",
	)
	if err := os.Mkdir(generatedDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	service := New(
		config.Config{Storage: storage}, database, mailer.New(config.Mail{}),
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
	completed, err := service.CleanupDeleting(ctx)
	if err != nil || completed != 0 {
		t.Fatalf("orphan cleanup completed=%d err=%v", completed, err)
	}
	for _, filePath := range orphaned {
		if _, err := os.Stat(filePath); !os.IsNotExist(err) {
			t.Fatalf("orphan artifact remains: %s: %v", filePath, err)
		}
	}
	for _, filePath := range preserved {
		if _, err := os.Stat(filePath); err != nil {
			t.Fatalf("referenced or unrelated file removed: %s: %v", filePath, err)
		}
	}
	if info, err := os.Stat(generatedDirectory); err != nil || !info.IsDir() {
		t.Fatalf("generated-looking directory must be preserved: %v", err)
	}
}
