package user

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/mail"
	"net/url"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/argon2"

	"go-server/internal/config"
	"go-server/internal/gameid"
	"go-server/internal/mailer"
	"go-server/internal/packages"
	"go-server/internal/qrimage"
	"go-server/internal/store"
	"go-server/internal/version"
)

const (
	sessionCookieName                 = "playmesh_user_session"
	csrfCookieName                    = "playmesh_csrf"
	userContextKey                    = "playmesh.user"
	sessionHashKey                    = "playmesh.user.session_hash"
	verificationResendHourlyLimit     = 5
	verificationResendMinimumInterval = time.Minute
	dummyPasswordHash                 = "$argon2id$v=19$m=65536,t=3,p=2$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
)

type captchaService interface {
	Challenge(c *gin.Context, scope string)
	Verify(c *gin.Context, scope string)
	ConsumeVerification(token string, scope string) bool
}

type Handler struct {
	config            config.Config
	store             *store.Store
	packages          *packages.Service
	mailer            *mailer.Mailer
	captcha           captchaService
	publicBaseURL     string
	publicBaseURLLock sync.RWMutex
}

func New(
	cfg config.Config,
	database *store.Store,
	packageService *packages.Service,
	mailService *mailer.Mailer,
	captcha captchaService,
) *Handler {
	return &Handler{
		config: cfg, store: database, packages: packageService,
		mailer: mailService, captcha: captcha, publicBaseURL: cfg.Relay.PublicBaseURL,
	}
}

const (
	userLoginCaptchaScope    = "user-login"
	userRegisterCaptchaScope = "user-register"
)

func (h *Handler) UpdatePublicBaseURL(value string) {
	h.publicBaseURLLock.Lock()
	h.publicBaseURL = value
	h.publicBaseURLLock.Unlock()
}

func (h *Handler) currentPublicBaseURL() string {
	h.publicBaseURLLock.RLock()
	value := h.publicBaseURL
	h.publicBaseURLLock.RUnlock()
	return strings.TrimRight(strings.TrimSpace(value), "/")
}

func (h *Handler) RegistrationState(c *gin.Context) {
	settings, err := h.store.GetSettings(c.Request.Context())
	if err != nil {
		writeError(c, http.StatusInternalServerError, "settings_failed", "无法读取注册配置")
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"allowUserRegistration":    settings.AllowUserRegistration,
		"requireEmailVerification": settings.RequireEmailVerification,
	})
}

func (h *Handler) Captcha(c *gin.Context) {
	scope, ok := userCaptchaScope(c.Query("purpose"))
	if !ok {
		writeError(c, http.StatusBadRequest, "invalid_request", "验证码用途无效")
		return
	}
	if h.captcha == nil {
		writeError(c, http.StatusInternalServerError, "captcha_failed", "验证码模块未初始化")
		return
	}
	h.captcha.Challenge(c, scope)
}

func (h *Handler) VerifyCaptcha(c *gin.Context) {
	scope, ok := userCaptchaScope(c.Query("purpose"))
	if !ok {
		writeError(c, http.StatusBadRequest, "invalid_request", "验证码用途无效")
		return
	}
	if h.captcha == nil {
		writeError(c, http.StatusInternalServerError, "captcha_failed", "验证码模块未初始化")
		return
	}
	h.captcha.Verify(c, scope)
}

func (h *Handler) Register(c *gin.Context) {
	settings, err := h.store.GetSettings(c.Request.Context())
	if err != nil {
		writeError(c, http.StatusInternalServerError, "settings_failed", "无法读取注册配置")
		return
	}
	// 注册开关必须先于验证码和密码哈希执行，避免关闭后仍消耗昂贵资源。
	if !settings.AllowUserRegistration {
		writeError(c, http.StatusForbidden, "registration_disabled", "当前游戏源未开放用户注册")
		return
	}
	var body struct {
		Email           string `json:"email"`
		Password        string `json:"password"`
		ConfirmPassword string `json:"confirmPassword"`
		CaptchaToken    string `json:"captchaToken"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		writeError(c, http.StatusBadRequest, "invalid_request", "注册参数无效")
		return
	}
	if h.captcha == nil ||
		!h.captcha.ConsumeVerification(body.CaptchaToken, userRegisterCaptchaScope) {
		writeError(c, http.StatusUnauthorized, "captcha_invalid", "验证码错误或已过期")
		return
	}
	email, err := normalizeEmail(body.Email)
	if err != nil {
		writeError(c, http.StatusBadRequest, "email_invalid", "邮箱格式无效")
		return
	}
	if body.Password != body.ConfirmPassword {
		writeError(c, http.StatusBadRequest, "password_confirmation_mismatch", "两次密码不一致")
		return
	}
	if !validPassword(body.Password) {
		writeError(c, http.StatusBadRequest, "password_invalid", "密码长度必须为 10 到 128 个字符")
		return
	}
	passwordHash, err := hashPassword(body.Password)
	if err != nil {
		writeError(c, http.StatusInternalServerError, "registration_failed", "注册失败")
		return
	}
	status := "active"
	if settings.RequireEmailVerification {
		status = "pending_verification"
	}
	created, err := h.store.CreateUser(
		c.Request.Context(), email, passwordHash, status,
	)
	if errors.Is(err, store.ErrEmailExists) {
		c.JSON(http.StatusAccepted, gin.H{"status": "registration_received"})
		return
	}
	if err != nil {
		writeError(c, http.StatusInternalServerError, "registration_failed", "注册失败")
		return
	}
	if status == "pending_verification" {
		// 邮件投递状态不能改变注册响应，否则会重新形成邮箱枚举信号。
		// 投递失败时用户仍可通过统一的重发入口再次请求。
		_ = h.sendVerification(c.Request.Context(), created)
	}
	c.JSON(http.StatusAccepted, gin.H{"status": "registration_received"})
}

func (h *Handler) Login(c *gin.Context) {
	var body struct {
		Email        string `json:"email"`
		Password     string `json:"password"`
		CaptchaToken string `json:"captchaToken"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		writeError(c, http.StatusBadRequest, "invalid_request", "登录参数无效")
		return
	}
	if h.captcha == nil ||
		!h.captcha.ConsumeVerification(body.CaptchaToken, userLoginCaptchaScope) {
		writeError(c, http.StatusUnauthorized, "captcha_invalid", "验证码错误或已过期")
		return
	}
	email, err := normalizeEmail(body.Email)
	if err != nil {
		writeError(c, http.StatusUnauthorized, "credentials_invalid", "邮箱或密码无效")
		return
	}
	account, passwordHash, err := h.store.GetUserByEmail(c.Request.Context(), email)
	lookupFailed := err != nil
	if lookupFailed {
		passwordHash = dummyPasswordHash
	}
	passwordValid := passwordMatches(body.Password, passwordHash)
	if lookupFailed || !passwordValid {
		writeError(c, http.StatusUnauthorized, "credentials_invalid", "邮箱或密码无效")
		return
	}
	disabled, err := h.store.UserDisabled(c.Request.Context(), account.ID)
	if err != nil {
		writeError(c, http.StatusInternalServerError, "login_failed", "无法读取账号状态")
		return
	}
	if disabled {
		writeError(c, http.StatusForbidden, "user_disabled", "账号已被管理员禁用")
		return
	}
	if account.Status != "active" {
		writeError(c, http.StatusForbidden, "email_verification_required", "请先验证邮箱后再登录")
		return
	}
	sessionToken, err := randomToken()
	if err != nil {
		writeError(c, http.StatusInternalServerError, "session_failed", "无法创建登录会话")
		return
	}
	csrfToken, err := randomToken()
	if err != nil {
		writeError(c, http.StatusInternalServerError, "session_failed", "无法创建登录会话")
		return
	}
	expiresAt := time.Now().Add(7 * 24 * time.Hour)
	if err := h.store.CreateUserSession(
		c.Request.Context(), account.ID, hashToken(sessionToken),
		hashToken(csrfToken), expiresAt,
	); err != nil {
		writeError(c, http.StatusInternalServerError, "session_failed", "无法创建登录会话")
		return
	}
	_ = h.store.CleanupUserSessions(c.Request.Context(), time.Now())
	h.setSessionCookie(c, sessionToken, int((7 * 24 * time.Hour).Seconds()))
	h.setCSRFCookie(c, csrfToken, int((7 * 24 * time.Hour).Seconds()))
	c.JSON(http.StatusOK, gin.H{"user": account, "csrfToken": csrfToken})
}

func userCaptchaScope(purpose string) (string, bool) {
	switch strings.TrimSpace(purpose) {
	case "login":
		return userLoginCaptchaScope, true
	case "register":
		return userRegisterCaptchaScope, true
	default:
		return "", false
	}
}

func (h *Handler) Logout(c *gin.Context) {
	sessionHash := c.GetString(sessionHashKey)
	if sessionHash != "" {
		_ = h.store.DeleteUserSession(c.Request.Context(), sessionHash)
	}
	h.setSessionCookie(c, "", -1)
	h.setCSRFCookie(c, "", -1)
	c.Status(http.StatusNoContent)
}

func (h *Handler) VerifyEmail(c *gin.Context) {
	token := strings.TrimSpace(c.Query("token"))
	if token == "" {
		c.Redirect(http.StatusSeeOther, "/my?emailVerification=failed")
		return
	}
	err := h.store.ConsumeEmailVerificationToken(
		c.Request.Context(), hashToken(token), time.Now(),
	)
	if err != nil {
		c.Redirect(http.StatusSeeOther, "/my?emailVerification=failed")
		return
	}
	c.Redirect(http.StatusSeeOther, "/my?emailVerification=success")
}

func (h *Handler) ResendVerification(c *gin.Context) {
	var body struct {
		Email string `json:"email"`
	}
	_ = c.ShouldBindJSON(&body)
	email, err := normalizeEmail(body.Email)
	if err == nil {
		account, _, lookupErr := h.store.GetUserByEmail(c.Request.Context(), email)
		if lookupErr == nil && account.Status == "pending_verification" {
			_ = h.reserveAndSendVerification(c.Request.Context(), account)
		}
	}
	c.JSON(http.StatusAccepted, gin.H{"status": "verification_requested"})
}

func (h *Handler) Me(c *gin.Context) {
	c.JSON(http.StatusOK, currentUser(c))
}

func (h *Handler) UpdateMe(c *gin.Context) {
	var body struct {
		DisplayName string `json:"displayName"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		writeError(c, http.StatusBadRequest, "invalid_request", "资料参数无效")
		return
	}
	body.DisplayName = strings.TrimSpace(body.DisplayName)
	if count := len([]rune(body.DisplayName)); count < 1 || count > 40 ||
		hasControl(body.DisplayName) {
		writeError(c, http.StatusBadRequest, "display_name_invalid", "展示名称必须为 1 到 40 个字符")
		return
	}
	updated, err := h.store.UpdateDisplayName(
		c.Request.Context(), currentUser(c).ID, body.DisplayName,
	)
	if err != nil {
		writeError(c, http.StatusInternalServerError, "profile_update_failed", "资料保存失败")
		return
	}
	c.JSON(http.StatusOK, updated)
}

func (h *Handler) PutUploadKey(c *gin.Context) {
	var body struct {
		Key      string `json:"key"`
		Generate bool   `json:"generate"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		writeError(c, http.StatusBadRequest, "invalid_request", "上传密钥参数无效")
		return
	}
	key := body.Key
	var err error
	if body.Generate {
		key, err = randomUploadKey()
		if err != nil {
			writeError(c, http.StatusInternalServerError, "upload_key_failed", "无法生成上传密钥")
			return
		}
	}
	if !validUploadKey(key) {
		writeError(c, http.StatusBadRequest, "upload_key_invalid", "上传密钥不符合复杂度要求")
		return
	}
	sourceQRCode, err := h.sourceQRCode(key)
	if err != nil {
		writeError(c, http.StatusInternalServerError, "source_qrcode_failed", "无法生成当前游戏源二维码")
		return
	}
	account := currentUser(c)
	ciphertext, err := h.encryptUploadKey(account.ID, key)
	if err != nil {
		writeError(c, http.StatusInternalServerError, "upload_key_failed", "上传密钥保存失败")
		return
	}
	if err := h.store.PutUploadCredentialEncrypted(
		c.Request.Context(), account.ID, h.uploadKeyHMAC(key), ciphertext,
	); err != nil {
		writeError(c, http.StatusInternalServerError, "upload_key_failed", "上传密钥保存失败")
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"uploadKey":    key,
		"sourceQRCode": "data:image/png;base64," + base64.StdEncoding.EncodeToString(sourceQRCode),
	})
}

func (h *Handler) GetUploadKey(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	account := currentUser(c)
	credential, err := h.store.UploadCredentialForUser(
		c.Request.Context(), account.ID,
	)
	if errors.Is(err, store.ErrNotFound) {
		c.JSON(http.StatusOK, gin.H{
			"configured":  false,
			"recoverable": false,
		})
		return
	}
	if err != nil {
		writeError(c, http.StatusInternalServerError, "upload_key_failed", "无法读取上传密钥")
		return
	}
	if credential.KeyCiphertext == "" {
		// Credentials created by older versions only contain a one-way HMAC.
		c.JSON(http.StatusOK, gin.H{
			"configured":  true,
			"recoverable": false,
		})
		return
	}
	key, err := h.decryptUploadKey(account.ID, credential.KeyCiphertext)
	if err != nil || !validUploadKey(key) ||
		!hmac.Equal(
			[]byte(h.uploadKeyHMAC(key)),
			[]byte(credential.KeyHMAC),
		) {
		writeError(
			c,
			http.StatusInternalServerError,
			"upload_key_reveal_failed",
			"上传密钥无法解密，请重新设置",
		)
		return
	}
	sourceQRCode, err := h.sourceQRCode(key)
	if err != nil {
		writeError(c, http.StatusInternalServerError, "source_qrcode_failed", "无法生成当前游戏源二维码")
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"configured":  true,
		"recoverable": true,
		"uploadKey":   key,
		"sourceQRCode": "data:image/png;base64," +
			base64.StdEncoding.EncodeToString(sourceQRCode),
	})
}

func (h *Handler) Games(c *gin.Context) {
	games, err := h.store.ListUserGames(c.Request.Context(), currentUser(c).ID)
	if err != nil {
		writeError(c, http.StatusInternalServerError, "games_failed", "无法读取个人游戏")
		return
	}
	c.JSON(http.StatusOK, gin.H{"data": games})
}

func (h *Handler) Notifications(c *gin.Context) {
	items, err := h.store.ListNotifications(
		c.Request.Context(), currentUser(c).ID, 50,
	)
	if err != nil {
		writeError(c, http.StatusInternalServerError, "notifications_failed", "无法读取站内通知")
		return
	}
	c.JSON(http.StatusOK, gin.H{"data": items})
}

func (h *Handler) ReadNotification(c *gin.Context) {
	id, err := parsePositiveInt64(c.Param("id"))
	if err != nil {
		writeError(c, http.StatusBadRequest, "invalid_id", "通知 ID 无效")
		return
	}
	if err := h.store.MarkNotificationRead(
		c.Request.Context(), currentUser(c).ID, id,
	); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(c, http.StatusNotFound, "notification_not_found", "通知不存在")
			return
		}
		writeError(c, http.StatusInternalServerError, "notification_update_failed", "无法更新通知")
		return
	}
	c.Status(http.StatusNoContent)
}

func (h *Handler) BrowserUpload(c *gin.Context) {
	h.processUpload(c, currentUser(c))
}

func (h *Handler) KeyUpload(c *gin.Context) {
	h.processUpload(c, currentUser(c))
}

func (h *Handler) processUpload(c *gin.Context, account store.User) {
	header, err := c.FormFile("package")
	if c.Request.MultipartForm != nil {
		defer c.Request.MultipartForm.RemoveAll()
	}
	if err != nil {
		writeError(c, http.StatusBadRequest, "package_required", "请选择 ZIP 游戏包")
		return
	}
	file, err := header.Open()
	if err != nil {
		writeError(c, http.StatusBadRequest, "package_invalid", "无法读取 ZIP 游戏包")
		return
	}
	defer file.Close()
	game, err := h.packages.ProcessUserUpload(
		c.Request.Context(), file, header.Filename, account,
	)
	if err != nil {
		h.writeUploadError(c, err)
		return
	}
	c.JSON(http.StatusAccepted, game)
}

func (h *Handler) Publish(c *gin.Context) {
	h.setPublished(c, true)
}

func (h *Handler) Unpublish(c *gin.Context) {
	h.setPublished(c, false)
}

func (h *Handler) setPublished(c *gin.Context, published bool) {
	id, ok := pathID(c)
	if !ok {
		return
	}
	account := currentUser(c)
	game, err := h.store.SetPublished(
		c.Request.Context(), id, store.UserReviewActor(account.ID), published,
	)
	if err != nil {
		writeStoreError(c, err)
		return
	}
	c.JSON(http.StatusOK, game)
}

func (h *Handler) DeleteGame(c *gin.Context) {
	id, ok := pathID(c)
	if !ok {
		return
	}
	account := currentUser(c)
	game, err := h.store.BeginDeleteOwnedGame(
		c.Request.Context(), id, store.UserReviewActor(account.ID),
	)
	if err != nil {
		writeStoreError(c, err)
		return
	}
	if err := packages.DeleteStoredFiles(
		h.config.Storage.GamesDirectory, game.StoredPath, game.IconPath,
	); err != nil {
		writeDeleteDeferred(c)
		return
	}
	if _, err := h.store.CompleteDeletingGame(
		c.Request.Context(), id, store.UserReviewActor(account.ID),
	); err != nil && !errors.Is(err, store.ErrNotFound) {
		writeDeleteDeferred(c)
		return
	}
	c.Status(http.StatusNoContent)
}

func (h *Handler) DeletePackage(c *gin.Context) {
	packageID := c.Param("gameId")
	if !gameid.Valid(packageID) {
		writeError(c, http.StatusBadRequest, "invalid_game_id", "gameId 无效")
		return
	}
	account := currentUser(c)
	games, err := h.store.BeginDeleteOwnedPackage(
		c.Request.Context(), packageID, store.UserReviewActor(account.ID),
	)
	if err != nil {
		writeStoreError(c, err)
		return
	}
	candidates := make([]string, 0, len(games)*2)
	for _, game := range games {
		candidates = append(candidates, game.StoredPath, game.IconPath)
	}
	if err := packages.DeleteStoredFiles(
		h.config.Storage.GamesDirectory, candidates...,
	); err != nil {
		writeDeleteDeferred(c)
		return
	}
	if _, err := h.store.CompleteDeletingPackage(
		c.Request.Context(), packageID, store.UserReviewActor(account.ID),
	); err != nil && !errors.Is(err, store.ErrNotFound) {
		writeDeleteDeferred(c)
		return
	}
	c.Status(http.StatusNoContent)
}

func writeDeleteDeferred(c *gin.Context) {
	c.JSON(http.StatusAccepted, gin.H{
		"code":    "deletion_pending",
		"status":  store.StatusDeleting,
		"message": "删除已进入后台清理队列",
	})
}

func (h *Handler) RequireSession(requireCSRF bool) gin.HandlerFunc {
	return func(c *gin.Context) {
		token, err := c.Cookie(sessionCookieName)
		if err != nil || token == "" {
			writeError(c, http.StatusUnauthorized, "user_unauthorized", "需要登录")
			c.Abort()
			return
		}
		sessionHash := hashToken(token)
		account, csrfHash, err := h.store.UserBySession(
			c.Request.Context(), sessionHash, time.Now(),
		)
		if err != nil || account.Status != "active" {
			writeError(c, http.StatusUnauthorized, "user_unauthorized", "登录会话无效或已过期")
			c.Abort()
			return
		}
		disabled, disabledErr := h.store.UserDisabled(
			c.Request.Context(), account.ID,
		)
		if disabledErr != nil || disabled {
			code := "user_unauthorized"
			message := "登录会话无效或已过期"
			if disabledErr == nil && disabled {
				code = "user_disabled"
				message = "账号已被管理员禁用"
			}
			writeError(c, http.StatusUnauthorized, code, message)
			c.Abort()
			return
		}
		if requireCSRF {
			provided := hashToken(strings.TrimSpace(c.GetHeader("X-CSRF-Token")))
			if subtle.ConstantTimeCompare([]byte(provided), []byte(csrfHash)) != 1 {
				writeError(c, http.StatusForbidden, "csrf_invalid", "CSRF Token 无效")
				c.Abort()
				return
			}
		}
		c.Set(userContextKey, account)
		c.Set(sessionHashKey, sessionHash)
		c.Next()
	}
}

func (h *Handler) RequireUploadKey() gin.HandlerFunc {
	return func(c *gin.Context) {
		header := strings.TrimSpace(c.GetHeader("Authorization"))
		scheme, key, ok := strings.Cut(header, " ")
		if !ok || scheme != "UploadKey" || !validUploadKey(key) {
			writeError(c, http.StatusUnauthorized, "upload_key_invalid", "上传密钥无效")
			c.Abort()
			return
		}
		account, err := h.store.UserByUploadCredential(
			c.Request.Context(), h.uploadKeyHMAC(key),
		)
		if err != nil {
			writeError(c, http.StatusUnauthorized, "upload_key_invalid", "上传密钥无效")
			c.Abort()
			return
		}
		disabled, disabledErr := h.store.UserDisabled(
			c.Request.Context(), account.ID,
		)
		if disabledErr != nil || disabled {
			code := "upload_key_invalid"
			message := "上传密钥无效"
			if disabledErr == nil && disabled {
				code = "user_disabled"
				message = "账号已被管理员禁用"
			}
			writeError(c, http.StatusForbidden, code, message)
			c.Abort()
			return
		}
		c.Set(userContextKey, account)
		c.Next()
	}
}

func (h *Handler) sendVerification(ctx context.Context, account store.User) error {
	token, err := randomToken()
	if err != nil {
		return err
	}
	if err := h.store.CreateEmailVerificationToken(
		ctx, account.ID, hashToken(token), time.Now().Add(24*time.Hour),
	); err != nil {
		return err
	}
	return h.deliverVerification(account, token)
}

func (h *Handler) reserveAndSendVerification(
	ctx context.Context,
	account store.User,
) error {
	token, err := randomToken()
	if err != nil {
		return err
	}
	now := time.Now()
	reserved, err := h.store.ReserveEmailVerificationToken(
		ctx,
		account.ID,
		hashToken(token),
		now,
		now.Add(24*time.Hour),
		verificationResendMinimumInterval,
		verificationResendHourlyLimit,
	)
	if err != nil || !reserved {
		return err
	}
	return h.deliverVerification(account, token)
}

func (h *Handler) deliverVerification(account store.User, token string) error {
	baseURL := h.currentPublicBaseURL()
	verificationURL := baseURL + "/api/user/auth/verify-email?token=" +
		url.QueryEscape(token)
	return h.mailer.SendEmailVerification(account.Email, verificationURL)
}

func (h *Handler) uploadKeyHMAC(key string) string {
	mac := hmac.New(sha256.New, []byte(h.config.UploadKeyPepper))
	_, _ = mac.Write([]byte(key))
	return hex.EncodeToString(mac.Sum(nil))
}

func (h *Handler) encryptUploadKey(userID int64, key string) (string, error) {
	aead, err := h.uploadKeyCipher()
	if err != nil {
		return "", err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	sealed := aead.Seal(
		nonce,
		nonce,
		[]byte(key),
		[]byte(fmt.Sprintf("playmesh-upload-key:%d", userID)),
	)
	return base64.RawURLEncoding.EncodeToString(sealed), nil
}

func (h *Handler) decryptUploadKey(userID int64, encoded string) (string, error) {
	aead, err := h.uploadKeyCipher()
	if err != nil {
		return "", err
	}
	sealed, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(sealed) < aead.NonceSize() {
		return "", errors.New("invalid upload key ciphertext")
	}
	nonce := sealed[:aead.NonceSize()]
	plaintext, err := aead.Open(
		nil,
		nonce,
		sealed[aead.NonceSize():],
		[]byte(fmt.Sprintf("playmesh-upload-key:%d", userID)),
	)
	if err != nil {
		return "", err
	}
	return string(plaintext), nil
}

func (h *Handler) uploadKeyCipher() (cipher.AEAD, error) {
	key := sha256.Sum256([]byte(h.config.UploadKeyPepper))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func (h *Handler) sourceQRCode(uploadKey string) ([]byte, error) {
	payload, err := h.sourceConfigurationURL(uploadKey)
	if err != nil {
		return nil, err
	}
	return qrimage.PNG(payload)
}

func (h *Handler) sourceConfigurationURL(uploadKey string) (string, error) {
	publicURL, err := url.Parse(strings.TrimRight(h.currentPublicBaseURL(), "/"))
	if err != nil || publicURL.Scheme == "" || publicURL.Host == "" {
		return "", errors.New("public URL is invalid")
	}
	query := publicURL.Query()
	query.Set("token", h.config.Auth.PublishedToken)
	query.Set("uploadKey", uploadKey)
	publicURL.RawQuery = query.Encode()
	return publicURL.String(), nil
}

func (h *Handler) setSessionCookie(c *gin.Context, value string, maxAge int) {
	c.SetSameSite(http.SameSiteLaxMode)
	c.SetCookie(
		sessionCookieName, value, maxAge, "/", "",
		requestIsHTTPS(c.Request), true,
	)
}

func (h *Handler) setCSRFCookie(c *gin.Context, value string, maxAge int) {
	c.SetSameSite(http.SameSiteLaxMode)
	c.SetCookie(
		csrfCookieName, value, maxAge, "/", "",
		requestIsHTTPS(c.Request), false,
	)
}

func requestIsHTTPS(request *http.Request) bool {
	if request != nil && request.TLS != nil {
		return true
	}
	if request == nil {
		return false
	}
	forwarded := strings.TrimSpace(strings.Split(
		request.Header.Get("X-Forwarded-Proto"), ",",
	)[0])
	return strings.EqualFold(forwarded, "https")
}

func (h *Handler) writeUploadError(c *gin.Context, err error) {
	var conflict *store.VersionConflictError
	if errors.As(err, &conflict) {
		code := "version_must_increase"
		if errors.Is(conflict, store.ErrVersionAlreadyExists) {
			code = "version_already_exists"
		}
		c.JSON(http.StatusConflict, gin.H{
			"code": code, "message": conflict.Error(),
			"currentHighestVersion": conflict.CurrentHighestVersion,
		})
		return
	}
	switch {
	case errors.Is(err, store.ErrOwnershipConflict):
		writeError(c, http.StatusConflict, "game_ownership_conflict", "gameId 已由其他账号持有")
	case errors.Is(err, version.ErrInvalid):
		writeError(c, http.StatusBadRequest, "invalid_version", "版本必须是无前缀的 MAJOR.MINOR.PATCH")
	default:
		var input *packages.InputError
		var rejected *packages.RejectedError
		var busy *packages.BusyError
		switch {
		case errors.As(err, &busy):
			writeError(c, http.StatusServiceUnavailable, "scanner_busy", busy.Error())
		case errors.As(err, &input):
			writeError(c, http.StatusBadRequest, "upload_invalid", input.Reason)
		case errors.As(err, &rejected):
			writeError(c, http.StatusUnprocessableEntity, "package_rejected", rejected.Reason)
		default:
			writeError(c, http.StatusInternalServerError, "upload_failed", "上传处理失败")
		}
	}
}

func writeStoreError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, store.ErrGameMustBeUnpublished):
		writeError(c, http.StatusConflict, "game_must_be_unpublished", err.Error())
	case errors.Is(err, store.ErrNotLatestVersion):
		writeError(c, http.StatusConflict, "not_latest_version", err.Error())
	case errors.Is(err, store.ErrInvalidGameState):
		writeError(c, http.StatusConflict, "invalid_game_state", err.Error())
	case errors.Is(err, store.ErrNotFound):
		writeError(c, http.StatusNotFound, "game_not_found", "游戏不存在")
	default:
		writeError(c, http.StatusInternalServerError, "game_operation_failed", "游戏操作失败")
	}
}

func writeError(c *gin.Context, status int, code string, message string) {
	c.JSON(status, gin.H{"code": code, "message": message})
}

func normalizeEmail(input string) (string, error) {
	value := strings.TrimSpace(input)
	address, err := mail.ParseAddress(value)
	if err != nil || !strings.EqualFold(address.Address, value) || len(value) > 320 {
		return "", errors.New("邮箱无效")
	}
	return strings.ToLower(address.Address), nil
}

func NormalizeEmail(input string) (string, error) {
	return normalizeEmail(input)
}

func HashPassword(password string) (string, error) {
	if !validPassword(password) {
		return "", errors.New("密码长度必须为 10 到 128 个字符")
	}
	return hashPassword(password)
}

func validPassword(value string) bool {
	count := len([]rune(value))
	return count >= 10 && count <= 128 && !hasControl(value)
}

func validUploadKey(value string) bool {
	count := len(value)
	if count < 10 || count > 128 {
		return false
	}
	var lower, upper, digit, special bool
	for _, character := range value {
		if unicode.IsSpace(character) || unicode.IsControl(character) {
			return false
		}
		switch {
		case unicode.IsLower(character):
			lower = true
		case unicode.IsUpper(character):
			upper = true
		case unicode.IsDigit(character):
			digit = true
		default:
			special = true
		}
	}
	return lower && upper && digit && special
}

func hasControl(value string) bool {
	for _, character := range value {
		if unicode.IsControl(character) {
			return true
		}
	}
	return false
}

func randomToken() (string, error) {
	value := make([]byte, 32)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func hashPassword(password string) (string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(password), salt, 3, 64*1024, 2, 32)
	return fmt.Sprintf(
		"$argon2id$v=19$m=65536,t=3,p=2$%s$%s",
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key),
	), nil
}

func passwordMatches(password string, encoded string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[1] != "argon2id" || parts[2] != "v=19" ||
		parts[3] != "m=65536,t=3,p=2" {
		return false
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil || len(salt) != 16 {
		return false
	}
	expected, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil || len(expected) != 32 {
		return false
	}
	actual := argon2.IDKey([]byte(password), salt, 3, 64*1024, 2, 32)
	return subtle.ConstantTimeCompare(actual, expected) == 1
}

func randomUploadKey() (string, error) {
	token, err := randomToken()
	if err != nil {
		return "", err
	}
	return "Pm!" + token + "aA1", nil
}

func hashToken(token string) string {
	hash := sha256.Sum256([]byte(token))
	return hex.EncodeToString(hash[:])
}

func currentUser(c *gin.Context) store.User {
	value, _ := c.Get(userContextKey)
	account, _ := value.(store.User)
	return account
}

func pathID(c *gin.Context) (int64, bool) {
	value, err := parsePositiveInt64(c.Param("id"))
	if err != nil {
		writeError(c, http.StatusBadRequest, "invalid_id", "游戏记录 ID 无效")
		return 0, false
	}
	return value, true
}

func parsePositiveInt64(value string) (int64, error) {
	var result int64
	if value == "" {
		return 0, errors.New("无效 ID")
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			return 0, errors.New("无效 ID")
		}
		next := result*10 + int64(character-'0')
		if next <= result {
			return 0, errors.New("无效 ID")
		}
		result = next
	}
	return result, nil
}
