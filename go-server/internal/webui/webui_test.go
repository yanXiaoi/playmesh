package webui

import (
	"encoding/json"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"go-server/internal/config"
	"go-server/internal/localization"
)

func TestWebLocaleResolversUseBrowserPreferenceListAndPrimaryLanguage(t *testing.T) {
	for _, name := range []string{"assets/user.js", "assets/admin.js"} {
		content, err := assets.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		source := string(content)
		for _, required := range []string{
			"navigator.languages",
			`split("-")[0].toLowerCase()`,
			"candidate.toLowerCase() === normalized.toLowerCase()",
			"candidate.split(\"-\")[0].toLowerCase() === primary",
			`cache: "no-store"`,
		} {
			if !strings.Contains(source, required) {
				t.Fatalf("%s 缺少语言匹配契约 %q", name, required)
			}
		}
		if strings.Contains(
			source,
			"available.includes(preferred) ? preferred : manifest.defaultLocale",
		) {
			t.Fatalf("%s 仍只支持精确 locale 匹配", name)
		}
		if !strings.Contains(source, "message ||") {
			t.Fatalf("%s 缺少未知 API code 的原始 message 回退", name)
		}
	}
}

func TestLocalizationResponsesRequireRevalidation(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := New(config.WebUI{
		DefaultLocale:     "zh-CN",
		EnabledLocales:    []string{"zh-CN", "en-US"},
		AllowLocaleSwitch: true,
	})
	for _, item := range []struct {
		name string
		call func(*gin.Context)
	}{
		{name: "manifest", call: handler.LocalizationManifest},
		{name: "bundle", call: handler.LocalizationBundle},
	} {
		t.Run(item.name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			context, _ := gin.CreateTestContext(recorder)
			if item.name == "bundle" {
				context.Params = []gin.Param{{Key: "locale", Value: "zh-CN"}}
			}
			item.call(context)
			if value := recorder.Header().Get("Cache-Control"); value != "no-cache" {
				t.Fatalf("Cache-Control = %q, want no-cache", value)
			}
		})
	}
}

func TestWebShellBootstrapsFixedLightUIAndLocaleBeforeFirstPaint(t *testing.T) {
	for _, item := range []struct {
		html string
		js   string
	}{
		{html: "assets/user.html", js: "assets/user.js"},
		{html: "assets/admin.html", js: "assets/admin.js"},
	} {
		content, err := assets.ReadFile(item.html)
		if err != nil {
			t.Fatal(err)
		}
		source := string(content)
		if strings.Contains(source, `<html lang="zh-CN">`) {
			t.Fatalf("%s 首帧仍写死 zh-CN", item.html)
		}
		bootstrap := strings.Index(source, "root.dataset.uiBooting")
		stylesheet := strings.Index(source, `rel="stylesheet"`)
		if bootstrap < 0 || stylesheet < 0 || bootstrap > stylesheet {
			t.Fatalf("%s 主题/语言预绘脚本没有位于样式表之前", item.html)
		}
		for _, required := range []string{
			`localStorage.getItem("playmesh.locale")`,
			"navigator.languages",
			`root.dataset.theme = "light"`,
			`root.style.colorScheme = "light"`,
			"window.__playmeshRevealUI",
		} {
			if !strings.Contains(source, required) {
				t.Fatalf("%s 缺少首帧契约 %q", item.html, required)
			}
		}

		for _, forbidden := range []string{
			`localStorage.getItem("playmesh.theme")`,
			`id="theme-toggle"`,
			`id="admin-theme"`,
		} {
			if strings.Contains(source, forbidden) {
				t.Fatalf("%s still contains theme switching UI %q", item.html, forbidden)
			}
		}

		script, err := assets.ReadFile(item.js)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(script), "window.__playmeshRevealUI?.()") {
			t.Fatalf("%s 本地化完成后没有解除首帧遮罩", item.js)
		}
	}

	stylesheet, err := assets.ReadFile("assets/style.css")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(
		string(stylesheet),
		"html[data-ui-booting] body",
	) || !strings.Contains(string(stylesheet), "visibility: hidden") {
		t.Fatal("Web UI 缺少首帧语言遮罩")
	}
}

func TestUserShellPlacesAuthenticationAndPublisherToolsInMyView(t *testing.T) {
	content, err := assets.ReadFile("assets/user.html")
	if err != nil {
		t.Fatal(err)
	}
	source := string(content)
	for _, required := range []string{
		`href="/my"`,
		`id="user-my-view"`,
		`id="auth-panel"`,
		`id="account-panel"`,
		`id="profile-dialog"`,
		`id="key-dialog"`,
		`id="upload-dialog"`,
		`data-open-dialog="profile-dialog"`,
		`data-open-dialog="key-dialog"`,
		`data-open-dialog="upload-dialog"`,
	} {
		if !strings.Contains(source, required) {
			t.Fatalf("user shell is missing My-view contract %q", required)
		}
	}
	if strings.Contains(source, `id="account-open"`) {
		t.Fatal("login must live inside the My view instead of the global header")
	}
	myView := strings.Index(source, `id="user-my-view"`)
	authPanel := strings.Index(source, `id="auth-panel"`)
	accountPanel := strings.Index(source, `id="account-panel"`)
	gamesView := strings.Index(source, `id="user-games-view"`)
	if myView < 0 || authPanel < myView || accountPanel < authPanel ||
		gamesView < accountPanel {
		t.Fatal("authentication and account content must be nested in the My view")
	}

	script, err := assets.ReadFile("assets/user.js")
	if err != nil {
		t.Fatal(err)
	}
	scriptSource := string(script)
	for _, required := range []string{
		`["/my", "/login", "/register"]`,
		`await jsonRequest("/api/user/me")`,
		`await showSignedOut(`,
		`.showModal()`,
	} {
		if !strings.Contains(scriptSource, required) {
			t.Fatalf("user script is missing protected My-view behavior %q", required)
		}
	}
}

func TestCaptchaLoadsInDialogsOnlyAfterAuthenticationSubmit(t *testing.T) {
	userHTML, err := assets.ReadFile("assets/user.html")
	if err != nil {
		t.Fatal(err)
	}
	userSource := string(userHTML)
	for _, required := range []string{
		`href="/assets/gocaptcha.global.css"`,
		`src="/assets/gocaptcha.global.js"`,
		`src="/assets/captcha.js"`,
		`id="auth-captcha-dialog"`,
		`id="user-captcha-widget"`,
	} {
		if !strings.Contains(userSource, required) {
			t.Fatalf("user CAPTCHA dialog is missing %q", required)
		}
	}
	loginFormStart := strings.Index(userSource, `id="login-form"`)
	registerFormStart := strings.Index(userSource, `id="register-form"`)
	captchaDialogStart := strings.Index(userSource, `id="auth-captcha-dialog"`)
	if loginFormStart < 0 || registerFormStart < loginFormStart ||
		captchaDialogStart < registerFormStart {
		t.Fatal("authentication forms and CAPTCHA dialog are out of order")
	}
	if strings.Contains(
		userSource[loginFormStart:captchaDialogStart],
		`data-captcha-image`,
	) {
		t.Fatal("CAPTCHA must not remain visible inside login or registration forms")
	}
	for _, forbidden := range []string{
		`id="auth-captcha-form"`,
		`id="auth-captcha-confirm"`,
		`id="auth-notice"`,
		`data-captcha-range`,
		`data-captcha-image`,
	} {
		if strings.Contains(userSource, forbidden) {
			t.Fatalf("user CAPTCHA must use the official component instead of %q", forbidden)
		}
	}
	officialScript := strings.Index(userSource, `src="/assets/gocaptcha.global.js"`)
	adapterScript := strings.Index(userSource, `src="/assets/captcha.js"`)
	userScriptIndex := strings.Index(userSource, `src="/assets/user.js"`)
	if officialScript < 0 || adapterScript <= officialScript ||
		userScriptIndex <= adapterScript {
		t.Fatal("official CAPTCHA, adapter, and user scripts are out of order")
	}

	adminHTML, err := assets.ReadFile("assets/admin.html")
	if err != nil {
		t.Fatal(err)
	}
	adminSource := string(adminHTML)
	for _, required := range []string{
		`gocaptcha.global.css`,
		`gocaptcha.global.js`,
		`captcha.js`,
		`id="admin-captcha-dialog"`,
		`id="admin-captcha-widget"`,
	} {
		if !strings.Contains(adminSource, required) {
			t.Fatalf("admin CAPTCHA UI is missing %q", required)
		}
	}
	for _, environmentOnly := range []string{
		`name="captchaMode"`,
		`name="captchaImageSource"`,
		`name="captchaImageDirectory"`,
		`name="captchaImageURL"`,
		`name="captchaImageCacheSize"`,
		`name="captchaInterval"`,
	} {
		if strings.Contains(adminSource, environmentOnly) {
			t.Fatalf("environment-only CAPTCHA setting is exposed in admin UI: %q", environmentOnly)
		}
	}
	for _, forbidden := range []string{
		`id="admin-captcha-form"`,
		`id="login-notice"`,
		`data-captcha-range`,
		`data-captcha-image`,
	} {
		if strings.Contains(adminSource, forbidden) {
			t.Fatalf("admin CAPTCHA must use the official component instead of %q", forbidden)
		}
	}

	userScript, err := assets.ReadFile("assets/user.js")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{
		`openAuthCaptcha("login"`,
		`openAuthCaptcha("register"`,
		`new window.PlaymeshCaptcha`,
		`confirm: (answer, reset)`,
	} {
		if !strings.Contains(string(userScript), required) {
			t.Fatalf("user CAPTCHA submit flow is missing %q", required)
		}
	}

	captchaScript, err := assets.ReadFile("assets/captcha.js")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{
		`window.GoCaptcha`,
		`text: "Click"`,
		`slide: "Slide"`,
		`rotate: "Rotate"`,
		`window.PlaymeshMessage`,
		`container.setAttribute("popover", "manual")`,
	} {
		if !strings.Contains(string(captchaScript), required) {
			t.Fatalf("CAPTCHA adapter is missing official-library contract %q", required)
		}
	}
}

func TestWebShellFixedCopyComesOnlyFromLocalizationBundles(t *testing.T) {
	directText := regexp.MustCompile(`(?s)data-i18n="[^"]+"[^>]*>([^<]*)<`)
	labelText := regexp.MustCompile(`(?s)data-i18n-label="[^"]+"[^>]*>([^<]*)<`)
	localizedAttribute := regexp.MustCompile(
		`(?s)<[^>]*data-i18n-(placeholder|aria|alt|title)="[^"]+"[^>]*>`,
	)
	localizationKey := regexp.MustCompile(
		`data-i18n(?:-label|-placeholder|-aria|-alt|-title)?="([^"]+)"`,
	)
	requiredKeys := make(map[string]struct{})
	for _, name := range []string{"assets/user.html", "assets/admin.html"} {
		content, err := assets.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		source := string(content)
		directMatches := directText.FindAllStringSubmatch(source, -1)
		if len(directMatches) != strings.Count(source, `data-i18n="`) {
			t.Fatalf("%s contains an unsupported data-i18n element shape", name)
		}
		for _, match := range directMatches {
			if strings.TrimSpace(match[1]) != "" {
				t.Fatalf("%s embeds localized element fallback %q", name, match[1])
			}
		}
		labelMatches := labelText.FindAllStringSubmatch(source, -1)
		if len(labelMatches) != strings.Count(source, `data-i18n-label="`) {
			t.Fatalf("%s contains an unsupported data-i18n-label shape", name)
		}
		for _, match := range labelMatches {
			if strings.TrimSpace(match[1]) != "" {
				t.Fatalf("%s embeds localized label fallback %q", name, match[1])
			}
		}
		for _, match := range localizedAttribute.FindAllStringSubmatch(source, -1) {
			target := map[string]string{
				"placeholder": "placeholder",
				"aria":        "aria-label",
				"alt":         "alt",
				"title":       "title",
			}[match[1]]
			valuePattern := regexp.MustCompile(
				`(?:^|\s)` + regexp.QuoteMeta(target) + `="([^"]*)"`,
			)
			value := valuePattern.FindStringSubmatch(match[0])
			if len(value) > 1 && strings.TrimSpace(value[1]) != "" {
				t.Fatalf(
					"%s embeds localized %s fallback %q",
					name, target, value[1],
				)
			}
		}
		for _, match := range localizationKey.FindAllStringSubmatch(source, -1) {
			requiredKeys[match[1]] = struct{}{}
		}
	}

	catalog, err := localization.Load()
	if err != nil {
		t.Fatal(err)
	}
	for _, locale := range catalog.EnabledLocaleIDs() {
		content, ok := catalog.Bundle(locale)
		if !ok {
			t.Fatalf("missing localization bundle %s", locale)
		}
		var messages map[string]string
		if err := json.Unmarshal(content, &messages); err != nil {
			t.Fatal(err)
		}
		for key := range requiredKeys {
			if strings.TrimSpace(messages[key]) == "" {
				t.Fatalf("%s is missing fixed UI key %s", locale, key)
			}
		}
	}

	for _, name := range []string{"assets/user.js", "assets/admin.js"} {
		content, err := assets.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		source := string(content)
		for _, required := range []string{
			`document.createTextNode("")`,
			"element.prepend(textNode)",
			"textNode.nodeValue =",
			"element.dataset.i18nLabel",
			"window.__playmeshRevealUI?.()",
		} {
			if !strings.Contains(source, required) {
				t.Fatalf("%s cannot localize empty fixed-copy nodes: %q", name, required)
			}
		}
	}
}
