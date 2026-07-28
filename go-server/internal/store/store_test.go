package store

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	_ "modernc.org/sqlite"

	"go-server/internal/config"
)

func TestOpenRejectsOldSchema(t *testing.T) {
	root := t.TempDir()
	databasePath := filepath.Join(root, "old.db")
	db, err := sql.Open("sqlite", databasePath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("CREATE TABLE games(id INTEGER PRIMARY KEY)"); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(databasePath)
	if err != nil {
		t.Fatal(err)
	}
	_, err = Open(testStorage(root, databasePath), Settings{})
	if err == nil {
		t.Fatal("旧 schema 未被拒绝")
	}
	after, readErr := os.ReadFile(databasePath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("拒绝旧 schema 时修改了旧数据库")
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		if _, statErr := os.Stat(databasePath + suffix); !os.IsNotExist(statErr) {
			t.Fatalf("拒绝旧 schema 时创建了 %s sidecar: %v", suffix, statErr)
		}
	}
}

func TestOwnershipVersionAndLatestPublication(t *testing.T) {
	root := t.TempDir()
	database, err := Open(
		testStorage(root, filepath.Join(root, "new.db")),
		Settings{AllowUserRegistration: true},
	)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	ctx := context.Background()
	first, err := database.CreateUser(ctx, "first@example.com", "hash", "active")
	if err != nil {
		t.Fatal(err)
	}
	second, err := database.CreateUser(ctx, "second@example.com", "hash", "active")
	if err != nil {
		t.Fatal(err)
	}
	v1, err := database.CreateOwnedGame(ctx, gameInput(first.ID, "1.0.0"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.CreateOwnedGame(ctx, gameInput(second.ID, "2.0.0")); !errors.Is(err, ErrOwnershipConflict) {
		t.Fatalf("所有权冲突 = %v", err)
	}
	if _, err := database.UpdateGameStatus(
		ctx, v1.ID, StatusApproved, "", AdminReviewActor("test-admin"),
	); err != nil {
		t.Fatal(err)
	}
	v2, err := database.CreateOwnedGame(ctx, gameInput(first.ID, "2.0.0"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.CreateOwnedGame(ctx, gameInput(first.ID, "1.5.0")); !errors.Is(err, ErrVersionMustIncrease) {
		t.Fatalf("低版本冲突 = %v", err)
	}
	if _, err := database.UpdateGameStatus(
		ctx, v2.ID, StatusApproved, "", AdminReviewActor("test-admin"),
	); err != nil {
		t.Fatal(err)
	}
	games, total, err := database.ListCatalogGames(ctx, CatalogQuery{}, 1, 10)
	if err != nil {
		t.Fatal(err)
	}
	if total != 1 || len(games) != 1 || games[0].Version != "2.0.0" {
		t.Fatalf("Catalog latest = total:%d games:%#v", total, games)
	}
	if _, err := database.SetPublished(
		ctx, v1.ID, UserReviewActor(first.ID), true,
	); !errors.Is(err, ErrNotLatestVersion) {
		t.Fatalf("历史版本上架 = %v", err)
	}
	if _, err := database.SetPublished(
		ctx, v2.ID, UserReviewActor(first.ID), false,
	); err != nil {
		t.Fatal(err)
	}
	games, total, err = database.ListCatalogGames(ctx, CatalogQuery{}, 1, 10)
	if err != nil {
		t.Fatal(err)
	}
	if total != 0 || len(games) != 0 {
		t.Fatalf("最新版本下架后发生回退: %#v", games)
	}
}

func TestConcurrentOwnedGameCreationIsSerialized(t *testing.T) {
	t.Run("different owners", func(t *testing.T) {
		root := t.TempDir()
		database, err := Open(
			testStorage(root, filepath.Join(root, "new.db")),
			Settings{AllowUserRegistration: true},
		)
		if err != nil {
			t.Fatal(err)
		}
		defer database.Close()
		ctx := context.Background()
		first, err := database.CreateUser(ctx, "first@example.com", "hash", "active")
		if err != nil {
			t.Fatal(err)
		}
		second, err := database.CreateUser(ctx, "second@example.com", "hash", "active")
		if err != nil {
			t.Fatal(err)
		}

		start := make(chan struct{})
		results := make(chan error, 2)
		var workers sync.WaitGroup
		for _, ownerID := range []int64{first.ID, second.ID} {
			workers.Add(1)
			go func(ownerID int64) {
				defer workers.Done()
				<-start
				_, createErr := database.CreateOwnedGame(
					ctx,
					gameInput(ownerID, "1.0.0"),
				)
				results <- createErr
			}(ownerID)
		}
		close(start)
		workers.Wait()
		close(results)

		successes, ownershipConflicts := 0, 0
		for createErr := range results {
			switch {
			case createErr == nil:
				successes++
			case errors.Is(createErr, ErrOwnershipConflict):
				ownershipConflicts++
			default:
				t.Fatalf("unexpected concurrent create error: %v", createErr)
			}
		}
		if successes != 1 || ownershipConflicts != 1 {
			t.Fatalf(
				"successes=%d ownershipConflicts=%d",
				successes,
				ownershipConflicts,
			)
		}
		assertPackagePersistenceCounts(t, database, "com.example.game", 1)
	})

	t.Run("same owner and version", func(t *testing.T) {
		root := t.TempDir()
		database, err := Open(
			testStorage(root, filepath.Join(root, "new.db")),
			Settings{AllowUserRegistration: true},
		)
		if err != nil {
			t.Fatal(err)
		}
		defer database.Close()
		ctx := context.Background()
		owner, err := database.CreateUser(ctx, "owner@example.com", "hash", "active")
		if err != nil {
			t.Fatal(err)
		}

		start := make(chan struct{})
		results := make(chan error, 2)
		var workers sync.WaitGroup
		for range 2 {
			workers.Add(1)
			go func() {
				defer workers.Done()
				<-start
				_, createErr := database.CreateOwnedGame(
					ctx,
					gameInput(owner.ID, "1.0.0"),
				)
				results <- createErr
			}()
		}
		close(start)
		workers.Wait()
		close(results)

		successes, versionConflicts := 0, 0
		for createErr := range results {
			switch {
			case createErr == nil:
				successes++
			case errors.Is(createErr, ErrVersionAlreadyExists):
				versionConflicts++
			default:
				t.Fatalf("unexpected concurrent create error: %v", createErr)
			}
		}
		if successes != 1 || versionConflicts != 1 {
			t.Fatalf(
				"successes=%d versionConflicts=%d",
				successes,
				versionConflicts,
			)
		}
		assertPackagePersistenceCounts(t, database, "com.example.game", 1)
	})
}

func assertPackagePersistenceCounts(
	t *testing.T,
	database *Store,
	packageID string,
	want int,
) {
	t.Helper()
	for table, query := range map[string]string{
		"games":          "SELECT COUNT(*) FROM games WHERE package_id = ?",
		"review_events":  "SELECT COUNT(*) FROM review_events WHERE package_id = ?",
		"game_ownership": "SELECT COUNT(*) FROM game_ownership WHERE package_id = ?",
	} {
		var count int
		if err := database.db.QueryRow(query, packageID).Scan(&count); err != nil {
			t.Fatal(err)
		}
		if count != want {
			t.Fatalf("%s count=%d want=%d", table, count, want)
		}
	}
}

func TestOutOfOrderApprovalKeepsHighestApprovedVersionPublished(t *testing.T) {
	root := t.TempDir()
	database, err := Open(
		testStorage(root, filepath.Join(root, "new.db")),
		Settings{AllowUserRegistration: true},
	)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	ctx := context.Background()
	owner, err := database.CreateUser(ctx, "owner@example.com", "hash", "active")
	if err != nil {
		t.Fatal(err)
	}
	v1, err := database.CreateOwnedGame(ctx, gameInput(owner.ID, "1.0.0"))
	if err != nil {
		t.Fatal(err)
	}
	v2, err := database.CreateOwnedGame(ctx, gameInput(owner.ID, "2.0.0"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.UpdateGameStatus(
		ctx, v2.ID, StatusApproved, "", AdminReviewActor("test-admin"),
	); err != nil {
		t.Fatal(err)
	}
	older, err := database.UpdateGameStatus(
		ctx, v1.ID, StatusApproved, "", AdminReviewActor("test-admin"),
	)
	if err != nil {
		t.Fatal(err)
	}
	if older.Published {
		t.Fatal("晚审批的历史版本不应取代更高版本")
	}
	games, total, err := database.ListCatalogGames(ctx, CatalogQuery{}, 1, 10)
	if err != nil {
		t.Fatal(err)
	}
	if total != 1 || len(games) != 1 || games[0].Version != "2.0.0" {
		t.Fatalf("乱序审批后的 Catalog = total:%d games:%#v", total, games)
	}
}

func TestVerificationTokenIsOneTimeAndUploadKeyRotationIsImmediate(t *testing.T) {
	root := t.TempDir()
	database, err := Open(
		testStorage(root, filepath.Join(root, "new.db")),
		Settings{AllowUserRegistration: true, RequireEmailVerification: true},
	)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	ctx := context.Background()
	account, err := database.CreateUser(
		ctx, "pending@example.com", "hash", "pending_verification",
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := database.CreateEmailVerificationToken(
		ctx, account.ID, "token-hash", time.Now().Add(time.Hour),
	); err != nil {
		t.Fatal(err)
	}
	if err := database.ConsumeEmailVerificationToken(
		ctx, "token-hash", time.Now(),
	); err != nil {
		t.Fatal(err)
	}
	if err := database.ConsumeEmailVerificationToken(
		ctx, "token-hash", time.Now(),
	); !errors.Is(err, ErrNotFound) {
		t.Fatalf("验证 Token 被重复使用: %v", err)
	}
	if err := database.PutUploadCredential(ctx, account.ID, "old-hmac"); err != nil {
		t.Fatal(err)
	}
	if err := database.PutUploadCredential(ctx, account.ID, "new-hmac"); err != nil {
		t.Fatal(err)
	}
	if _, err := database.UserByUploadCredential(ctx, "old-hmac"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("轮换后的旧上传密钥仍有效: %v", err)
	}
	if _, err := database.UserByUploadCredential(ctx, "new-hmac"); err != nil {
		t.Fatalf("轮换后的新上传密钥无效: %v", err)
	}
}

func TestConcurrentVerificationReservationsEnforceAccountLimits(t *testing.T) {
	root := t.TempDir()
	database, err := Open(
		testStorage(root, filepath.Join(root, "new.db")),
		Settings{AllowUserRegistration: true, RequireEmailVerification: true},
	)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	ctx := context.Background()
	account, err := database.CreateUser(
		ctx, "pending@example.com", "hash", "pending_verification",
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := database.CreateEmailVerificationToken(
		ctx,
		account.ID,
		"old-token-hash",
		time.Now().Add(time.Hour),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := database.db.Exec(
		"UPDATE email_verification_tokens SET created_at = ? WHERE user_id = ?",
		time.Now().Add(-2*time.Minute).UnixMilli(),
		account.ID,
	); err != nil {
		t.Fatal(err)
	}

	const workers = 8
	type reservationResult struct {
		reserved bool
		err      error
	}
	start := make(chan struct{})
	results := make(chan reservationResult, workers)
	var group sync.WaitGroup
	now := time.Now()
	for index := 0; index < workers; index++ {
		group.Add(1)
		go func(index int) {
			defer group.Done()
			<-start
			reserved, reserveErr := database.ReserveEmailVerificationToken(
				ctx,
				account.ID,
				"reserved-token-"+string(rune('a'+index)),
				now,
				now.Add(time.Hour),
				time.Minute,
				5,
			)
			results <- reservationResult{reserved: reserved, err: reserveErr}
		}(index)
	}
	close(start)
	group.Wait()
	close(results)

	reservedCount := 0
	for result := range results {
		if result.err != nil {
			t.Fatalf("并发预留错误: %v", result.err)
		}
		if result.reserved {
			reservedCount++
		}
	}
	if reservedCount != 1 {
		t.Fatalf("并发预留成功数 = %d, want 1", reservedCount)
	}
	if err := database.ConsumeEmailVerificationToken(
		ctx,
		"old-token-hash",
		time.Now(),
	); !errors.Is(err, ErrNotFound) {
		t.Fatalf("原子预留后旧 Token 仍有效: %v", err)
	}
	_, sentLastHour, err := database.VerificationSendStats(
		ctx,
		account.ID,
		time.Now(),
	)
	if err != nil || sentLastHour != 2 {
		t.Fatalf("并发预留后的小时计数 = %d, err = %v", sentLastHour, err)
	}
}

func TestDeletingStatePersistsUntilFilesCanBeCleaned(t *testing.T) {
	root := t.TempDir()
	database, err := Open(
		testStorage(root, filepath.Join(root, "new.db")),
		Settings{AllowUserRegistration: true},
	)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	ctx := context.Background()
	owner, err := database.CreateUser(ctx, "owner@example.com", "hash", "active")
	if err != nil {
		t.Fatal(err)
	}
	game, err := database.CreateOwnedGame(ctx, gameInput(owner.ID, "1.0.0"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.UpdateGameStatus(
		ctx, game.ID, StatusApproved, "", AdminReviewActor("test-admin"),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := database.SetPublished(
		ctx, game.ID, UserReviewActor(owner.ID), false,
	); err != nil {
		t.Fatal(err)
	}
	deleting, err := database.BeginDeleteOwnedGame(
		ctx, game.ID, UserReviewActor(owner.ID),
	)
	if err != nil {
		t.Fatal(err)
	}
	if deleting.Status != StatusDeleting {
		t.Fatalf("删除开始状态 = %q", deleting.Status)
	}
	stillStored, err := database.GetGame(ctx, game.ID)
	if err != nil || stillStored.Status != StatusDeleting {
		t.Fatalf("deleting 记录未持久化: game=%#v err=%v", stillStored, err)
	}
	userGames, err := database.ListUserGames(ctx, owner.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(userGames) != 0 {
		t.Fatalf("用户门户仍公开 deleting 记录: %#v", userGames)
	}
	catalogGames, total, err := database.ListCatalogGames(ctx, CatalogQuery{}, 1, 10)
	if err != nil {
		t.Fatal(err)
	}
	if total != 0 || len(catalogGames) != 0 {
		t.Fatalf("Catalog 仍公开 deleting 记录: %#v", catalogGames)
	}
	retry, err := database.BeginDeleteOwnedGame(
		ctx, game.ID, UserReviewActor(owner.ID),
	)
	if err != nil || retry.Status != StatusDeleting {
		t.Fatalf("重试删除开始失败: game=%#v err=%v", retry, err)
	}
	if _, err := database.CompleteDeletingGame(
		ctx, game.ID, UserReviewActor(owner.ID),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := database.GetGame(ctx, game.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("完成清理后记录仍存在: %v", err)
	}
	var ownershipCount, auditCount int
	if err := database.db.QueryRow(
		"SELECT COUNT(*) FROM game_ownership WHERE package_id = ?",
		game.PackageID,
	).Scan(&ownershipCount); err != nil {
		t.Fatal(err)
	}
	if err := database.db.QueryRow(
		"SELECT COUNT(*) FROM review_events WHERE game_record_id = ?",
		game.ID,
	).Scan(&auditCount); err != nil {
		t.Fatal(err)
	}
	if ownershipCount != 0 || auditCount < 3 {
		t.Fatalf("删除收尾 ownership=%d audits=%d", ownershipCount, auditCount)
	}
	events, err := database.ListReviewEvents(ctx, game.PackageID)
	if err != nil {
		t.Fatal(err)
	}
	expected := []struct {
		action     string
		identifier string
		role       string
		from       string
		target     string
	}{
		{"uploaded", UserReviewActor(owner.ID).Identifier, "user", "none", "pending"},
		{"approved", "test-admin", "admin", "pending", "approved"},
		{"published", "test-admin", "admin", "unpublished", "published"},
		{"unpublished", UserReviewActor(owner.ID).Identifier, "user", "published", "unpublished"},
		{"delete_started", UserReviewActor(owner.ID).Identifier, "user", "approved", "deleting"},
		{"deleted", UserReviewActor(owner.ID).Identifier, "user", "deleting", "deleted"},
	}
	if len(events) != len(expected) {
		t.Fatalf("review events=%#v", events)
	}
	for index, want := range expected {
		event := events[index]
		if event.Action != want.action ||
			event.ActorIdentifier != want.identifier ||
			event.ActorRole != want.role ||
			event.PackageID != game.PackageID ||
			event.Version != game.Version ||
			event.CreatedAt <= 0 ||
			!strings.Contains(event.Detail, "from="+want.from) ||
			!strings.Contains(event.Detail, "target="+want.target) {
			t.Fatalf("review event[%d]=%#v want=%#v", index, event, want)
		}
	}
}

func TestSettingsReviewEventRecordsConfiguredAdminAndTransition(t *testing.T) {
	root := t.TempDir()
	database, err := Open(
		testStorage(root, filepath.Join(root, "new.db")),
		Settings{Name: "Before", AllowUserRegistration: true},
	)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	ctx := context.Background()
	next := Settings{
		Name: "After", Author: "Operator", SupportsGameRelay: true,
		RequireEmailVerification: true,
	}
	if err := database.UpdateSettings(
		ctx, next, AdminReviewActor("configured-admin"),
	); err != nil {
		t.Fatal(err)
	}
	events, err := database.ListReviewEvents(ctx, "_server")
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 {
		t.Fatalf("settings review events=%#v", events)
	}
	event := events[0]
	if event.ActorIdentifier != "configured-admin" ||
		event.ActorRole != "admin" ||
		event.Action != "settings_updated" ||
		event.PackageID != "_server" ||
		event.Version != "settings" ||
		event.CreatedAt <= 0 ||
		!strings.Contains(event.Detail, `from={name="Before"`) ||
		!strings.Contains(event.Detail, `target={name="After"`) {
		t.Fatalf("settings review event=%#v", event)
	}
}

func testStorage(root string, databasePath string) config.Storage {
	return config.Storage{
		DatabasePath:        databasePath,
		GamesDirectory:      filepath.Join(root, "games"),
		QuarantineDirectory: filepath.Join(root, "quarantine"),
	}
}

func TestAdminUserLifecycleAndNotifications(t *testing.T) {
	root := t.TempDir()
	database, err := Open(
		testStorage(root, filepath.Join(root, "server.db")),
		Settings{AllowUserRegistration: true},
	)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	ctx := context.Background()
	account, err := database.CreateUser(
		ctx, "publisher@example.com", "password-hash", "active",
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := database.CreateUserSession(
		ctx, account.ID, "session-hash", "csrf-hash", time.Now().Add(time.Hour),
	); err != nil {
		t.Fatal(err)
	}
	users, err := database.ListAdminUsers(ctx, AdminUserQuery{
		Search: "publisher", Page: 1, Size: 20,
	})
	if err != nil || users.Total != 1 || len(users.Data) != 1 {
		t.Fatalf("用户搜索 = %#v, err=%v", users, err)
	}
	if err := database.SetUserDisabled(
		ctx, account.ID, true, "违反发布规则",
	); err != nil {
		t.Fatal(err)
	}
	if _, _, err := database.UserBySession(
		ctx, "session-hash", time.Now(),
	); !errors.Is(err, ErrNotFound) {
		t.Fatalf("禁用后会话仍然有效: %v", err)
	}
	disabled, err := database.ListAdminUsers(ctx, AdminUserQuery{
		Status: "disabled", Page: 1, Size: 20,
	})
	if err != nil || disabled.Total != 1 ||
		disabled.Data[0].DisabledReason != "违反发布规则" {
		t.Fatalf("禁用用户列表 = %#v, err=%v", disabled, err)
	}
	if err := database.CreateNotification(
		ctx, account.ID, "game_unpublished", "游戏包已下架", "原因：测试",
	); err != nil {
		t.Fatal(err)
	}
	notifications, err := database.ListNotifications(ctx, account.ID, 50)
	if err != nil || len(notifications) != 1 || notifications[0].ReadAt != 0 {
		t.Fatalf("站内通知 = %#v, err=%v", notifications, err)
	}
	if err := database.MarkNotificationRead(
		ctx, account.ID, notifications[0].ID,
	); err != nil {
		t.Fatal(err)
	}
	notifications, err = database.ListNotifications(ctx, account.ID, 50)
	if err != nil || notifications[0].ReadAt == 0 {
		t.Fatalf("通知未标为已读 = %#v, err=%v", notifications, err)
	}
	if _, err := database.CreateOwnedGame(ctx, gameInput(account.ID, "1.0.0")); err != nil {
		t.Fatal(err)
	}
	if err := database.DeleteUser(ctx, account.ID); !errors.Is(err, ErrUserHasGames) {
		t.Fatalf("拥有游戏包的用户删除错误 = %v", err)
	}
}

func TestOpenMigratesSchemaV3ToCurrent(t *testing.T) {
	root := t.TempDir()
	databasePath := filepath.Join(root, "server.db")
	storage := testStorage(root, databasePath)
	database, err := Open(storage, Settings{})
	if err != nil {
		t.Fatal(err)
	}
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}
	raw, err := sql.Open("sqlite", databasePath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(`
		DROP TABLE user_notifications;
		DROP TABLE disabled_users;
		ALTER TABLE upload_credentials RENAME TO upload_credentials_v5;
		CREATE TABLE upload_credentials (
			user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
			key_hmac TEXT NOT NULL UNIQUE,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL
		);
		INSERT INTO upload_credentials(user_id, key_hmac, created_at, updated_at)
		SELECT user_id, key_hmac, created_at, updated_at
		FROM upload_credentials_v5;
		DROP TABLE upload_credentials_v5;
		PRAGMA user_version = 3;
	`); err != nil {
		_ = raw.Close()
		t.Fatal(err)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}
	migrated, err := Open(storage, Settings{})
	if err != nil {
		t.Fatal(err)
	}
	defer migrated.Close()
	var version int
	if err := migrated.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		t.Fatal(err)
	}
	if version != SchemaVersion {
		t.Fatalf("迁移后 schema 版本 = %d", version)
	}
	var ciphertextColumn int
	rows, err := migrated.db.Query("PRAGMA table_info(upload_credentials)")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var cid, notNull, primaryKey int
		var name, columnType string
		var defaultValue any
		if err := rows.Scan(
			&cid, &name, &columnType, &notNull, &defaultValue, &primaryKey,
		); err != nil {
			t.Fatal(err)
		}
		if name == "key_ciphertext" {
			ciphertextColumn++
		}
	}
	if ciphertextColumn != 1 {
		t.Fatalf("迁移后 key_ciphertext 字段数 = %d", ciphertextColumn)
	}
}

func TestDisplayNameUpdateAppliesToExistingGames(t *testing.T) {
	root := t.TempDir()
	database, err := Open(
		testStorage(root, filepath.Join(root, "server.db")),
		Settings{},
	)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	ctx := context.Background()
	owner, err := database.CreateUser(ctx, "publisher@example.com", "hash", "active")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.UpdateDisplayName(ctx, owner.ID, "上传时昵称"); err != nil {
		t.Fatal(err)
	}
	game, err := database.CreateOwnedGame(ctx, gameInput(owner.ID, "1.0.0"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.UpdateDisplayName(ctx, owner.ID, "更新后昵称"); err != nil {
		t.Fatal(err)
	}
	var storedAuthor string
	if err := database.db.QueryRow(
		"SELECT author FROM games WHERE id = ?", game.ID,
	).Scan(&storedAuthor); err != nil {
		t.Fatal(err)
	}
	if storedAuthor != "更新后昵称" {
		t.Fatalf("游戏作者快照 = %q", storedAuthor)
	}
	// A legacy stale snapshot must not leak through current read APIs.
	if _, err := database.db.Exec(
		"UPDATE games SET author = '旧快照' WHERE id = ?", game.ID,
	); err != nil {
		t.Fatal(err)
	}
	current, err := database.GetGame(ctx, game.ID)
	if err != nil {
		t.Fatal(err)
	}
	if current.Author != "更新后昵称" {
		t.Fatalf("游戏读取作者 = %q", current.Author)
	}
	userGames, err := database.ListUserGames(ctx, owner.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(userGames) != 1 || userGames[0].Author != "更新后昵称" {
		t.Fatalf("用户游戏作者 = %#v", userGames)
	}
}

func gameInput(userID int64, gameVersion string) CreateGameInput {
	return CreateGameInput{
		PackageID:        "com.example.game",
		Name:             "Example",
		Author:           "Publisher",
		Version:          gameVersion,
		OwnerUserID:      userID,
		Status:           StatusPending,
		OriginalFilename: "game.zip",
		StoredPath:       "games/game.zip",
		ManifestJSON: `{"id":"com.example.game","name":"Example","version":"` +
			gameVersion + `"}`,
		ScanStatus: "clean",
		ScanReport: "{}",
	}
}
