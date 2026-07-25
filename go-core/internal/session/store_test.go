package session

import (
	"errors"
	"testing"
)

func TestStoreAuthorityAndCapacity(t *testing.T) {
	store := NewStore()
	snapshot, host, err := store.Create(CreateInput{
		GameID: "fishing", DisplayMode: "single_screen_multiplayer",
		MinPlayers: 2, MaxPlayers: 2, Nickname: "房主",
	})
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	if snapshot.AuthorityClientID != host.Player.ID || host.Player.Role != "authority" || len(snapshot.Players) != 0 || len(host.Token) < 32 {
		t.Fatalf("authority or token is invalid: %#v %#v", snapshot, host)
	}
	if _, err := store.Start(snapshot.ID, host.Token); !errors.Is(err, ErrTooFewPlayers) {
		t.Fatalf("Start() error = %v, want ErrTooFewPlayers", err)
	}

	joined, guest, err := store.Join(JoinInput{JoinCode: snapshot.JoinCode, Nickname: "玩家一"})
	if err != nil || len(joined.Players) != 1 {
		t.Fatalf("Join() = %#v, %v", joined, err)
	}
	if _, _, err := store.Join(JoinInput{JoinCode: snapshot.JoinCode, Nickname: "玩家二"}); err != nil {
		t.Fatalf("second player Join() error = %v", err)
	}
	if _, _, err := store.Join(JoinInput{JoinCode: snapshot.JoinCode, Nickname: "玩家三"}); !errors.Is(err, ErrSessionFull) {
		t.Fatalf("third Join() error = %v, want ErrSessionFull", err)
	}
	if _, err := store.Start(snapshot.ID, guest.Token); !errors.Is(err, ErrNotAuthority) {
		t.Fatalf("guest Start() error = %v, want ErrNotAuthority", err)
	}
	running, err := store.Start(snapshot.ID, host.Token)
	if err != nil || running.State != StateRunning {
		t.Fatalf("host Start() = %#v, %v", running, err)
	}
}

func TestStoreRejectsInvalidTokenAndAllowsLateJoin(t *testing.T) {
	store := NewStore()
	snapshot, host, err := store.Create(CreateInput{
		GameID: "fishing", DisplayMode: "single_screen_multiplayer",
		MinPlayers: 1, MaxPlayers: 2, Nickname: "房主",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Snapshot(snapshot.ID, "wrong"); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("Snapshot() error = %v, want ErrUnauthorized", err)
	}
	if _, err := store.Start(snapshot.ID, host.Token); err != nil {
		if !errors.Is(err, ErrTooFewPlayers) {
			t.Fatal(err)
		}
		if _, _, joinErr := store.Join(JoinInput{JoinCode: snapshot.JoinCode, Nickname: "玩家一"}); joinErr != nil {
			t.Fatal(joinErr)
		}
		if _, err = store.Start(snapshot.ID, host.Token); err != nil {
			t.Fatal(err)
		}
	}
	late, _, err := store.Join(JoinInput{JoinCode: snapshot.JoinCode, Nickname: "迟到玩家"})
	if err != nil || late.State != StateRunning || len(late.Players) != 2 {
		t.Fatalf("late Join() = %#v, %v", late, err)
	}
}

func TestMultiScreenAppHostAuthorityDoesNotDependOnPlayerOrder(t *testing.T) {
	store := NewStore()
	snapshot, host, err := store.Create(CreateInput{
		GameID: "multi", DisplayMode: "multi_screen",
		MinPlayers: 1, MaxPlayers: 4, Nickname: "创建者",
	})
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.AuthorityClientID != host.Player.ID || host.Player.Role != "authority_player" {
		t.Fatalf("authority identity = %#v, snapshot = %#v", host.Player, snapshot)
	}
	if len(snapshot.Players) != 1 || snapshot.Players[0].ID != host.Player.ID {
		t.Fatalf("participating App host must be a player: %#v", snapshot.Players)
	}
	joined, guest, err := store.Join(JoinInput{
		JoinCode: snapshot.JoinCode, Nickname: "加入玩家",
	})
	if err != nil {
		t.Fatal(err)
	}
	if joined.AuthorityClientID != host.Player.ID || guest.Player.Role != "player" {
		t.Fatalf("joining a player changed Authority: host=%#v guest=%#v session=%#v", host.Player, guest.Player, joined)
	}
	if _, err := store.Start(snapshot.ID, guest.Token); !errors.Is(err, ErrNotAuthority) {
		t.Fatalf("joined player Start() error = %v, want ErrNotAuthority", err)
	}
	if running, err := store.Start(snapshot.ID, host.Token); err != nil || running.State != StateRunning {
		t.Fatalf("Start() = %#v, %v", running, err)
	}
}

func TestDisplayShareTokenLifecycle(t *testing.T) {
	store := NewStore()
	snapshot, host, err := store.Create(CreateInput{
		GameID: "fishing", DisplayMode: "single_screen_multiplayer",
		MinPlayers: 1, MaxPlayers: 4, Nickname: "房主",
	})
	if err != nil {
		t.Fatal(err)
	}
	grant, err := store.OpenShare(snapshot.ID, host.Token)
	if err != nil || grant.Token == "" {
		t.Fatalf("OpenShare() = %#v, %v", grant, err)
	}
	if _, _, err := store.Join(JoinInput{
		JoinCode: snapshot.JoinCode, Nickname: "无效链接", ShareToken: "wrong",
	}); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("wrong share token error = %v, want ErrUnauthorized", err)
	}
	if _, _, err := store.Join(JoinInput{
		JoinCode: snapshot.JoinCode, Nickname: "有效链接", ShareToken: grant.Token,
	}); err != nil {
		t.Fatalf("valid share token error = %v", err)
	}
	if err := store.CloseShare(snapshot.ID, host.Token); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Join(JoinInput{
		JoinCode: snapshot.JoinCode, Nickname: "关闭后链接", ShareToken: grant.Token,
	}); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("closed share token error = %v, want ErrUnauthorized", err)
	}
}

func TestResetAndBrowserRefreshCreateFreshPlayer(t *testing.T) {
	store := NewStore()
	snapshot, host, err := store.Create(CreateInput{
		GameID: "fishing", DisplayMode: "single_screen_multiplayer",
		MinPlayers: 1, MaxPlayers: 2, Nickname: "房主",
	})
	if err != nil {
		t.Fatal(err)
	}
	grant, err := store.OpenShare(snapshot.ID, host.Token)
	if err != nil {
		t.Fatal(err)
	}
	joined, first, err := store.Join(JoinInput{
		JoinCode: snapshot.JoinCode, Nickname: "同名玩家", ShareToken: grant.Token,
		PlayerID: "p_persistent_browser",
	})
	if err != nil {
		t.Fatal(err)
	}
	record, _, err := store.Authenticate(snapshot.ID, first.Token)
	if err != nil {
		t.Fatal(err)
	}
	connected := store.SetConnected(record, first.Player.ID, true)
	if len(connected.Players) != 1 || !connected.Players[0].Connected {
		t.Fatalf("connected snapshot = %#v", connected)
	}
	if running, err := store.Start(snapshot.ID, host.Token); err != nil || running.State != StateRunning {
		t.Fatalf("Start() = %#v, %v", running, err)
	}
	reset, err := store.Reset(snapshot.ID, host.Token)
	if err != nil || reset.State != StateLobby || reset.ID != snapshot.ID || reset.JoinCode != snapshot.JoinCode {
		t.Fatalf("Reset() = %#v, %v", reset, err)
	}
	disconnected := store.SetConnected(record, first.Player.ID, false)
	if len(disconnected.Players) != 1 || disconnected.Players[0].Connected {
		t.Fatalf("lobby disconnect should remain visible in room status: %#v", disconnected.Players)
	}
	if _, _, err := store.Authenticate(snapshot.ID, first.Token); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("old credential error = %v, want ErrUnauthorized", err)
	}
	refreshed, second, err := store.Join(JoinInput{
		JoinCode: joined.JoinCode, Nickname: "同名玩家", ShareToken: grant.Token,
		PlayerID: "p_persistent_browser",
	})
	if err != nil {
		t.Fatal(err)
	}
	if second.Player.ID != first.Player.ID || second.Player.Nickname != first.Player.Nickname || len(refreshed.Players) != 1 {
		t.Fatalf("refresh identities = %#v, %#v", first.Player, second.Player)
	}
	if len(refreshed.Players) != 1 || refreshed.Players[0].ID != second.Player.ID {
		t.Fatalf("refreshed snapshot = %#v", refreshed)
	}
}

func TestPlayerSourceAndLatencyRemainInUnifiedRoomSnapshot(t *testing.T) {
	store := NewStore()
	snapshot, _, err := store.Create(CreateInput{
		GameID: "room-status", DisplayMode: "single_screen_multiplayer",
		MinPlayers: 1, MaxPlayers: 3, Nickname: "Host",
	})
	if err != nil {
		t.Fatal(err)
	}
	_, guest, err := store.Join(JoinInput{
		JoinCode: snapshot.JoinCode,
		Nickname: "Remote App",
		PlayerID: "u_remote_app",
		Source:   "server",
	})
	if err != nil {
		t.Fatal(err)
	}
	record, _, err := store.Authenticate(snapshot.ID, guest.Token)
	if err != nil {
		t.Fatal(err)
	}
	store.TryConnect(record, guest.Player.ID)
	latency := 42
	withLatency := store.SetLatency(record, guest.Player.ID, &latency)
	if len(withLatency.Players) != 1 ||
		withLatency.Players[0].Source != "server" ||
		withLatency.Players[0].LatencyMS == nil ||
		*withLatency.Players[0].LatencyMS != latency {
		t.Fatalf("room status player = %#v", withLatency.Players)
	}
	disconnected := store.SetConnected(record, guest.Player.ID, false)
	if len(disconnected.Players) != 1 ||
		disconnected.Players[0].Connected ||
		disconnected.Players[0].LatencyMS != nil ||
		disconnected.Players[0].Source != "server" {
		t.Fatalf("disconnected room status player = %#v", disconnected.Players)
	}
}

func TestUpdateNicknameKeepsPlayerIdentity(t *testing.T) {
	store := NewStore()
	snapshot, _, err := store.Create(CreateInput{
		GameID: "fishing", DisplayMode: "single_screen_multiplayer",
		MinPlayers: 1, MaxPlayers: 2, Nickname: "房主",
	})
	if err != nil {
		t.Fatal(err)
	}
	_, guest, err := store.Join(JoinInput{JoinCode: snapshot.JoinCode, Nickname: "旧昵称"})
	if err != nil {
		t.Fatal(err)
	}
	updated, player, err := store.UpdateNickname(snapshot.ID, guest.Token, "  新昵称  ")
	if err != nil {
		t.Fatal(err)
	}
	if player.ID != guest.Player.ID || player.Nickname != "新昵称" {
		t.Fatalf("updated player = %#v, original = %#v", player, guest.Player)
	}
	if len(updated.Players) != 1 || updated.Players[0].Nickname != "新昵称" {
		t.Fatalf("updated snapshot = %#v", updated)
	}
	if _, _, err := store.UpdateNickname(snapshot.ID, guest.Token, ""); err == nil {
		t.Fatal("empty nickname should be rejected")
	}
	if _, _, err := store.UpdateNickname(snapshot.ID, "wrong", "昵称"); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("invalid token error = %v, want ErrUnauthorized", err)
	}
}

func TestAppPlayerUsesPersistentIDAndRejoinReplacesCredential(t *testing.T) {
	store := NewStore()
	snapshot, _, err := store.Create(CreateInput{
		GameID: "app-player", DisplayMode: "single_screen_multiplayer",
		MinPlayers: 1, MaxPlayers: 1, Nickname: "Host",
	})
	if err != nil {
		t.Fatal(err)
	}
	firstSnapshot, first, err := store.Join(JoinInput{
		JoinCode: snapshot.JoinCode, Nickname: "App Player", PlayerID: "u_device_123",
	})
	if err != nil {
		t.Fatal(err)
	}
	if first.Player.ID != "u_device_123" || len(firstSnapshot.Players) != 1 {
		t.Fatalf("first app identity = %#v, snapshot = %#v", first.Player, firstSnapshot)
	}
	record, _, err := store.Authenticate(snapshot.ID, first.Token)
	if err != nil {
		t.Fatal(err)
	}
	if _, connected := store.TryConnect(record, first.Player.ID); !connected {
		t.Fatal("first App player did not connect")
	}
	if _, _, err := store.Join(JoinInput{
		JoinCode: snapshot.JoinCode, Nickname: "App Player Updated", PlayerID: "u_device_123",
	}); !errors.Is(err, ErrPlayerConnected) {
		t.Fatalf("duplicate online App player error = %v, want ErrPlayerConnected", err)
	}
	store.SetConnected(record, first.Player.ID, false)
	secondSnapshot, second, err := store.Join(JoinInput{
		JoinCode: snapshot.JoinCode, Nickname: "App Player Updated", PlayerID: "u_device_123",
	})
	if err != nil {
		t.Fatal(err)
	}
	if second.Player.ID != first.Player.ID || len(secondSnapshot.Players) != 1 {
		t.Fatalf("rejoined app identity = %#v, snapshot = %#v", second.Player, secondSnapshot)
	}
	if _, _, err := store.Authenticate(snapshot.ID, first.Token); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("old app credential error = %v, want ErrUnauthorized", err)
	}
	if _, _, err := store.Join(JoinInput{
		JoinCode: snapshot.JoinCode, Nickname: "Invalid", PlayerID: "browser-forged-id",
	}); err == nil {
		t.Fatal("invalid App player ID was accepted")
	}
}

func TestFinishAndResetPruneOnlyDisconnectedPlayers(t *testing.T) {
	store := NewStore()
	snapshot, host, err := store.Create(CreateInput{
		GameID: "retention", DisplayMode: "single_screen_multiplayer",
		MinPlayers: 1, MaxPlayers: 2, Nickname: "Host",
	})
	if err != nil {
		t.Fatal(err)
	}
	_, guest, err := store.Join(JoinInput{
		JoinCode: snapshot.JoinCode, Nickname: "Browser", PlayerID: "p_retained",
	})
	if err != nil {
		t.Fatal(err)
	}
	record, _, err := store.Authenticate(snapshot.ID, guest.Token)
	if err != nil {
		t.Fatal(err)
	}
	store.TryConnect(record, guest.Player.ID)
	if _, err := store.Start(snapshot.ID, host.Token); err != nil {
		t.Fatal(err)
	}
	disconnected := store.SetConnected(record, guest.Player.ID, false)
	if len(disconnected.Players) != 1 || disconnected.Players[0].Connected {
		t.Fatalf("running disconnect was not retained: %#v", disconnected.Players)
	}
	finished, err := store.Finish(snapshot.ID, host.Token)
	if err != nil || finished.State != StateStopped || len(finished.Players) != 0 {
		t.Fatalf("Finish() = %#v, %v", finished, err)
	}
}
