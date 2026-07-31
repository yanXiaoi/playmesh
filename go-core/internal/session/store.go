package session

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"regexp"
	"strings"
	"sync"
)

var (
	ErrNotFound        = errors.New("会话不存在")
	ErrUnauthorized    = errors.New("会话凭证无效")
	ErrSessionFull     = errors.New("会话人数已满")
	ErrSessionStarted  = errors.New("会话已经开始")
	ErrPlayerConnected = errors.New("玩家身份已有在线连接")
	ErrTooFewPlayers   = errors.New("当前人数不足以开始游戏")
	ErrNotAuthority    = errors.New("只有权威玩家可以执行此操作")
)

type State string

const (
	StateLobby   State = "lobby"
	StateRunning State = "running"
	StatePaused  State = "paused"
	StateStopped State = "stopped"
)

type Player struct {
	ID           string  `json:"id"`
	Nickname     string  `json:"nickname"`
	Avatar       *string `json:"avatar"`
	Role         string  `json:"role"`
	Source       string  `json:"source"`
	Connected    bool    `json:"connected"`
	AvatarDigest string  `json:"-"`
	access       playerAccess
}

type Snapshot struct {
	ID                string   `json:"id"`
	JoinCode          string   `json:"joinCode"`
	GameID            string   `json:"gameId"`
	DisplayMode       string   `json:"displayMode"`
	State             State    `json:"state"`
	MinPlayers        int      `json:"minPlayers"`
	MaxPlayers        int      `json:"maxPlayers"`
	AuthorityClientID string   `json:"authorityClientId"`
	Players           []Player `json:"players"`
}

type Credentials struct {
	Player      Player `json:"player"`
	Token       string `json:"token"`
	Reconnected bool   `json:"reconnected"`
}

type CreateInput struct {
	GameID, DisplayMode, Nickname string
	MinPlayers, MaxPlayers        int
}

type JoinInput struct {
	JoinCode, Nickname, ShareToken, PlayerID string
	Access                                   playerAccess
}

type playerAccess uint8

const (
	playerAccessLANHTML playerAccess = iota
	playerAccessLANApp
	playerAccessServer
)

func (access playerAccess) source() string {
	switch access {
	case playerAccessLANApp:
		return "lan_app"
	case playerAccessServer:
		return "server"
	default:
		return "lan_html"
	}
}

func (access playerAccess) canUploadAvatar() bool {
	return access == playerAccessLANApp
}

type ShareGrant struct {
	Token string `json:"token"`
}

type record struct {
	mutex                             sync.RWMutex
	id, joinCode, gameID, displayMode string
	state                             State
	minPlayers, maxPlayers            int
	authority                         Player
	players                           map[string]Player
	tokens                            map[[32]byte]string
	shareTokenHash                    [32]byte
}

type Store struct {
	mutex       sync.RWMutex
	sessions    map[string]*record
	joinCodeIDs map[string]string
}

func NewStore() *Store {
	return &Store{sessions: make(map[string]*record), joinCodeIDs: make(map[string]string)}
}

func (s *Store) Create(input CreateInput) (Snapshot, Credentials, error) {
	if strings.TrimSpace(input.GameID) == "" || strings.TrimSpace(input.DisplayMode) == "" ||
		input.MinPlayers < 1 || input.MaxPlayers < input.MinPlayers || input.MaxPlayers > 16 {
		return Snapshot{}, Credentials{}, errors.New("创建会话参数无效")
	}
	// Authority is always the App runtime that creates the session. Whether that
	// same App also participates as a player is a separate display-mode concern;
	// player order never elects or transfers Authority.
	authorityName := input.Nickname
	if input.DisplayMode == "single_screen_multiplayer" {
		authorityName = "公共显示端"
	}
	authority, token, tokenHash, err := newIdentity(authorityName, "authority")
	if err != nil {
		return Snapshot{}, Credentials{}, err
	}
	hostParticipatesAsPlayer := input.DisplayMode == "multi_screen"
	if hostParticipatesAsPlayer {
		authority.Role = "authority_player"
	}
	authority.Source = "lan_app"
	authority.access = playerAccessLANApp
	id, err := randomID("s_", 16)
	if err != nil {
		return Snapshot{}, Credentials{}, err
	}
	joinCode, err := s.uniqueJoinCode()
	if err != nil {
		return Snapshot{}, Credentials{}, err
	}
	players := make(map[string]Player)
	if hostParticipatesAsPlayer {
		players[authority.ID] = authority
	}
	record := &record{
		id: id, joinCode: joinCode, gameID: input.GameID, displayMode: input.DisplayMode,
		state: StateLobby, minPlayers: input.MinPlayers, maxPlayers: input.MaxPlayers,
		authority: authority, players: players,
		tokens: map[[32]byte]string{tokenHash: authority.ID},
	}
	s.mutex.Lock()
	s.sessions[id], s.joinCodeIDs[joinCode] = record, id
	s.mutex.Unlock()
	return record.snapshot(), Credentials{Player: authority, Token: token}, nil
}

func (s *Store) Join(input JoinInput) (Snapshot, Credentials, error) {
	record, err := s.byJoinCode(input.JoinCode)
	if err != nil {
		return Snapshot{}, Credentials{}, err
	}
	player, token, tokenHash, err := newIdentityWithID(input.Nickname, "player", input.PlayerID)
	if err != nil {
		return Snapshot{}, Credentials{}, err
	}
	player.Source = input.Access.source()
	player.access = input.Access
	record.mutex.Lock()
	defer record.mutex.Unlock()
	if input.ShareToken != "" && sha256.Sum256([]byte(input.ShareToken)) != record.shareTokenHash {
		return Snapshot{}, Credentials{}, ErrUnauthorized
	}
	existing, replacing := record.players[player.ID]
	if !replacing && len(record.players) >= record.maxPlayers {
		return Snapshot{}, Credentials{}, ErrSessionFull
	}
	if replacing && existing.Connected {
		return Snapshot{}, Credentials{}, ErrPlayerConnected
	}
	if replacing {
		if existing.access != player.access {
			return Snapshot{}, Credentials{}, ErrUnauthorized
		}
		player.Avatar = existing.Avatar
		player.AvatarDigest = existing.AvatarDigest
	}
	record.players[player.ID], record.tokens[tokenHash] = player, player.ID
	return record.snapshotLocked(), Credentials{
		Player: player, Token: token, Reconnected: replacing,
	}, nil
}

func (s *Store) OpenShare(sessionID, token string) (ShareGrant, error) {
	record, identity, err := s.Authenticate(sessionID, token)
	if err != nil {
		return ShareGrant{}, err
	}
	if identity.ID != record.authority.ID {
		return ShareGrant{}, ErrNotAuthority
	}
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return ShareGrant{}, err
	}
	shareToken := base64.RawURLEncoding.EncodeToString(raw)
	record.mutex.Lock()
	record.shareTokenHash = sha256.Sum256([]byte(shareToken))
	record.mutex.Unlock()
	return ShareGrant{Token: shareToken}, nil
}

func (s *Store) CloseShare(sessionID, token string) error {
	record, identity, err := s.Authenticate(sessionID, token)
	if err != nil {
		return err
	}
	if identity.ID != record.authority.ID {
		return ErrNotAuthority
	}
	record.mutex.Lock()
	record.shareTokenHash = [32]byte{}
	record.mutex.Unlock()
	return nil
}

func (s *Store) Authenticate(sessionID, token string) (*record, Player, error) {
	record, err := s.get(sessionID)
	if err != nil {
		return nil, Player{}, err
	}
	record.mutex.RLock()
	defer record.mutex.RUnlock()
	playerID, ok := record.tokens[sha256.Sum256([]byte(token))]
	if !ok {
		return nil, Player{}, ErrUnauthorized
	}
	if playerID == record.authority.ID {
		return record, record.authority, nil
	}
	return record, record.players[playerID], nil
}

func (s *Store) Start(sessionID, token string) (Snapshot, error) {
	record, player, err := s.Authenticate(sessionID, token)
	if err != nil {
		return Snapshot{}, err
	}
	record.mutex.Lock()
	defer record.mutex.Unlock()
	if player.ID != record.authority.ID {
		return Snapshot{}, ErrNotAuthority
	}
	if record.state != StateLobby && record.state != StatePaused && record.state != StateStopped {
		return Snapshot{}, ErrSessionStarted
	}
	if len(record.players) < record.minPlayers {
		return Snapshot{}, ErrTooFewPlayers
	}
	record.state = StateRunning
	return record.snapshotLocked(), nil
}

func (s *Store) Reset(sessionID, token string) (Snapshot, error) {
	record, player, err := s.Authenticate(sessionID, token)
	if err != nil {
		return Snapshot{}, err
	}
	record.mutex.Lock()
	defer record.mutex.Unlock()
	if player.ID != record.authority.ID {
		return Snapshot{}, ErrNotAuthority
	}
	record.state = StateLobby
	record.pruneDisconnectedLocked()
	return record.snapshotLocked(), nil
}

func (s *Store) Finish(sessionID, token string) (Snapshot, error) {
	record, player, err := s.Authenticate(sessionID, token)
	if err != nil {
		return Snapshot{}, err
	}
	record.mutex.Lock()
	defer record.mutex.Unlock()
	if player.ID != record.authority.ID {
		return Snapshot{}, ErrNotAuthority
	}
	record.state = StateStopped
	record.authority.Avatar, record.authority.AvatarDigest = nil, ""
	if _, participates := record.players[record.authority.ID]; participates {
		record.players[record.authority.ID] = record.authority
	}
	for playerID, current := range record.players {
		current.Avatar, current.AvatarDigest = nil, ""
		record.players[playerID] = current
	}
	record.pruneDisconnectedLocked()
	return record.snapshotLocked(), nil
}

func (s *Store) Snapshot(sessionID, token string) (Snapshot, error) {
	record, _, err := s.Authenticate(sessionID, token)
	if err != nil {
		return Snapshot{}, err
	}
	return record.snapshot(), nil
}

func (s *Store) UpdateNickname(sessionID, token, nickname string) (Snapshot, Player, error) {
	nickname, err := validateNickname(nickname)
	if err != nil {
		return Snapshot{}, Player{}, err
	}
	record, player, err := s.Authenticate(sessionID, token)
	if err != nil {
		return Snapshot{}, Player{}, err
	}
	record.mutex.Lock()
	defer record.mutex.Unlock()
	if player.ID == record.authority.ID {
		record.authority.Nickname = nickname
		player = record.authority
		if _, isPlayer := record.players[player.ID]; isPlayer {
			record.players[player.ID] = player
		}
	} else {
		current, exists := record.players[player.ID]
		if !exists {
			return Snapshot{}, Player{}, ErrUnauthorized
		}
		current.Nickname = nickname
		record.players[player.ID] = current
		player = current
	}
	return record.snapshotLocked(), player, nil
}

func (s *Store) CommitAvatar(record *record, playerID, digest string) (Snapshot, Player, error) {
	record.mutex.Lock()
	defer record.mutex.Unlock()
	avatar := "/bucket/_sys-user-avatars/" + playerID + ".png"
	if playerID == record.authority.ID {
		if !record.authority.access.canUploadAvatar() {
			return Snapshot{}, Player{}, ErrUnauthorized
		}
		record.authority.Avatar, record.authority.AvatarDigest = &avatar, digest
		if _, participates := record.players[playerID]; participates {
			record.players[playerID] = record.authority
		}
		return record.snapshotLocked(), record.authority, nil
	}
	player, exists := record.players[playerID]
	if !exists || !player.access.canUploadAvatar() {
		return Snapshot{}, Player{}, ErrUnauthorized
	}
	player.Avatar, player.AvatarDigest = &avatar, digest
	record.players[playerID] = player
	return record.snapshotLocked(), player, nil
}

func (s *Store) SetConnected(record *record, playerID string, connected bool) Snapshot {
	record.mutex.Lock()
	defer record.mutex.Unlock()
	if playerID == record.authority.ID {
		record.authority.Connected = connected
		if _, isPlayer := record.players[playerID]; isPlayer {
			player := record.authority
			record.players[playerID] = player
		}
	} else {
		player := record.players[playerID]
		player.Connected = connected
		record.players[playerID] = player
	}
	if !connected && playerID != record.authority.ID {
		for tokenHash, tokenPlayerID := range record.tokens {
			if tokenPlayerID == playerID {
				delete(record.tokens, tokenHash)
			}
		}
	}
	if !connected && playerID == record.authority.ID && record.state == StateRunning {
		record.state = StatePaused
	}
	return record.snapshotLocked()
}

func (s *Store) TryConnect(record *record, playerID string) (Snapshot, bool) {
	record.mutex.Lock()
	defer record.mutex.Unlock()
	if playerID == record.authority.ID {
		if record.authority.Connected {
			return record.snapshotLocked(), false
		}
		record.authority.Connected = true
		if _, isPlayer := record.players[playerID]; isPlayer {
			record.players[playerID] = record.authority
		}
		return record.snapshotLocked(), true
	}
	player, exists := record.players[playerID]
	if !exists || player.Connected {
		return record.snapshotLocked(), false
	}
	player.Connected = true
	record.players[playerID] = player
	return record.snapshotLocked(), true
}

func (s *Store) get(id string) (*record, error) {
	s.mutex.RLock()
	record := s.sessions[id]
	s.mutex.RUnlock()
	if record == nil {
		return nil, ErrNotFound
	}
	return record, nil
}

func (s *Store) byJoinCode(joinCode string) (*record, error) {
	s.mutex.RLock()
	id := s.joinCodeIDs[strings.ToUpper(strings.TrimSpace(joinCode))]
	record := s.sessions[id]
	s.mutex.RUnlock()
	if record == nil {
		return nil, ErrNotFound
	}
	return record, nil
}

func (s *Store) uniqueJoinCode() (string, error) {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	for range 8 {
		bytes := make([]byte, 6)
		if _, err := rand.Read(bytes); err != nil {
			return "", err
		}
		for index := range bytes {
			bytes[index] = alphabet[int(bytes[index])%len(alphabet)]
		}
		code := string(bytes)
		s.mutex.RLock()
		_, exists := s.joinCodeIDs[code]
		s.mutex.RUnlock()
		if !exists {
			return code, nil
		}
	}
	return "", errors.New("无法生成唯一加入码")
}

func (r *record) snapshot() Snapshot {
	r.mutex.RLock()
	defer r.mutex.RUnlock()
	return r.snapshotLocked()
}

func (r *record) authorityConnected() bool {
	r.mutex.RLock()
	defer r.mutex.RUnlock()
	return r.authority.Connected
}

func (r *record) snapshotLocked() Snapshot {
	players := make([]Player, 0, len(r.players))
	for _, player := range r.players {
		players = append(players, player)
	}
	return Snapshot{ID: r.id, JoinCode: r.joinCode, GameID: r.gameID, DisplayMode: r.displayMode,
		State: r.state, MinPlayers: r.minPlayers, MaxPlayers: r.maxPlayers,
		AuthorityClientID: r.authority.ID, Players: players}
}

func (r *record) pruneDisconnectedLocked() {
	for playerID, player := range r.players {
		if playerID != r.authority.ID && !player.Connected {
			delete(r.players, playerID)
			for tokenHash, tokenPlayerID := range r.tokens {
				if tokenPlayerID == playerID {
					delete(r.tokens, tokenHash)
				}
			}
		}
	}
}

func normalizeClaimedPlayerSource(value string) (string, error) {
	switch strings.TrimSpace(value) {
	case "", "lan_html":
		return "lan_html", nil
	case "lan_app":
		return "lan_app", nil
	case "server":
		return "server", nil
	default:
		return "", errors.New("玩家来源无效")
	}
}

func newIdentity(nickname, role string) (Player, string, [32]byte, error) {
	return newIdentityWithID(nickname, role, "")
}

var playerIDPattern = regexp.MustCompile(`^[pu]_[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func newIdentityWithID(nickname, role, requestedID string) (Player, string, [32]byte, error) {
	nickname, err := validateNickname(nickname)
	if err != nil {
		return Player{}, "", [32]byte{}, err
	}
	id := strings.TrimSpace(requestedID)
	if id == "" {
		id, err = randomID("p_", 12)
		if err != nil {
			return Player{}, "", [32]byte{}, err
		}
	} else if !playerIDPattern.MatchString(id) {
		return Player{}, "", [32]byte{}, errors.New("App 玩家 ID 无效")
	}
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil {
		return Player{}, "", [32]byte{}, err
	}
	token := base64.RawURLEncoding.EncodeToString(tokenBytes)
	return Player{ID: id, Nickname: nickname, Role: role}, token, sha256.Sum256([]byte(token)), nil
}

func validateNickname(nickname string) (string, error) {
	nickname = strings.TrimSpace(nickname)
	if nickname == "" || len([]rune(nickname)) > 32 {
		return "", errors.New("玩家昵称无效")
	}
	return nickname, nil
}

func randomID(prefix string, byteCount int) (string, error) {
	value := make([]byte, byteCount)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return prefix + hex.EncodeToString(value), nil
}
