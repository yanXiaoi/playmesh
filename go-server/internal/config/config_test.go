package config

import "testing"

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
		cfg.Admin.CaptchaImageDirectory = ""
		if err := cfg.Validate(); err == nil {
			t.Fatal("local CAPTCHA image source accepted an empty directory")
		}
	})
}
