package admin

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"go-server/internal/config"
	"go-server/internal/mailer"
	"go-server/internal/store"
)

func TestAdminUnpublishRequiresReasonAndNotifiesOwner(t *testing.T) {
	gin.SetMode(gin.TestMode)
	root := t.TempDir()
	cfg := config.Default()
	cfg.Storage.DatabasePath = filepath.Join(root, "server.db")
	cfg.Storage.GamesDirectory = filepath.Join(root, "games")
	cfg.Storage.QuarantineDirectory = filepath.Join(root, "quarantine")
	database, err := store.Open(cfg.Storage, store.Settings{})
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	owner, err := database.CreateUser(
		context.Background(), "owner@example.com", "hash", "active",
	)
	if err != nil {
		t.Fatal(err)
	}
	game, err := database.CreateOwnedGame(
		context.Background(),
		store.CreateGameInput{
			PackageID:        "com.example.notice",
			Name:             "Notice Game",
			Author:           "Owner",
			Version:          "1.0.0",
			OwnerUserID:      owner.ID,
			Status:           store.StatusApproved,
			Published:        true,
			OriginalFilename: "notice.zip",
			ManifestJSON:     `{"id":"com.example.notice","version":"1.0.0"}`,
			ScanStatus:       "clean",
			ScanReport:       "{}",
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	handler := NewHandler(
		cfg, database, nil, mailer.New(config.Mail{}), nil, nil,
	)
	engine := gin.New()
	engine.POST("/games/:id/unpublish", handler.AdminUnpublishGame)
	engine.DELETE("/games/:id", handler.AdminDeleteGame)
	path := "/games/" + strconv.FormatInt(game.ID, 10)

	missingReason := httptest.NewRecorder()
	request := httptest.NewRequest(
		http.MethodPost, path+"/unpublish", strings.NewReader(`{}`),
	)
	request.Header.Set("Content-Type", "application/json")
	engine.ServeHTTP(missingReason, request)
	if missingReason.Code != http.StatusBadRequest {
		t.Fatalf("缺少下架原因状态 = %d", missingReason.Code)
	}

	unpublished := httptest.NewRecorder()
	request = httptest.NewRequest(
		http.MethodPost,
		path+"/unpublish",
		strings.NewReader(`{"reason":"版权方要求下架"}`),
	)
	request.Header.Set("Content-Type", "application/json")
	engine.ServeHTTP(unpublished, request)
	if unpublished.Code != http.StatusOK {
		t.Fatalf("下架状态 = %d %s", unpublished.Code, unpublished.Body.String())
	}
	notifications, err := database.ListNotifications(
		context.Background(), owner.ID, 50,
	)
	if err != nil || len(notifications) != 1 ||
		notifications[0].Kind != "game_unpublished" ||
		!strings.Contains(notifications[0].Message, "版权方要求下架") {
		t.Fatalf("下架通知 = %#v, err=%v", notifications, err)
	}

	deleted := httptest.NewRecorder()
	request = httptest.NewRequest(
		http.MethodDelete,
		path,
		strings.NewReader(`{"reason":"清理违规版本"}`),
	)
	request.Header.Set("Content-Type", "application/json")
	engine.ServeHTTP(deleted, request)
	if deleted.Code != http.StatusNoContent {
		t.Fatalf("删除状态 = %d %s", deleted.Code, deleted.Body.String())
	}
	notifications, err = database.ListNotifications(
		context.Background(), owner.ID, 50,
	)
	if err != nil || len(notifications) != 2 ||
		notifications[0].Kind != "game_deleted" {
		t.Fatalf("删除通知 = %#v, err=%v", notifications, err)
	}
}

func TestEditableRelayPreservesEnvironmentOnlyTURNSecret(t *testing.T) {
	current := config.Default().Relay
	current.TURNSharedSecret = "environment-turn-secret-at-least-32-bytes"
	edited := current
	edited.TURNPublicIP = "203.0.113.8"
	edited.TURNSharedSecret = ""

	merged := relayFromEditable(current, edited)
	if merged.TURNPublicIP != edited.TURNPublicIP {
		t.Fatalf("TURN public IP = %q", merged.TURNPublicIP)
	}
	if merged.TURNSharedSecret != current.TURNSharedSecret {
		t.Fatal("admin relay edit discarded the environment-only TURN secret")
	}
}
