package localization

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestGeneratedGoServerBundlesMatchSingleSource(t *testing.T) {
	catalog, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	sourceRoot := filepath.Join("..", "..", "..", "assets", "playmesh-localization")
	sourceManifestBytes, err := os.ReadFile(filepath.Join(sourceRoot, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var sourceManifest struct {
		DefaultLocale string `json:"defaultLocale"`
		Locales       []struct {
			ID      string `json:"id"`
			Enabled bool   `json:"enabled"`
			Bundles struct {
				GoServer string `json:"goServer"`
			} `json:"bundles"`
		} `json:"locales"`
	}
	if err := json.Unmarshal(sourceManifestBytes, &sourceManifest); err != nil {
		t.Fatal(err)
	}
	if catalog.Manifest.DefaultLocale != sourceManifest.DefaultLocale {
		t.Fatal("生成清单默认语言已陈旧")
	}
	for _, locale := range sourceManifest.Locales {
		if !locale.Enabled {
			continue
		}
		sourceBytes, err := os.ReadFile(filepath.Join(sourceRoot, locale.Bundles.GoServer))
		if err != nil {
			t.Fatal(err)
		}
		var sourceMessages, generatedMessages map[string]string
		if err := json.Unmarshal(sourceBytes, &sourceMessages); err != nil {
			t.Fatal(err)
		}
		generatedBytes, ok := catalog.Bundle(locale.ID)
		if !ok {
			t.Fatalf("生成资源缺少 %s", locale.ID)
		}
		if err := json.Unmarshal(generatedBytes, &generatedMessages); err != nil {
			t.Fatal(err)
		}
		if len(sourceMessages) != len(generatedMessages) {
			t.Fatalf("%s 生成词典 key 数量不一致", locale.ID)
		}
		for key, value := range sourceMessages {
			if generatedMessages[key] != value {
				t.Fatalf("%s 的 %s 已陈旧", locale.ID, key)
			}
		}
	}
}
