package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"go-server/internal/config"
	"go-server/internal/version"
)

const (
	StatusPending  = "pending"
	StatusApproved = "approved"
	StatusRejected = "rejected"
	StatusDeleting = "deleting"
	SchemaVersion  = 3
)

var (
	ErrNotFound              = errors.New("记录不存在")
	ErrEmailExists           = errors.New("邮箱已注册")
	ErrOwnershipConflict     = errors.New("gameId 已由其他账号持有")
	ErrVersionAlreadyExists  = errors.New("版本已存在")
	ErrVersionMustIncrease   = errors.New("版本必须严格递增")
	ErrGameMustBeUnpublished = errors.New("游戏必须先下架")
	ErrNotLatestVersion      = errors.New("只能上架当前最新审核版本")
	ErrInvalidGameState      = errors.New("游戏状态不允许此操作")
)

type VersionConflictError struct {
	Kind                  error
	CurrentHighestVersion string
}

func (e *VersionConflictError) Error() string { return e.Kind.Error() }
func (e *VersionConflictError) Unwrap() error { return e.Kind }

type Store struct {
	db *sql.DB
}

type Game struct {
	ID               int64  `json:"id"`
	PackageID        string `json:"packageId"`
	Name             string `json:"name"`
	Author           string `json:"author"`
	Version          string `json:"version"`
	Remarks          string `json:"remarks"`
	TagsText         string `json:"-"`
	Email            string `json:"email,omitempty"`
	OwnerUserID      int64  `json:"ownerUserId"`
	Status           string `json:"status"`
	Published        bool   `json:"published"`
	OriginalFilename string `json:"originalFilename"`
	StoredPath       string `json:"-"`
	IconPath         string `json:"-"`
	ManifestJSON     string `json:"-"`
	ScanStatus       string `json:"scanStatus"`
	ScanReport       string `json:"scanReport"`
	RejectionReason  string `json:"rejectionReason,omitempty"`
	CreatedAt        int64  `json:"createdAt"`
	UpdatedAt        int64  `json:"updatedAt"`
	ReviewedAt       int64  `json:"reviewedAt,omitempty"`
}

type CreateGameInput struct {
	PackageID        string
	Name             string
	Author           string
	Version          string
	Remarks          string
	TagsText         string
	OwnerUserID      int64
	Status           string
	Published        bool
	OriginalFilename string
	StoredPath       string
	IconPath         string
	ManifestJSON     string
	ScanStatus       string
	ScanReport       string
	RejectionReason  string
}

type User struct {
	ID              int64  `json:"id"`
	Email           string `json:"email"`
	DisplayName     string `json:"displayName"`
	Status          string `json:"status"`
	EmailVerifiedAt int64  `json:"emailVerifiedAt,omitempty"`
	CreatedAt       int64  `json:"createdAt"`
}

type UploadCredential struct {
	UserID  int64
	KeyHMAC string
}

type AdminGameQuery struct {
	Status string
	Search string
	Page   int
	Size   int
}

type PagedGames struct {
	Total   int64  `json:"total"`
	Current int    `json:"current"`
	Size    int    `json:"size"`
	Data    []Game `json:"data"`
}

type CatalogQuery struct {
	Status      string
	Name        string
	Tag         string
	Description string
}

type PublicGameQuery struct {
	Status    string
	PackageID string
	Name      string
	Author    string
	FromTime  int64
	ToTime    int64
	Sort      string
	Order     string
	Page      int
	Size      int
}

type Settings struct {
	Name                     string `json:"name"`
	Author                   string `json:"author"`
	Homepage                 string `json:"homepage"`
	SupportsGameRelay        bool   `json:"supportsGameRelay"`
	AllowUserRegistration    bool   `json:"allowUserRegistration"`
	RequireEmailVerification bool   `json:"requireEmailVerification"`
}

type ReviewActor struct {
	UserID     int64
	Identifier string
	Role       string
}

func UserReviewActor(userID int64) ReviewActor {
	return ReviewActor{
		UserID: userID, Identifier: strconv.FormatInt(userID, 10), Role: "user",
	}
}

func AdminReviewActor(identifier string) ReviewActor {
	return ReviewActor{Identifier: strings.TrimSpace(identifier), Role: "admin"}
}

func SystemReviewActor() ReviewActor {
	return ReviewActor{Identifier: "system", Role: "system"}
}

type ReviewEvent struct {
	ID              int64  `json:"id"`
	GameRecordID    int64  `json:"gameRecordId,omitempty"`
	PackageID       string `json:"packageId"`
	Version         string `json:"version"`
	ActorUserID     int64  `json:"actorUserId,omitempty"`
	ActorIdentifier string `json:"actorIdentifier"`
	ActorRole       string `json:"actorRole"`
	Action          string `json:"action"`
	Detail          string `json:"detail"`
	CreatedAt       int64  `json:"createdAt"`
}

func Open(cfg config.Storage, defaults Settings) (*Store, error) {
	for _, path := range []string{
		filepath.Dir(cfg.DatabasePath),
		cfg.GamesDirectory,
		cfg.QuarantineDirectory,
	} {
		if err := os.MkdirAll(path, 0o750); err != nil {
			return nil, fmt.Errorf("创建服务端数据目录 %q: %w", path, err)
		}
	}
	existing := false
	if info, err := os.Stat(cfg.DatabasePath); err == nil && info.Size() > 0 {
		existing = true
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	db, err := sql.Open("sqlite", cfg.DatabasePath)
	if err != nil {
		return nil, fmt.Errorf("打开 SQLite: %w", err)
	}
	db.SetMaxOpenConns(1)
	result := &Store{db: db}
	if existing {
		// Check the destructive schema boundary before any pragma that can
		// mutate the database header or create WAL sidecar files.
		var schemaVersion int
		if err := db.QueryRow(`PRAGMA user_version`).Scan(&schemaVersion); err != nil {
			_ = db.Close()
			return nil, err
		}
		if schemaVersion != SchemaVersion {
			_ = db.Close()
			return nil, fmt.Errorf(
				"SQLite schema 版本不匹配：当前 %d，要求 %d；请备份后使用全新数据库",
				schemaVersion, SchemaVersion,
			)
		}
		if err := result.verifySchema(); err != nil {
			_ = db.Close()
			return nil, err
		}
	} else if err := result.createSchema(); err != nil {
		_ = db.Close()
		return nil, err
	}
	if _, err := db.Exec(`
		PRAGMA foreign_keys = ON;
		PRAGMA journal_mode = WAL;
		PRAGMA busy_timeout = 5000;
	`); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("配置 SQLite: %w", err)
	}
	if err := result.ensureSettings(defaults); err != nil {
		_ = db.Close()
		return nil, err
	}
	for _, databaseFile := range []string{
		cfg.DatabasePath, cfg.DatabasePath + "-wal", cfg.DatabasePath + "-shm",
	} {
		if err := os.Chmod(databaseFile, 0o600); err != nil &&
			!errors.Is(err, os.ErrNotExist) && os.PathSeparator != '\\' {
			_ = db.Close()
			return nil, fmt.Errorf("收紧 SQLite 文件权限: %w", err)
		}
	}
	return result, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) createSchema() error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`
		CREATE TABLE users (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			normalized_email TEXT NOT NULL UNIQUE,
			password_hash TEXT NOT NULL,
			display_name TEXT NOT NULL,
			status TEXT NOT NULL CHECK(status IN ('pending_verification', 'active')),
			email_verified_at INTEGER NOT NULL DEFAULT 0,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL
		);
		CREATE TABLE user_sessions (
			token_hash TEXT PRIMARY KEY,
			user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
			csrf_hash TEXT NOT NULL,
			expires_at INTEGER NOT NULL,
			created_at INTEGER NOT NULL
		);
		CREATE INDEX user_sessions_user_idx ON user_sessions(user_id);
		CREATE INDEX user_sessions_expires_idx ON user_sessions(expires_at);
		CREATE TABLE email_verification_tokens (
			token_hash TEXT PRIMARY KEY,
			user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
			expires_at INTEGER NOT NULL,
			used_at INTEGER NOT NULL DEFAULT 0,
			created_at INTEGER NOT NULL
		);
		CREATE INDEX email_tokens_user_idx
			ON email_verification_tokens(user_id, created_at DESC);
		CREATE TABLE upload_credentials (
			user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
			key_hmac TEXT NOT NULL UNIQUE,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL
		);
		CREATE TABLE game_ownership (
			package_id TEXT PRIMARY KEY,
			user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
			created_at INTEGER NOT NULL
		);
		CREATE TABLE games (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			package_id TEXT NOT NULL,
			name TEXT NOT NULL,
			author TEXT NOT NULL,
			version TEXT NOT NULL,
			version_major INTEGER NOT NULL,
			version_minor INTEGER NOT NULL,
			version_patch INTEGER NOT NULL,
			remarks TEXT NOT NULL DEFAULT '',
			tags_text TEXT NOT NULL DEFAULT '',
			owner_user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
			status TEXT NOT NULL CHECK(status IN ('pending', 'approved', 'rejected', 'deleting')),
			published INTEGER NOT NULL DEFAULT 0 CHECK(published IN (0, 1)),
			original_filename TEXT NOT NULL,
			stored_path TEXT NOT NULL DEFAULT '',
			icon_path TEXT NOT NULL DEFAULT '',
			manifest_json TEXT NOT NULL,
			scan_status TEXT NOT NULL,
			scan_report TEXT NOT NULL,
			rejection_reason TEXT NOT NULL DEFAULT '',
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL,
			reviewed_at INTEGER NOT NULL DEFAULT 0,
			UNIQUE(package_id, version)
		);
		CREATE INDEX games_status_updated_idx ON games(status, updated_at DESC);
		CREATE INDEX games_package_version_idx
			ON games(package_id, version_major DESC, version_minor DESC, version_patch DESC);
		CREATE INDEX games_owner_idx ON games(owner_user_id, updated_at DESC);
		CREATE TABLE review_events (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			game_record_id INTEGER,
			package_id TEXT NOT NULL,
			version TEXT NOT NULL,
			actor_user_id INTEGER,
			actor_identifier TEXT NOT NULL,
			actor_role TEXT NOT NULL,
			action TEXT NOT NULL,
			detail TEXT NOT NULL DEFAULT '',
			created_at INTEGER NOT NULL
		);
		CREATE INDEX review_events_package_idx
			ON review_events(package_id, created_at DESC);
		CREATE TABLE server_settings (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL,
			updated_at INTEGER NOT NULL
		);
		CREATE TABLE admin_sessions (
			token_hash TEXT PRIMARY KEY,
			expires_at INTEGER NOT NULL,
			created_at INTEGER NOT NULL
		);
		CREATE INDEX admin_sessions_expires_idx ON admin_sessions(expires_at);
	`); err != nil {
		return fmt.Errorf("创建 SQLite schema: %w", err)
	}
	if _, err := tx.Exec(fmt.Sprintf("PRAGMA user_version = %d", SchemaVersion)); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) verifySchema() error {
	required := []string{
		"users", "user_sessions", "email_verification_tokens", "upload_credentials",
		"game_ownership", "games", "review_events", "server_settings", "admin_sessions",
	}
	for _, table := range required {
		var count int
		if err := s.db.QueryRow(
			"SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", table,
		).Scan(&count); err != nil || count != 1 {
			return fmt.Errorf("SQLite schema 缺少目标表 %s", table)
		}
	}
	var duplicatePackage, duplicateVersion string
	var duplicateCount int
	err := s.db.QueryRow(`
		SELECT package_id, version, COUNT(*)
		FROM games GROUP BY package_id, version HAVING COUNT(*) > 1 LIMIT 1
	`).Scan(&duplicatePackage, &duplicateVersion, &duplicateCount)
	if err == nil {
		return fmt.Errorf(
			"SQLite 完整性错误：%s %s 存在 %d 条重复版本",
			duplicatePackage, duplicateVersion, duplicateCount,
		)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("检查 SQLite 游戏版本唯一性: %w", err)
	}
	return nil
}

func (s *Store) ensureSettings(defaults Settings) error {
	now := time.Now().UnixMilli()
	values := map[string]string{
		"name":                       defaults.Name,
		"author":                     defaults.Author,
		"homepage":                   defaults.Homepage,
		"supports_game_relay":        boolString(defaults.SupportsGameRelay),
		"allow_user_registration":    boolString(defaults.AllowUserRegistration),
		"require_email_verification": boolString(defaults.RequireEmailVerification),
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for key, value := range values {
		if _, err := tx.Exec(
			`INSERT OR IGNORE INTO server_settings(key, value, updated_at) VALUES(?, ?, ?)`,
			key, value, now,
		); err != nil {
			return fmt.Errorf("初始化设置: %w", err)
		}
	}
	for key, value := range map[string]string{
		"allow_user_registration":    boolString(defaults.AllowUserRegistration),
		"require_email_verification": boolString(defaults.RequireEmailVerification),
	} {
		if _, err := tx.Exec(`
			UPDATE server_settings SET value = ?, updated_at = ? WHERE key = ?
		`, value, now, key); err != nil {
			return fmt.Errorf("同步注册设置: %w", err)
		}
	}
	return tx.Commit()
}

func (s *Store) CreateUser(
	ctx context.Context,
	email string,
	passwordHash string,
	status string,
) (User, error) {
	now := time.Now().UnixMilli()
	result, err := s.db.ExecContext(ctx, `
		INSERT INTO users(
			normalized_email, password_hash, display_name, status,
			email_verified_at, created_at, updated_at
		) VALUES(?, ?, ?, ?, ?, ?, ?)
	`, email, passwordHash, email, status, boolTime(status == "active", now), now, now)
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "unique") {
			return User{}, ErrEmailExists
		}
		return User{}, err
	}
	id, err := result.LastInsertId()
	if err != nil {
		return User{}, err
	}
	return s.GetUser(ctx, id)
}

func (s *Store) GetUser(ctx context.Context, id int64) (User, error) {
	return scanUser(s.db.QueryRowContext(ctx, `
		SELECT id, normalized_email, display_name, status, email_verified_at, created_at
		FROM users WHERE id = ?
	`, id))
}

func (s *Store) GetUserByEmail(
	ctx context.Context,
	email string,
) (User, string, error) {
	var user User
	var passwordHash string
	err := s.db.QueryRowContext(ctx, `
		SELECT id, normalized_email, display_name, status, email_verified_at,
		       created_at, password_hash
		FROM users WHERE normalized_email = ?
	`, email).Scan(
		&user.ID, &user.Email, &user.DisplayName, &user.Status,
		&user.EmailVerifiedAt, &user.CreatedAt, &passwordHash,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, "", ErrNotFound
	}
	return user, passwordHash, err
}

func (s *Store) UpdateDisplayName(
	ctx context.Context,
	userID int64,
	displayName string,
) (User, error) {
	result, err := s.db.ExecContext(ctx, `
		UPDATE users SET display_name = ?, updated_at = ? WHERE id = ?
	`, displayName, time.Now().UnixMilli(), userID)
	if err != nil {
		return User{}, err
	}
	if affected, _ := result.RowsAffected(); affected != 1 {
		return User{}, ErrNotFound
	}
	return s.GetUser(ctx, userID)
}

func (s *Store) CreateUserSession(
	ctx context.Context,
	userID int64,
	tokenHash string,
	csrfHash string,
	expiresAt time.Time,
) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO user_sessions(token_hash, user_id, csrf_hash, expires_at, created_at)
		VALUES(?, ?, ?, ?, ?)
	`, tokenHash, userID, csrfHash, expiresAt.UnixMilli(), time.Now().UnixMilli())
	return err
}

func (s *Store) UserBySession(
	ctx context.Context,
	tokenHash string,
	now time.Time,
) (User, string, error) {
	var user User
	var csrfHash string
	err := s.db.QueryRowContext(ctx, `
		SELECT u.id, u.normalized_email, u.display_name, u.status,
		       u.email_verified_at, u.created_at, s.csrf_hash
		FROM user_sessions s
		JOIN users u ON u.id = s.user_id
		WHERE s.token_hash = ? AND s.expires_at > ?
	`, tokenHash, now.UnixMilli()).Scan(
		&user.ID, &user.Email, &user.DisplayName, &user.Status,
		&user.EmailVerifiedAt, &user.CreatedAt, &csrfHash,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, "", ErrNotFound
	}
	return user, csrfHash, err
}

func (s *Store) DeleteUserSession(ctx context.Context, tokenHash string) error {
	_, err := s.db.ExecContext(ctx, "DELETE FROM user_sessions WHERE token_hash = ?", tokenHash)
	return err
}

func (s *Store) CleanupUserSessions(ctx context.Context, now time.Time) error {
	_, err := s.db.ExecContext(ctx,
		"DELETE FROM user_sessions WHERE expires_at <= ?", now.UnixMilli())
	return err
}

func (s *Store) CreateEmailVerificationToken(
	ctx context.Context,
	userID int64,
	tokenHash string,
	expiresAt time.Time,
) error {
	now := time.Now().UnixMilli()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx,
		"UPDATE email_verification_tokens SET used_at = ? WHERE user_id = ? AND used_at = 0",
		now, userID,
	); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO email_verification_tokens(
			token_hash, user_id, expires_at, used_at, created_at
		) VALUES(?, ?, ?, 0, ?)
	`, tokenHash, userID, expiresAt.UnixMilli(), now); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) VerificationSendStats(
	ctx context.Context,
	userID int64,
	now time.Time,
) (lastSentAt int64, sentLastHour int, err error) {
	err = s.db.QueryRowContext(ctx, `
		SELECT COALESCE(MAX(created_at), 0),
		       COALESCE(SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END), 0)
		FROM email_verification_tokens WHERE user_id = ?
	`, now.Add(-time.Hour).UnixMilli(), userID).Scan(&lastSentAt, &sentLastHour)
	return
}

func (s *Store) ReserveEmailVerificationToken(
	ctx context.Context,
	userID int64,
	tokenHash string,
	now time.Time,
	expiresAt time.Time,
	minimumInterval time.Duration,
	hourlyLimit int,
) (bool, error) {
	if minimumInterval <= 0 || hourlyLimit < 1 {
		return false, errors.New("邮箱验证重发限制无效")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	lockResult, err := tx.ExecContext(ctx,
		"UPDATE users SET updated_at = updated_at WHERE id = ?",
		userID,
	)
	if err != nil {
		return false, err
	}
	if affected, err := lockResult.RowsAffected(); err != nil || affected != 1 {
		if err != nil {
			return false, err
		}
		return false, ErrNotFound
	}
	var lastSentAt int64
	var sentLastHour int
	if err := tx.QueryRowContext(ctx, `
		SELECT COALESCE(MAX(created_at), 0),
		       COALESCE(SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END), 0)
		FROM email_verification_tokens WHERE user_id = ?
	`, now.Add(-time.Hour).UnixMilli(), userID).Scan(
		&lastSentAt,
		&sentLastHour,
	); err != nil {
		return false, err
	}
	if (lastSentAt > 0 &&
		now.UnixMilli()-lastSentAt < minimumInterval.Milliseconds()) ||
		sentLastHour >= hourlyLimit {
		return false, nil
	}
	nowMilliseconds := now.UnixMilli()
	if _, err := tx.ExecContext(ctx,
		"UPDATE email_verification_tokens SET used_at = ? WHERE user_id = ? AND used_at = 0",
		nowMilliseconds, userID,
	); err != nil {
		return false, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO email_verification_tokens(
			token_hash, user_id, expires_at, used_at, created_at
		) VALUES(?, ?, ?, 0, ?)
	`, tokenHash, userID, expiresAt.UnixMilli(), nowMilliseconds); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return true, nil
}

func (s *Store) ConsumeEmailVerificationToken(
	ctx context.Context,
	tokenHash string,
	now time.Time,
) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var userID int64
	err = tx.QueryRowContext(ctx, `
		SELECT user_id FROM email_verification_tokens
		WHERE token_hash = ? AND used_at = 0 AND expires_at > ?
	`, tokenHash, now.UnixMilli()).Scan(&userID)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE email_verification_tokens SET used_at = ? WHERE token_hash = ?
	`, now.UnixMilli(), tokenHash); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE users SET status = 'active', email_verified_at = ?, updated_at = ?
		WHERE id = ?
	`, now.UnixMilli(), now.UnixMilli(), userID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) PutUploadCredential(
	ctx context.Context,
	userID int64,
	keyHMAC string,
) error {
	now := time.Now().UnixMilli()
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO upload_credentials(user_id, key_hmac, created_at, updated_at)
		VALUES(?, ?, ?, ?)
		ON CONFLICT(user_id) DO UPDATE SET
			key_hmac = excluded.key_hmac, updated_at = excluded.updated_at
	`, userID, keyHMAC, now, now)
	return err
}

func (s *Store) UserByUploadCredential(
	ctx context.Context,
	keyHMAC string,
) (User, error) {
	return scanUser(s.db.QueryRowContext(ctx, `
		SELECT u.id, u.normalized_email, u.display_name, u.status,
		       u.email_verified_at, u.created_at
		FROM upload_credentials c
		JOIN users u ON u.id = c.user_id
		WHERE c.key_hmac = ? AND u.status = 'active'
	`, keyHMAC))
}

func (s *Store) CreateOwnedGame(
	ctx context.Context,
	input CreateGameInput,
) (Game, error) {
	parsed, err := version.Parse(input.Version)
	if err != nil {
		return Game{}, err
	}
	now := time.Now().UnixMilli()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Game{}, err
	}
	defer tx.Rollback()
	var ownerID int64
	err = tx.QueryRowContext(ctx,
		"SELECT user_id FROM game_ownership WHERE package_id = ?",
		input.PackageID,
	).Scan(&ownerID)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO game_ownership(package_id, user_id, created_at) VALUES(?, ?, ?)
		`, input.PackageID, input.OwnerUserID, now); err != nil {
			return Game{}, err
		}
	case err != nil:
		return Game{}, err
	case ownerID != input.OwnerUserID:
		return Game{}, ErrOwnershipConflict
	}
	var highestVersion string
	var major, minor, patch int64
	err = tx.QueryRowContext(ctx, `
		SELECT version, version_major, version_minor, version_patch
		FROM games WHERE package_id = ?
		ORDER BY version_major DESC, version_minor DESC, version_patch DESC
		LIMIT 1
	`, input.PackageID).Scan(&highestVersion, &major, &minor, &patch)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return Game{}, err
	}
	if err == nil {
		comparison := version.Compare(parsed, version.Value{Major: major, Minor: minor, Patch: patch})
		if comparison == 0 {
			return Game{}, &VersionConflictError{
				Kind: ErrVersionAlreadyExists, CurrentHighestVersion: highestVersion,
			}
		}
		if comparison < 0 {
			return Game{}, &VersionConflictError{
				Kind: ErrVersionMustIncrease, CurrentHighestVersion: highestVersion,
			}
		}
	}
	result, err := tx.ExecContext(ctx, `
		INSERT INTO games(
			package_id, name, author, version, version_major, version_minor, version_patch,
			remarks, tags_text, owner_user_id, status, published, original_filename,
			stored_path, icon_path, manifest_json, scan_status, scan_report,
			rejection_reason, created_at, updated_at
		) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, input.PackageID, input.Name, input.Author, input.Version,
		parsed.Major, parsed.Minor, parsed.Patch, input.Remarks, input.TagsText,
		input.OwnerUserID, input.Status, input.Published, input.OriginalFilename,
		input.StoredPath, input.IconPath, input.ManifestJSON, input.ScanStatus,
		input.ScanReport, input.RejectionReason, now, now)
	if err != nil {
		return Game{}, err
	}
	id, err := result.LastInsertId()
	if err != nil {
		return Game{}, err
	}
	if err := insertReviewEvent(
		ctx, tx, id, input.PackageID, input.Version,
		UserReviewActor(input.OwnerUserID), "uploaded",
		fmt.Sprintf("from=none target=%s scanStatus=%q", input.Status, input.ScanStatus),
		now,
	); err != nil {
		return Game{}, err
	}
	if err := tx.Commit(); err != nil {
		return Game{}, err
	}
	return s.GetGame(ctx, id)
}

func (s *Store) CheckOwnership(
	ctx context.Context,
	packageID string,
	userID int64,
) error {
	var ownerID int64
	err := s.db.QueryRowContext(ctx,
		"SELECT user_id FROM game_ownership WHERE package_id = ?", packageID,
	).Scan(&ownerID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if ownerID != userID {
		return ErrOwnershipConflict
	}
	return nil
}

func (s *Store) GetGame(ctx context.Context, id int64) (Game, error) {
	return scanGame(s.db.QueryRowContext(ctx, gameSelect+` WHERE g.id = ?`, id))
}

func (s *Store) ListUserGames(
	ctx context.Context,
	userID int64,
) ([]Game, error) {
	rows, err := s.db.QueryContext(ctx,
		gameSelect+` WHERE g.owner_user_id = ? AND g.status <> ? ORDER BY
			g.package_id, g.version_major DESC, g.version_minor DESC, g.version_patch DESC`,
		userID, StatusDeleting,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanGames(rows)
}

func (s *Store) ListAdminGames(ctx context.Context, query AdminGameQuery) (PagedGames, error) {
	where := []string{"1 = 1"}
	args := make([]any, 0, 7)
	if query.Status != "" {
		where = append(where, "g.status = ?")
		args = append(args, query.Status)
	}
	if value := strings.ToLower(strings.TrimSpace(query.Search)); value != "" {
		where = append(where, `(lower(g.package_id) LIKE ? OR lower(g.name) LIKE ? OR
			lower(g.author) LIKE ? OR lower(u.normalized_email) LIKE ? OR lower(g.version) LIKE ?)`)
		pattern := "%" + value + "%"
		args = append(args, pattern, pattern, pattern, pattern, pattern)
	}
	whereSQL := strings.Join(where, " AND ")
	var total int64
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM games g JOIN users u ON u.id = g.owner_user_id
		WHERE `+whereSQL, args...).Scan(&total); err != nil {
		return PagedGames{}, err
	}
	offset := int64(query.Page-1) * int64(query.Size)
	listArgs := append(append([]any{}, args...), query.Size, offset)
	rows, err := s.db.QueryContext(ctx, gameSelect+`
		WHERE `+whereSQL+`
		ORDER BY g.updated_at DESC, g.id DESC LIMIT ? OFFSET ?
	`, listArgs...)
	if err != nil {
		return PagedGames{}, err
	}
	defer rows.Close()
	games, err := scanGames(rows)
	return PagedGames{
		Total: total, Current: query.Page, Size: query.Size, Data: games,
	}, err
}

func (s *Store) ListCatalogGames(
	ctx context.Context,
	query CatalogQuery,
	page int,
	size int,
) ([]Game, int64, error) {
	filters := []string{"package_rank = 1", "published = 1", "stored_path <> ''"}
	args := make([]any, 0, 5)
	appendLike := func(column, value string) {
		if value = strings.ToLower(strings.TrimSpace(value)); value != "" {
			filters = append(filters, "lower("+column+") LIKE ?")
			args = append(args, "%"+value+"%")
		}
	}
	appendLike("name", query.Name)
	appendLike("tags_text", query.Tag)
	appendLike("remarks", query.Description)
	filterSQL := strings.Join(filters, " AND ")
	cte := `
		WITH ranked AS (
			SELECT g.*, u.normalized_email,
			       ROW_NUMBER() OVER (
			           PARTITION BY g.package_id
			           ORDER BY g.version_major DESC, g.version_minor DESC, g.version_patch DESC
			       ) package_rank
			FROM games g JOIN users u ON u.id = g.owner_user_id
			WHERE g.status = 'approved'
		)
	`
	var total int64
	if err := s.db.QueryRowContext(
		ctx, cte+"SELECT COUNT(*) FROM ranked WHERE "+filterSQL, args...,
	).Scan(&total); err != nil {
		return nil, 0, err
	}
	offset := int64(page-1) * int64(size)
	listArgs := append(append([]any{}, args...), size, offset)
	rows, err := s.db.QueryContext(ctx, cte+`
		SELECT `+rankedGameColumns+` FROM ranked
		WHERE `+filterSQL+`
		ORDER BY updated_at DESC, id DESC LIMIT ? OFFSET ?
	`, listArgs...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	games, err := scanGames(rows)
	return games, total, err
}

func (s *Store) ListPublicGames(
	ctx context.Context,
	query PublicGameQuery,
) (PagedGames, error) {
	games, total, err := s.ListCatalogGames(ctx, CatalogQuery{
		Name: query.Name,
	}, query.Page, query.Size)
	if err != nil {
		return PagedGames{}, err
	}
	return PagedGames{
		Total: total, Current: query.Page, Size: query.Size, Data: games,
	}, nil
}

func (s *Store) GetCatalogGame(
	ctx context.Context,
	packageID string,
	versionValue string,
) (Game, error) {
	row := s.db.QueryRowContext(ctx, `
		WITH ranked AS (
			SELECT g.*, u.normalized_email,
			       ROW_NUMBER() OVER (
			           PARTITION BY g.package_id
			           ORDER BY g.version_major DESC, g.version_minor DESC, g.version_patch DESC
			       ) package_rank
			FROM games g JOIN users u ON u.id = g.owner_user_id
			WHERE g.status = 'approved' AND g.package_id = ?
		)
		SELECT `+rankedGameColumns+` FROM ranked
		WHERE package_rank = 1 AND published = 1 AND version = ? AND stored_path <> ''
	`, packageID, versionValue)
	return scanGame(row)
}

func (s *Store) UpdateGameStatus(
	ctx context.Context,
	id int64,
	status string,
	reason string,
	actor ReviewActor,
) (Game, error) {
	if status != StatusApproved && status != StatusRejected {
		return Game{}, ErrInvalidGameState
	}
	now := time.Now().UnixMilli()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Game{}, err
	}
	defer tx.Rollback()
	current, err := getGameTx(ctx, tx, id)
	if err != nil {
		return Game{}, err
	}
	if current.Status != StatusPending {
		return Game{}, ErrInvalidGameState
	}
	if status == StatusApproved && current.StoredPath == "" {
		return Game{}, ErrInvalidGameState
	}
	published := false
	type unpublishedGame struct {
		id      int64
		version string
	}
	autoUnpublished := make([]unpublishedGame, 0)
	if status == StatusApproved {
		parsed, err := version.Parse(current.Version)
		if err != nil {
			return Game{}, err
		}
		var higherApproved int
		if err := tx.QueryRowContext(ctx, `
			SELECT COUNT(*) FROM games
			WHERE package_id = ? AND status = 'approved' AND (
				version_major > ? OR
				(version_major = ? AND version_minor > ?) OR
				(version_major = ? AND version_minor = ? AND version_patch > ?)
			)
		`, current.PackageID, parsed.Major, parsed.Major, parsed.Minor,
			parsed.Major, parsed.Minor, parsed.Patch,
		).Scan(&higherApproved); err != nil {
			return Game{}, err
		}
		published = higherApproved == 0
		if published {
			rows, err := tx.QueryContext(ctx, `
				SELECT id, version FROM games
				WHERE package_id = ? AND status = 'approved' AND published = 1
				ORDER BY id
			`, current.PackageID)
			if err != nil {
				return Game{}, err
			}
			for rows.Next() {
				var previous unpublishedGame
				if err := rows.Scan(&previous.id, &previous.version); err != nil {
					_ = rows.Close()
					return Game{}, err
				}
				autoUnpublished = append(autoUnpublished, previous)
			}
			rowsErr := rows.Err()
			closeErr := rows.Close()
			if rowsErr != nil {
				return Game{}, rowsErr
			}
			if closeErr != nil {
				return Game{}, closeErr
			}
			if _, err := tx.ExecContext(ctx, `
				UPDATE games SET published = 0, updated_at = ?
				WHERE package_id = ? AND status = 'approved'
			`, now, current.PackageID); err != nil {
				return Game{}, err
			}
		}
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE games SET status = ?, published = ?, rejection_reason = ?,
			updated_at = ?, reviewed_at = ? WHERE id = ?
	`, status, published, reason, now, now, id); err != nil {
		return Game{}, err
	}
	if err := insertReviewEvent(
		ctx, tx, id, current.PackageID, current.Version, actor,
		status,
		fmt.Sprintf("from=%s target=%s reason=%q", current.Status, status, reason),
		now,
	); err != nil {
		return Game{}, err
	}
	for _, previous := range autoUnpublished {
		if err := insertReviewEvent(
			ctx, tx, previous.id, current.PackageID, previous.version, actor,
			"unpublished",
			"from=published target=unpublished reason=latest_version_approved",
			now,
		); err != nil {
			return Game{}, err
		}
	}
	if published {
		if err := insertReviewEvent(
			ctx, tx, id, current.PackageID, current.Version, actor,
			"published",
			"from=unpublished target=published reason=approval",
			now,
		); err != nil {
			return Game{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return Game{}, err
	}
	return s.GetGame(ctx, id)
}

func (s *Store) SetPublished(
	ctx context.Context,
	id int64,
	actor ReviewActor,
	published bool,
) (Game, error) {
	now := time.Now().UnixMilli()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Game{}, err
	}
	defer tx.Rollback()
	current, err := getGameTx(ctx, tx, id)
	if err != nil {
		return Game{}, err
	}
	if actor.Role == "user" && current.OwnerUserID != actor.UserID {
		return Game{}, ErrNotFound
	}
	if current.Status != StatusApproved {
		return Game{}, ErrInvalidGameState
	}
	if published {
		var latestID int64
		if err := tx.QueryRowContext(ctx, `
			SELECT id FROM games WHERE package_id = ? AND status = 'approved'
			ORDER BY version_major DESC, version_minor DESC, version_patch DESC LIMIT 1
		`, current.PackageID).Scan(&latestID); err != nil {
			return Game{}, err
		}
		if latestID != id {
			return Game{}, ErrNotLatestVersion
		}
	}
	if _, err := tx.ExecContext(ctx,
		"UPDATE games SET published = ?, updated_at = ? WHERE id = ?",
		published, now, id,
	); err != nil {
		return Game{}, err
	}
	action := "unpublished"
	if published {
		action = "published"
	}
	if err := insertReviewEvent(
		ctx, tx, id, current.PackageID, current.Version,
		actor, action,
		fmt.Sprintf(
			"from=%s target=%s",
			publicationState(current.Published), publicationState(published),
		),
		now,
	); err != nil {
		return Game{}, err
	}
	if err := tx.Commit(); err != nil {
		return Game{}, err
	}
	return s.GetGame(ctx, id)
}

func (s *Store) BeginDeleteOwnedGame(
	ctx context.Context,
	id int64,
	actor ReviewActor,
) (Game, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Game{}, err
	}
	defer tx.Rollback()
	current, err := getGameTx(ctx, tx, id)
	if err != nil {
		return Game{}, err
	}
	if actor.Role == "user" && current.OwnerUserID != actor.UserID {
		return Game{}, ErrNotFound
	}
	if current.Published {
		return Game{}, ErrGameMustBeUnpublished
	}
	if current.Status == StatusDeleting {
		return current, tx.Commit()
	}
	now := time.Now().UnixMilli()
	if _, err := tx.ExecContext(ctx, `
		UPDATE games SET status = ?, published = 0, updated_at = ? WHERE id = ?
	`, StatusDeleting, now, id); err != nil {
		return Game{}, err
	}
	if err := insertReviewEvent(
		ctx, tx, current.ID, current.PackageID, current.Version,
		actor, "delete_started",
		fmt.Sprintf("from=%s target=%s", current.Status, StatusDeleting), now,
	); err != nil {
		return Game{}, err
	}
	if err := tx.Commit(); err != nil {
		return Game{}, err
	}
	current.Status = StatusDeleting
	current.Published = false
	current.UpdatedAt = now
	return current, nil
}

func (s *Store) CompleteDeletingGame(
	ctx context.Context,
	id int64,
	actor ReviewActor,
) (Game, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Game{}, err
	}
	defer tx.Rollback()
	current, err := getGameTx(ctx, tx, id)
	if err != nil {
		return Game{}, err
	}
	if actor.Role == "user" && current.OwnerUserID != actor.UserID {
		return Game{}, ErrNotFound
	}
	if current.Status != StatusDeleting {
		return Game{}, ErrInvalidGameState
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM games WHERE id = ?", id); err != nil {
		return Game{}, err
	}
	var remaining int
	if err := tx.QueryRowContext(ctx,
		"SELECT COUNT(*) FROM games WHERE package_id = ?", current.PackageID,
	).Scan(&remaining); err != nil {
		return Game{}, err
	}
	if remaining == 0 {
		if _, err := tx.ExecContext(ctx,
			"DELETE FROM game_ownership WHERE package_id = ?", current.PackageID,
		); err != nil {
			return Game{}, err
		}
	}
	if err := insertReviewEvent(
		ctx, tx, current.ID, current.PackageID, current.Version,
		actor, "deleted", "from=deleting target=deleted",
		time.Now().UnixMilli(),
	); err != nil {
		return Game{}, err
	}
	if err := tx.Commit(); err != nil {
		return Game{}, err
	}
	return current, nil
}

func (s *Store) BeginDeleteOwnedPackage(
	ctx context.Context,
	packageID string,
	actor ReviewActor,
) ([]Game, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var ownerID int64
	if err := tx.QueryRowContext(ctx,
		"SELECT user_id FROM game_ownership WHERE package_id = ?", packageID,
	).Scan(&ownerID); errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	} else if err != nil {
		return nil, err
	}
	if actor.Role != "user" || ownerID != actor.UserID {
		return nil, ErrNotFound
	}
	var published int
	if err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM games WHERE package_id = ? AND published = 1
	`, packageID).Scan(&published); err != nil {
		return nil, err
	}
	if published > 0 {
		return nil, ErrGameMustBeUnpublished
	}
	rows, err := tx.QueryContext(ctx, gameSelect+`
		WHERE g.package_id = ? AND g.owner_user_id = ?
	`, packageID, actor.UserID)
	if err != nil {
		return nil, err
	}
	games, scanErr := scanGames(rows)
	closeErr := rows.Close()
	if scanErr != nil {
		return nil, scanErr
	}
	if closeErr != nil {
		return nil, closeErr
	}
	if len(games) == 0 {
		return nil, ErrNotFound
	}
	now := time.Now().UnixMilli()
	for index := range games {
		game := games[index]
		if game.Status == StatusDeleting {
			continue
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE games SET status = ?, published = 0, updated_at = ? WHERE id = ?
		`, StatusDeleting, now, game.ID); err != nil {
			return nil, err
		}
		if err := insertReviewEvent(
			ctx, tx, game.ID, game.PackageID, game.Version,
			actor, "delete_started",
			fmt.Sprintf(
				"from=%s target=%s package_delete", game.Status, StatusDeleting,
			),
			now,
		); err != nil {
			return nil, err
		}
		games[index].Status = StatusDeleting
		games[index].Published = false
		games[index].UpdatedAt = now
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return games, nil
}

func (s *Store) CompleteDeletingPackage(
	ctx context.Context,
	packageID string,
	actor ReviewActor,
) ([]Game, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var ownerID int64
	if err := tx.QueryRowContext(ctx,
		"SELECT user_id FROM game_ownership WHERE package_id = ?", packageID,
	).Scan(&ownerID); errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	} else if err != nil {
		return nil, err
	}
	if actor.Role == "user" && ownerID != actor.UserID {
		return nil, ErrNotFound
	}
	rows, err := tx.QueryContext(ctx, gameSelect+`
		WHERE g.package_id = ? ORDER BY g.id
	`, packageID)
	if err != nil {
		return nil, err
	}
	games, scanErr := scanGames(rows)
	closeErr := rows.Close()
	if scanErr != nil {
		return nil, scanErr
	}
	if closeErr != nil {
		return nil, closeErr
	}
	if len(games) == 0 {
		return nil, ErrNotFound
	}
	for _, game := range games {
		if game.Status != StatusDeleting {
			return nil, ErrInvalidGameState
		}
	}
	if _, err := tx.ExecContext(ctx,
		"DELETE FROM games WHERE package_id = ?", packageID,
	); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx,
		"DELETE FROM game_ownership WHERE package_id = ?", packageID,
	); err != nil {
		return nil, err
	}
	now := time.Now().UnixMilli()
	for _, game := range games {
		if err := insertReviewEvent(
			ctx, tx, game.ID, game.PackageID, game.Version,
			actor, "deleted",
			"from=deleting target=deleted package_delete", now,
		); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return games, nil
}

func (s *Store) ListDeletingGames(ctx context.Context) ([]Game, error) {
	rows, err := s.db.QueryContext(ctx, gameSelect+`
		WHERE g.status = ? ORDER BY g.updated_at, g.id
	`, StatusDeleting)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanGames(rows)
}

func (s *Store) ListStoredFilePaths(ctx context.Context) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT stored_path FROM games WHERE stored_path <> ''
		UNION
		SELECT icon_path FROM games WHERE icon_path <> ''
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	paths := make([]string, 0)
	for rows.Next() {
		var storedPath string
		if err := rows.Scan(&storedPath); err != nil {
			return nil, err
		}
		paths = append(paths, storedPath)
	}
	return paths, rows.Err()
}

func (s *Store) ListReviewEvents(
	ctx context.Context,
	packageID string,
) ([]ReviewEvent, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, game_record_id, package_id, version, actor_user_id,
		       actor_identifier, actor_role, action, detail, created_at
		FROM review_events
		WHERE package_id = ?
		ORDER BY id
	`, packageID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	events := make([]ReviewEvent, 0)
	for rows.Next() {
		var event ReviewEvent
		var gameRecordID, actorUserID sql.NullInt64
		if err := rows.Scan(
			&event.ID, &gameRecordID, &event.PackageID, &event.Version,
			&actorUserID, &event.ActorIdentifier, &event.ActorRole,
			&event.Action, &event.Detail, &event.CreatedAt,
		); err != nil {
			return nil, err
		}
		if gameRecordID.Valid {
			event.GameRecordID = gameRecordID.Int64
		}
		if actorUserID.Valid {
			event.ActorUserID = actorUserID.Int64
		}
		events = append(events, event)
	}
	return events, rows.Err()
}

const settingsSelect = `
	SELECT key, value FROM server_settings WHERE key IN (
		'name', 'author', 'homepage', 'supports_game_relay',
		'allow_user_registration', 'require_email_verification'
	)
`

func (s *Store) GetSettings(ctx context.Context) (Settings, error) {
	rows, err := s.db.QueryContext(ctx, settingsSelect)
	if err != nil {
		return Settings{}, err
	}
	defer rows.Close()
	return scanSettings(rows)
}

func scanSettings(rows *sql.Rows) (Settings, error) {
	var settings Settings
	for rows.Next() {
		var key, value string
		if err := rows.Scan(&key, &value); err != nil {
			return Settings{}, err
		}
		switch key {
		case "name":
			settings.Name = value
		case "author":
			settings.Author = value
		case "homepage":
			settings.Homepage = value
		case "supports_game_relay":
			settings.SupportsGameRelay = value == "true"
		case "allow_user_registration":
			settings.AllowUserRegistration = value == "true"
		case "require_email_verification":
			settings.RequireEmailVerification = value == "true"
		}
	}
	return settings, rows.Err()
}

func (s *Store) UpdateSettings(
	ctx context.Context,
	settings Settings,
	actor ReviewActor,
) error {
	now := time.Now().UnixMilli()
	settings.Name = strings.TrimSpace(settings.Name)
	settings.Author = strings.TrimSpace(settings.Author)
	settings.Homepage = strings.TrimSpace(settings.Homepage)
	values := map[string]string{
		"name":                       settings.Name,
		"author":                     settings.Author,
		"homepage":                   settings.Homepage,
		"supports_game_relay":        boolString(settings.SupportsGameRelay),
		"allow_user_registration":    boolString(settings.AllowUserRegistration),
		"require_email_verification": boolString(settings.RequireEmailVerification),
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, settingsSelect)
	if err != nil {
		return err
	}
	current, scanErr := scanSettings(rows)
	closeErr := rows.Close()
	if scanErr != nil {
		return scanErr
	}
	if closeErr != nil {
		return closeErr
	}
	for key, value := range values {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO server_settings(key, value, updated_at) VALUES(?, ?, ?)
			ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
		`, key, value, now); err != nil {
			return err
		}
	}
	if err := insertReviewEvent(
		ctx, tx, 0, "_server", "settings", actor,
		"settings_updated",
		fmt.Sprintf(
			"from=%s target=%s",
			settingsAuditValue(current), settingsAuditValue(settings),
		),
		now,
	); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) CreateAdminSession(
	ctx context.Context,
	tokenHash string,
	expiresAt time.Time,
) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO admin_sessions(token_hash, expires_at, created_at) VALUES(?, ?, ?)
	`, tokenHash, expiresAt.UnixMilli(), time.Now().UnixMilli())
	return err
}

func (s *Store) AdminSessionValid(
	ctx context.Context,
	tokenHash string,
	now time.Time,
) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM admin_sessions WHERE token_hash = ? AND expires_at > ?
	`, tokenHash, now.UnixMilli()).Scan(&count)
	return count == 1, err
}

func (s *Store) DeleteAdminSession(ctx context.Context, tokenHash string) error {
	_, err := s.db.ExecContext(ctx,
		"DELETE FROM admin_sessions WHERE token_hash = ?", tokenHash)
	return err
}

func (s *Store) CleanupAdminSessions(ctx context.Context, now time.Time) error {
	_, err := s.db.ExecContext(ctx,
		"DELETE FROM admin_sessions WHERE expires_at <= ?", now.UnixMilli())
	return err
}

const gameSelect = `
	SELECT g.id, g.package_id, g.name, g.author, g.version, g.remarks, g.tags_text,
	       u.normalized_email, g.owner_user_id, g.status, g.published,
	       g.original_filename, g.stored_path, g.icon_path, g.manifest_json,
	       g.scan_status, g.scan_report, g.rejection_reason,
	       g.created_at, g.updated_at, g.reviewed_at
	FROM games g JOIN users u ON u.id = g.owner_user_id
`

const rankedGameColumns = `
	id, package_id, name, author, version, remarks, tags_text, normalized_email,
	owner_user_id, status, published, original_filename, stored_path, icon_path,
	manifest_json, scan_status, scan_report, rejection_reason,
	created_at, updated_at, reviewed_at
`

type rowScanner interface {
	Scan(dest ...any) error
}

func scanGame(row rowScanner) (Game, error) {
	var game Game
	err := row.Scan(
		&game.ID, &game.PackageID, &game.Name, &game.Author, &game.Version,
		&game.Remarks, &game.TagsText, &game.Email, &game.OwnerUserID,
		&game.Status, &game.Published, &game.OriginalFilename, &game.StoredPath,
		&game.IconPath, &game.ManifestJSON, &game.ScanStatus, &game.ScanReport,
		&game.RejectionReason, &game.CreatedAt, &game.UpdatedAt, &game.ReviewedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return Game{}, ErrNotFound
	}
	return game, err
}

func scanGames(rows *sql.Rows) ([]Game, error) {
	games := make([]Game, 0)
	for rows.Next() {
		game, err := scanGame(rows)
		if err != nil {
			return nil, err
		}
		games = append(games, game)
	}
	return games, rows.Err()
}

func scanUser(row rowScanner) (User, error) {
	var user User
	err := row.Scan(
		&user.ID, &user.Email, &user.DisplayName, &user.Status,
		&user.EmailVerifiedAt, &user.CreatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, ErrNotFound
	}
	return user, err
}

func getGameTx(ctx context.Context, tx *sql.Tx, id int64) (Game, error) {
	return scanGame(tx.QueryRowContext(ctx, gameSelect+` WHERE g.id = ?`, id))
}

func insertReviewEvent(
	ctx context.Context,
	tx *sql.Tx,
	gameRecordID int64,
	packageID string,
	gameVersion string,
	actor ReviewActor,
	action string,
	detail string,
	createdAt int64,
) error {
	if strings.TrimSpace(actor.Identifier) == "" {
		return errors.New("review event actor identifier is required")
	}
	if strings.TrimSpace(actor.Role) == "" {
		return errors.New("review event actor role is required")
	}
	var recordID any
	if gameRecordID > 0 {
		recordID = gameRecordID
	}
	var userID any
	if actor.UserID > 0 {
		userID = actor.UserID
	}
	_, err := tx.ExecContext(ctx, `
		INSERT INTO review_events(
			game_record_id, package_id, version, actor_user_id,
			actor_identifier, actor_role, action, detail, created_at
		) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, recordID, packageID, gameVersion, userID, actor.Identifier,
		actor.Role, action, detail, createdAt)
	return err
}

func publicationState(published bool) string {
	if published {
		return "published"
	}
	return "unpublished"
}

func settingsAuditValue(settings Settings) string {
	return fmt.Sprintf(
		"{name=%q author=%q homepage=%q supportsGameRelay=%t "+
			"allowUserRegistration=%t requireEmailVerification=%t}",
		settings.Name,
		settings.Author,
		settings.Homepage,
		settings.SupportsGameRelay,
		settings.AllowUserRegistration,
		settings.RequireEmailVerification,
	)
}

func boolString(value bool) string {
	if value {
		return "true"
	}
	return "false"
}

func boolTime(value bool, now int64) int64 {
	if value {
		return now
	}
	return 0
}
