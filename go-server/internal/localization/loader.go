package localization

import (
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
)

//go:embed assets/*
var generatedAssets embed.FS

type Manifest struct {
	ManifestVersion string   `json:"manifestVersion"`
	DefaultLocale   string   `json:"defaultLocale"`
	UI              UI       `json:"ui"`
	Locales         []Locale `json:"locales"`
}

type UI struct {
	AllowLocaleSwitch bool   `json:"allowLocaleSwitch"`
	DefaultThemeMode  string `json:"defaultThemeMode"`
	AllowThemeSwitch  bool   `json:"allowThemeSwitch"`
}

type Locale struct {
	ID       string  `json:"id"`
	Label    string  `json:"label"`
	Enabled  bool    `json:"enabled"`
	Fallback *string `json:"fallback"`
	Bundles  struct {
		GoServer string `json:"goServer"`
	} `json:"bundles"`
}

type Catalog struct {
	Manifest Manifest
	bundles  map[string][]byte
}

func Load() (Catalog, error) {
	manifestBytes, err := generatedAssets.ReadFile("assets/manifest.json")
	if err != nil {
		return Catalog{}, err
	}
	var manifest Manifest
	if err := json.Unmarshal(manifestBytes, &manifest); err != nil {
		return Catalog{}, fmt.Errorf("解析本地化清单: %w", err)
	}
	if manifest.ManifestVersion != "1.0.0" || manifest.DefaultLocale == "" {
		return Catalog{}, errors.New("本地化清单版本或默认语言无效")
	}
	seen := make(map[string]struct{}, len(manifest.Locales))
	bundles := make(map[string][]byte, len(manifest.Locales))
	var baselineKeys []string
	for _, locale := range manifest.Locales {
		if !locale.Enabled {
			continue
		}
		if locale.ID == "" || locale.Bundles.GoServer == "" {
			return Catalog{}, errors.New("本地化清单包含不完整语言")
		}
		if _, exists := seen[locale.ID]; exists {
			return Catalog{}, fmt.Errorf("本地化清单包含重复语言 %s", locale.ID)
		}
		seen[locale.ID] = struct{}{}
		content, err := generatedAssets.ReadFile("assets/" + locale.Bundles.GoServer)
		if err != nil {
			return Catalog{}, fmt.Errorf("读取 %s 词典: %w", locale.ID, err)
		}
		var messages map[string]string
		if err := json.Unmarshal(content, &messages); err != nil {
			return Catalog{}, fmt.Errorf("解析 %s 词典: %w", locale.ID, err)
		}
		keys := make([]string, 0, len(messages))
		for key := range messages {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		if baselineKeys == nil {
			baselineKeys = keys
		} else if !sameStrings(baselineKeys, keys) {
			return Catalog{}, fmt.Errorf("%s 词典消息 key 与默认集合不一致", locale.ID)
		}
		bundles[locale.ID] = content
	}
	if _, ok := bundles[manifest.DefaultLocale]; !ok {
		return Catalog{}, errors.New("本地化默认语言未启用")
	}
	fallbacks := make(map[string]string)
	for _, locale := range manifest.Locales {
		if !locale.Enabled || locale.Fallback == nil {
			continue
		}
		if _, ok := bundles[*locale.Fallback]; !ok || *locale.Fallback == locale.ID {
			return Catalog{}, fmt.Errorf("%s 的回退语言无效", locale.ID)
		}
		fallbacks[locale.ID] = *locale.Fallback
	}
	for locale := range fallbacks {
		seenFallback := make(map[string]struct{})
		current := locale
		for current != "" {
			if _, exists := seenFallback[current]; exists {
				return Catalog{}, fmt.Errorf("%s 的回退语言形成环", locale)
			}
			seenFallback[current] = struct{}{}
			current = fallbacks[current]
		}
	}
	return Catalog{Manifest: manifest, bundles: bundles}, nil
}

func (c Catalog) Bundle(locale string) ([]byte, bool) {
	content, ok := c.bundles[locale]
	return append([]byte(nil), content...), ok
}

func (c Catalog) EnabledLocaleIDs() []string {
	result := make([]string, 0, len(c.bundles))
	for _, locale := range c.Manifest.Locales {
		if _, ok := c.bundles[locale.ID]; ok {
			result = append(result, locale.ID)
		}
	}
	return result
}

func sameStrings(left []string, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
