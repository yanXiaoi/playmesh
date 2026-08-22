package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateRejectsInvalidRelayLimits(t *testing.T) {
	cfg := Default()
	cfg.Relay.MaxTunnels = 0
	if err := cfg.Validate(); err == nil {
		t.Fatal("无效中转限制未被拒绝")
	}
}

func TestValidateAllowsOptionalDeclarationFields(t *testing.T) {
	cfg := Default()
	cfg.Name = ""
	cfg.Author = ""
	cfg.Homepage = ""
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestDefaultStorageBudgetSupportsLargeHTMLGames(t *testing.T) {
	storage := Default().Storage
	if storage.MaxUploadBytes != 100<<20 ||
		storage.MaxExpandedBytes != 512<<20 ||
		storage.MaxFileBytes != 128<<20 ||
		storage.MaxFiles != 8000 {
		t.Fatalf("默认游戏包预算 = %+v", storage)
	}
}

func TestDefaultScannerDoesNotRejectRetiredContentPatterns(t *testing.T) {
	retired := map[string]struct{}{
		"external-http-ws":            {},
		"protocol-relative-attribute": {},
		"protocol-relative-css":       {},
		"protocol-relative-script":    {},
		"function-constructor":        {},
		"file-protocol":               {},
		"javascript-url":              {},
		"embedded-document":           {},
	}
	for _, rule := range Default().Scanner.ContentRules {
		if _, exists := retired[rule.ID]; exists {
			t.Fatalf("默认扫描器仍包含已取消规则 %q", rule.ID)
		}
	}
}

func TestNormalizeRetiresOnlyExactLegacyContentRules(t *testing.T) {
	cfg := Default()
	cfg.Scanner.ContentRules = append(cfg.Scanner.ContentRules,
		ContentRule{
			ID: "external-http-ws", Description: "legacy",
			Pattern: `(?i)(?:https?|wss?)://`, Enabled: true,
		},
		ContentRule{
			ID: "protocol-relative-attribute", Description: "legacy",
			Pattern: `(?i)(?:src|href|action)\s*=\s*["']//`, Enabled: true,
		},
		ContentRule{
			ID: "protocol-relative-css", Description: "legacy",
			Pattern: `(?i)url\s*\(\s*["']?//`, Enabled: true,
		},
		ContentRule{
			ID: "protocol-relative-script", Description: "legacy",
			Pattern: `(?i)["']\s*//[a-z0-9]`, Enabled: true,
		},
		ContentRule{
			ID: "function-constructor", Description: "legacy",
			Pattern: `(?i)new\s+Function\s*\(`, Enabled: true,
		},
		ContentRule{
			ID: "file-protocol", Description: "legacy",
			Pattern: `(?i)file://`, Enabled: true,
		},
		ContentRule{
			ID: "javascript-url", Description: "legacy",
			Pattern: `(?i)javascript\s*:`, Enabled: true,
		},
		ContentRule{
			ID: "embedded-document", Description: "legacy",
			Pattern: `(?i)<\s*(iframe|object|embed)\b`, Enabled: true,
		},
		ContentRule{
			ID: "operator-custom-link-policy", Description: "custom",
			Pattern: `https://blocked\.example`, Enabled: true,
		},
	)
	cfg.normalize()
	for _, rule := range cfg.Scanner.ContentRules {
		if isRetiredDefaultContentRule(rule) {
			t.Fatalf("历史默认规则未被迁移删除: %+v", rule)
		}
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("迁移后配置无效: %v", err)
	}
	customFound := false
	for _, rule := range cfg.Scanner.ContentRules {
		customFound = customFound || rule.ID == "operator-custom-link-policy"
	}
	if !customFound {
		t.Fatal("部署者自定义内容规则被错误删除")
	}
}

func TestValidateRelayPublicBaseURL(t *testing.T) {
	tests := []struct {
		name          string
		publicBaseURL string
		valid         bool
	}{
		{
			name:          "HTTP is allowed when TLS is optional",
			publicBaseURL: "http://relay.example.com:16668",
			valid:         true,
		},
		{
			name:          "HTTPS is allowed",
			publicBaseURL: "https://relay.example.com",
			valid:         true,
		},
		{
			name:          "Path is rejected",
			publicBaseURL: "https://relay.example.com/public",
		},
		{
			name:          "Query is rejected",
			publicBaseURL: "https://relay.example.com?target=other",
		},
		{
			name:          "Credentials are rejected",
			publicBaseURL: "https://user:secret@relay.example.com",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := Default()
			cfg.Relay.PublicBaseURL = test.publicBaseURL
			err := cfg.Validate()
			if test.valid && err != nil {
				t.Fatal(err)
			}
			if !test.valid && err == nil {
				t.Fatal("无效的公共中转地址未被拒绝")
			}
		})
	}
}

func TestValidateCaptchaImageSources(t *testing.T) {
	t.Run("local directory", func(t *testing.T) {
		cfg := Default()
		cfg.Admin.CaptchaMode = "slide"
		cfg.Admin.CaptchaImageSource = "local"
		cfg.Admin.CaptchaImageDirectory = "data/captcha-images"
		if err := cfg.Validate(); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("remote random URL", func(t *testing.T) {
		cfg := Default()
		cfg.Admin.CaptchaMode = "rotate"
		cfg.Admin.CaptchaImageSource = "remote"
		cfg.Admin.CaptchaImageURL = "https://images.example.com/random"
		cfg.Admin.CaptchaImageCacheSize = 12
		if err := cfg.Validate(); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("remote requires URL", func(t *testing.T) {
		cfg := Default()
		cfg.Admin.CaptchaImageSource = "remote"
		cfg.Admin.CaptchaImageURL = ""
		if err := cfg.Validate(); err == nil {
			t.Fatal("remote CAPTCHA image source accepted an empty URL")
		}
	})
	t.Run("local requires directory", func(t *testing.T) {
		cfg := Default()
		cfg.Admin.CaptchaImageSource = "local"
		cfg.Admin.CaptchaImageDirectory = ""
		if err := cfg.Validate(); err == nil {
			t.Fatal("local CAPTCHA image source accepted an empty directory")
		}
	})
}

func TestDefaultCaptchaWorksWithoutLocalImages(t *testing.T) {
	cfg := Default()
	if cfg.Admin.CaptchaMode != "slide" {
		t.Fatalf("default CAPTCHA mode = %q, want slide", cfg.Admin.CaptchaMode)
	}
	if cfg.Admin.CaptchaImageSource != "remote" {
		t.Fatalf(
			"default CAPTCHA image source = %q, want remote",
			cfg.Admin.CaptchaImageSource,
		)
	}
	if cfg.Admin.CaptchaImageURL != "https://t.alcy.cc/moe" {
		t.Fatalf("unexpected default CAPTCHA image URL %q", cfg.Admin.CaptchaImageURL)
	}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestApplyEnvironmentOverridesCaptchaSettings(t *testing.T) {
	t.Setenv("PLAYMESH_CAPTCHA_MODE", "rotate")
	t.Setenv("PLAYMESH_CAPTCHA_IMAGE_SOURCE", "local")
	t.Setenv("PLAYMESH_CAPTCHA_IMAGE_DIRECTORY", "fixtures/captcha")
	t.Setenv("PLAYMESH_CAPTCHA_IMAGE_URL", "https://images.example.com/random")
	t.Setenv("PLAYMESH_CAPTCHA_IMAGE_CACHE_SIZE", "12")
	t.Setenv("PLAYMESH_CAPTCHA_INTERVAL_MILLISECONDS", "1750")

	cfg := Default()
	if err := cfg.applyEnvironment(); err != nil {
		t.Fatal(err)
	}
	if cfg.Admin.CaptchaMode != "rotate" ||
		cfg.Admin.CaptchaImageSource != "local" ||
		cfg.Admin.CaptchaImageDirectory != "fixtures/captcha" ||
		cfg.Admin.CaptchaImageURL != "https://images.example.com/random" ||
		cfg.Admin.CaptchaImageCacheSize != 12 ||
		cfg.Admin.CaptchaIntervalMilliseconds != 1750 {
		t.Fatalf("CAPTCHA environment settings were not applied: %+v", cfg.Admin)
	}
}

func TestSaveOmitsEnvironmentCaptchaSettings(t *testing.T) {
	cfg := Default()
	cfg.ConfigPath = filepath.Join(t.TempDir(), "server.json")
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(cfg.ConfigPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, environmentOnly := range []string{
		"captchaMode",
		"captchaImageSource",
		"captchaImageDirectory",
		"captchaImageUrl",
		"captchaImageCacheSize",
		"captchaIntervalMilliseconds",
	} {
		if strings.Contains(string(content), environmentOnly) {
			t.Fatalf("saved server.json contains environment-only field %q", environmentOnly)
		}
	}
}
