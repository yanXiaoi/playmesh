package sdk

import "testing"

func TestRequireCurrentVersionsAcceptsCompatibleAppSDK(t *testing.T) {
	for _, appVersion := range []string{MinimumSupportedAppVersion, RequiredAppVersion} {
		if err := RequireCurrentVersions(Versions{
			Game: RequiredGameVersion,
			App:  appVersion,
		}); err != nil {
			t.Fatalf("App SDK %s should be supported: %v", appVersion, err)
		}
	}
}

func TestRequireCurrentVersionsRejectsUnsupportedAppSDK(t *testing.T) {
	if err := RequireCurrentVersions(Versions{
		Game: RequiredGameVersion,
		App:  "3.1.0",
	}); err == nil {
		t.Fatal("App SDK 3.1.0 should not be supported")
	}
}
