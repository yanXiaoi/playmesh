package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"go-server/internal/config"
)

const (
	StatusPending  = "pending"
	StatusApproved = "approved"
	StatusRejected = "rejected"
)

var ErrNotFound = errors.New("记录不存在")

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
	Email            string `json:"email"`
	Status           string `json:"status"`
	OriginalFilename string `json:"originalFilename"`
	StoredPath       string `json:"-"`
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
	Email            string
	Status           string
	OriginalFilename string
	StoredPath       string
	ManifestJSON     string
	ScanStatus       string
	ScanReport       string
	RejectionReason  string
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
	Name              string `json:"name"`
	Author            string `json:"author"`
	Homepage          string `json:"homepage"`
	SupportsGameRelay bool   `json:"supportsGameRelay"`
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
	db, err := sql.Open("sqlite", cfg.DatabasePath)
	if err != nil {
		return nil, fmt.Errorf("打开 SQLite: %w", err)
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`
		PRAGMA foreign_keys = ON;
		PRAGMA journal_mode = WAL;
		PRAGMA busy_timeout = 5000;
	`); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("配置 SQLite: %w", err)
	}
	result := &Store{db: db}
	if err := result.migrate(); err != nil {
		_ = db.Close()
		return nil, err
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

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) migrate() error {
	_, err := s.db.Exec(`
		CREATE TABLE IF NOT EXISTS games (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			package_id TEXT NOT NULL,
			name TEXT NOT NULL,
			author TEXT NOT NULL DEFAULT '',
			version TEXT NOT NULL,
			remarks TEXT NOT NULL DEFAULT '',
			tags_text TEXT NOT NULL DEFAULT '',
			email TEXT NOT NULL,
			status TEXT NOT NULL CHECK(status IN ('pending', 'approved', 'rejected')),
			original_filename TEXT NOT NULL,
			stored_path TEXT NOT NULL DEFAULT '',
			manifest_json TEXT NOT NULL DEFAULT '{}',
			scan_status TEXT NOT NULL,
			scan_report TEXT NOT NULL,
			rejection_reason TEXT NOT NULL DEFAULT '',
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL,
			reviewed_at INTEGER NOT NULL DEFAULT 0
		);
		CREATE INDEX IF NOT EXISTS games_status_updated_idx
			ON games(status, updated_at DESC);
		CREATE INDEX IF NOT EXISTS games_package_status_idx
			ON games(package_id, status, updated_at DESC);

		CREATE TABLE IF NOT EXISTS review_events (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			game_id INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
			action TEXT NOT NULL,
			detail TEXT NOT NULL DEFAULT '',
			created_at INTEGER NOT NULL
		);
		CREATE INDEX IF NOT EXISTS review_events_game_idx
			ON review_events(game_id, created_at DESC);

		CREATE TABLE IF NOT EXISTS server_settings (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL,
			updated_at INTEGER NOT NULL
		);

		CREATE TABLE IF NOT EXISTS admin_sessions (
			token_hash TEXT PRIMARY KEY,
			expires_at INTEGER NOT NULL,
			created_at INTEGER NOT NULL
		);
		CREATE INDEX IF NOT EXISTS admin_sessions_expires_idx
			ON admin_sessions(expires_at);
	`)
	if err != nil {
		return fmt.Errorf("迁移 SQLite: %w", err)
	}
	return nil
}

func (s *Store) ensureSettings(defaults Settings) error {
	now := time.Now().UnixMilli()
	values := map[string]string{
		"name":                defaults.Name,
		"author":              defaults.Author,
		"homepage":            defaults.Homepage,
		"supports_game_relay": boolString(defaults.SupportsGameRelay),
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
	return tx.Commit()
}

func (s *Store) CreateGame(ctx context.Context, input CreateGameInput) (Game, error) {
	now := time.Now().UnixMilli()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Game{}, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		INSERT INTO games(
			package_id, name, author, version, remarks, tags_text, email, status,
			original_filename, stored_path, manifest_json, scan_status,
			scan_report, rejection_reason, created_at, updated_at
		) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, input.PackageID, input.Name, input.Author, input.Version, input.Remarks, input.TagsText,
		input.Email, input.Status, input.OriginalFilename, input.StoredPath,
		input.ManifestJSON, input.ScanStatus, input.ScanReport,
		input.RejectionReason, now, now)
	if err != nil {
		return Game{}, fmt.Errorf("保存游戏包记录: %w", err)
	}
	id, err := result.LastInsertId()
	if err != nil {
		return Game{}, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO review_events(game_id, action, detail, created_at)
		VALUES(?, 'uploaded', ?, ?)
	`, id, input.ScanStatus, now); err != nil {
		return Game{}, err
	}
	if err := tx.Commit(); err != nil {
		return Game{}, err
	}
	return s.GetGame(ctx, id)
}

func (s *Store) GetGame(ctx context.Context, id int64) (Game, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT id, package_id, name, author, version, remarks, tags_text, email, status,
		       original_filename, stored_path, manifest_json, scan_status,
		       scan_report, rejection_reason, created_at, updated_at, reviewed_at
		FROM games WHERE id = ?
	`, id)
	return scanGame(row)
}

func (s *Store) ListAdminGames(ctx context.Context, query AdminGameQuery) (PagedGames, error) {
	where := []string{"1 = 1"}
	args := make([]any, 0, 5)
	if query.Status != "" {
		where = append(where, "status = ?")
		args = append(args, query.Status)
	}
	if value := strings.ToLower(strings.TrimSpace(query.Search)); value != "" {
		where = append(where, `(lower(package_id) LIKE ? OR lower(name) LIKE ? OR
			lower(author) LIKE ? OR lower(email) LIKE ? OR lower(version) LIKE ?)`)
		pattern := "%" + value + "%"
		args = append(args, pattern, pattern, pattern, pattern, pattern)
	}
	whereSQL := strings.Join(where, " AND ")
	var total int64
	if err := s.db.QueryRowContext(
		ctx, "SELECT COUNT(*) FROM games WHERE "+whereSQL, args...,
	).Scan(&total); err != nil {
		return PagedGames{}, err
	}
	offset := int64(query.Page-1) * int64(query.Size)
	listArgs := append(append([]any{}, args...), query.Size, offset)
	// #nosec G202 -- whereSQL contains only constant clauses selected above;
	// every request value remains a bound parameter.
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, package_id, name, author, version, remarks, tags_text, email, status,
		       original_filename, stored_path, manifest_json, scan_status,
		       scan_report, rejection_reason, created_at, updated_at, reviewed_at
		FROM games
		WHERE `+whereSQL+`
		ORDER BY updated_at DESC, id DESC
		LIMIT ? OFFSET ?
	`, listArgs...)
	if err != nil {
		return PagedGames{}, err
	}
	defer rows.Close()
	games := make([]Game, 0)
	for rows.Next() {
		game, err := scanGame(rows)
		if err != nil {
			return PagedGames{}, err
		}
		games = append(games, game)
	}
	return PagedGames{
		Total: total, Current: query.Page, Size: query.Size, Data: games,
	}, rows.Err()
}

func (s *Store) ListCatalogGames(
	ctx context.Context,
	query CatalogQuery,
	page int,
	size int,
) ([]Game, int64, error) {
	where := []string{"status = ?", "stored_path <> ''"}
	args := []any{query.Status}
	appendLike := func(column, value string) {
		if value = strings.ToLower(strings.TrimSpace(value)); value != "" {
			where = append(where, "lower("+column+") LIKE ?")
			args = append(args, "%"+value+"%")
		}
	}
	appendLike("name", query.Name)
	appendLike("tags_text", query.Tag)
	appendLike("remarks", query.Description)
	whereSQL := strings.Join(where, " AND ")
	var total int64
	if err := s.db.QueryRowContext(
		ctx, "SELECT COUNT(DISTINCT package_id) FROM games WHERE "+whereSQL, args...,
	).Scan(&total); err != nil {
		return nil, 0, err
	}
	offset := int64(page-1) * int64(size)
	listArgs := append(append([]any{}, args...), size, offset)
	// #nosec G202 -- whereSQL contains only constant clauses selected above;
	// every request value remains a bound parameter.
	rows, err := s.db.QueryContext(ctx, `
		WITH ranked AS (
			SELECT id, package_id, name, author, version, remarks, tags_text, email, status,
			       original_filename, stored_path, manifest_json, scan_status,
			       scan_report, rejection_reason, created_at, updated_at, reviewed_at,
			       ROW_NUMBER() OVER (
			           PARTITION BY package_id ORDER BY updated_at DESC, id DESC
			       ) AS package_rank
			FROM games
			WHERE `+whereSQL+`
		)
		SELECT id, package_id, name, author, version, remarks, tags_text, email, status,
		       original_filename, stored_path, manifest_json, scan_status,
		       scan_report, rejection_reason, created_at, updated_at, reviewed_at
		FROM ranked
		WHERE package_rank = 1
		ORDER BY updated_at DESC, id DESC
		LIMIT ? OFFSET ?
	`, listArgs...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	games := make([]Game, 0)
	for rows.Next() {
		game, err := scanGame(rows)
		if err != nil {
			return nil, 0, err
		}
		games = append(games, game)
	}
	return games, total, rows.Err()
}

func (s *Store) ListPublicGames(
	ctx context.Context,
	query PublicGameQuery,
) (PagedGames, error) {
	if query.Status != StatusApproved && query.Status != StatusPending {
		return PagedGames{}, errors.New("公开页面只能查看已通过或待审核游戏")
	}
	where := []string{"status = ?"}
	args := []any{query.Status}
	appendLike := func(column, value string) {
		if value = strings.ToLower(strings.TrimSpace(value)); value != "" {
			where = append(where, "lower("+column+") LIKE ?")
			args = append(args, "%"+value+"%")
		}
	}
	appendLike("package_id", query.PackageID)
	appendLike("name", query.Name)
	appendLike("author", query.Author)
	if query.FromTime > 0 {
		where = append(where, "created_at >= ?")
		args = append(args, query.FromTime)
	}
	if query.ToTime > 0 {
		where = append(where, "created_at <= ?")
		args = append(args, query.ToTime)
	}
	sortColumn := map[string]string{
		"id": "package_id", "name": "name", "author": "author",
		"time": "created_at",
	}[query.Sort]
	if sortColumn == "" {
		sortColumn = "created_at"
	}
	order := "DESC"
	if strings.EqualFold(query.Order, "asc") {
		order = "ASC"
	}
	whereSQL := strings.Join(where, " AND ")
	var total int64
	if err := s.db.QueryRowContext(
		ctx, "SELECT COUNT(*) FROM games WHERE "+whereSQL, args...,
	).Scan(&total); err != nil {
		return PagedGames{}, err
	}
	offset := int64(query.Page-1) * int64(query.Size)
	listArgs := append(append([]any{}, args...), query.Size, offset)
	// #nosec G202 -- whereSQL, sortColumn and order are selected exclusively
	// from fixed server-side allowlists; every request value is bound.
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, package_id, name, author, version, remarks, tags_text, email, status,
		       original_filename, stored_path, manifest_json, scan_status,
		       scan_report, rejection_reason, created_at, updated_at, reviewed_at
		FROM games
		WHERE `+whereSQL+`
		ORDER BY `+sortColumn+` `+order+`, id DESC
		LIMIT ? OFFSET ?
	`, listArgs...)
	if err != nil {
		return PagedGames{}, err
	}
	defer rows.Close()
	games := make([]Game, 0)
	for rows.Next() {
		game, err := scanGame(rows)
		if err != nil {
			return PagedGames{}, err
		}
		games = append(games, game)
	}
	return PagedGames{
		Total: total, Current: query.Page, Size: query.Size, Data: games,
	}, rows.Err()
}

func (s *Store) GetCatalogGame(
	ctx context.Context,
	packageID string,
	status string,
) (Game, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT id, package_id, name, author, version, remarks, tags_text, email, status,
		       original_filename, stored_path, manifest_json, scan_status,
		       scan_report, rejection_reason, created_at, updated_at, reviewed_at
		FROM games
		WHERE package_id = ? AND status = ? AND stored_path <> ''
		ORDER BY updated_at DESC, id DESC
		LIMIT 1
	`, packageID, status)
	return scanGame(row)
}

func (s *Store) UpdateGameStatus(
	ctx context.Context,
	id int64,
	status string,
	reason string,
) (Game, error) {
	if status != StatusPending && status != StatusApproved && status != StatusRejected {
		return Game{}, errors.New("状态无效")
	}
	current, err := s.GetGame(ctx, id)
	if err != nil {
		return Game{}, err
	}
	if status == StatusApproved && current.StoredPath == "" {
		return Game{}, errors.New("已删除危险原包的记录不能批准")
	}
	now := time.Now().UnixMilli()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Game{}, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		UPDATE games
		SET status = ?, rejection_reason = ?, updated_at = ?, reviewed_at = ?
		WHERE id = ?
	`, status, reason, now, now, id)
	if err != nil {
		return Game{}, err
	}
	affected, _ := result.RowsAffected()
	if affected == 0 {
		return Game{}, ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO review_events(game_id, action, detail, created_at)
		VALUES(?, ?, ?, ?)
	`, id, status, reason, now); err != nil {
		return Game{}, err
	}
	if err := tx.Commit(); err != nil {
		return Game{}, err
	}
	return s.GetGame(ctx, id)
}

func (s *Store) DeleteGame(ctx context.Context, id int64) (string, error) {
	game, err := s.GetGame(ctx, id)
	if err != nil {
		return "", err
	}
	result, err := s.db.ExecContext(ctx, "DELETE FROM games WHERE id = ?", id)
	if err != nil {
		return "", err
	}
	affected, _ := result.RowsAffected()
	if affected == 0 {
		return "", ErrNotFound
	}
	return game.StoredPath, nil
}

func (s *Store) GetSettings(ctx context.Context) (Settings, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT key, value FROM server_settings
		WHERE key IN ('name', 'author', 'homepage', 'supports_game_relay')
	`)
	if err != nil {
		return Settings{}, err
	}
	defer rows.Close()
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
		}
	}
	return settings, rows.Err()
}

func (s *Store) UpdateSettings(ctx context.Context, settings Settings) error {
	now := time.Now().UnixMilli()
	values := map[string]string{
		"name":                strings.TrimSpace(settings.Name),
		"author":              strings.TrimSpace(settings.Author),
		"homepage":            strings.TrimSpace(settings.Homepage),
		"supports_game_relay": boolString(settings.SupportsGameRelay),
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for key, value := range values {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO server_settings(key, value, updated_at) VALUES(?, ?, ?)
			ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
		`, key, value, now); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) CreateAdminSession(
	ctx context.Context,
	tokenHash string,
	expiresAt time.Time,
) error {
	now := time.Now().UnixMilli()
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO admin_sessions(token_hash, expires_at, created_at)
		VALUES(?, ?, ?)
	`, tokenHash, expiresAt.UnixMilli(), now)
	return err
}

func (s *Store) AdminSessionValid(
	ctx context.Context,
	tokenHash string,
	now time.Time,
) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM admin_sessions
		WHERE token_hash = ? AND expires_at > ?
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

type rowScanner interface {
	Scan(dest ...any) error
}

func scanGame(row rowScanner) (Game, error) {
	var game Game
	err := row.Scan(
		&game.ID, &game.PackageID, &game.Name, &game.Author, &game.Version, &game.Remarks,
		&game.TagsText, &game.Email, &game.Status, &game.OriginalFilename,
		&game.StoredPath, &game.ManifestJSON, &game.ScanStatus,
		&game.ScanReport, &game.RejectionReason, &game.CreatedAt,
		&game.UpdatedAt, &game.ReviewedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return Game{}, ErrNotFound
	}
	return game, err
}

func boolString(value bool) string {
	if value {
		return "true"
	}
	return "false"
}
