package cocos

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/development"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/project"
)

func TestCocosPreviewPageMappingKeepsSettingsAtPreviewOrigin(t *testing.T) {
	pageURL, err := url.Parse(
		"http://127.0.0.1:7456/web-mobile/task-42/index.html?scene=main&scene=secondary&encoded=%2Fkeep%2forder#debug",
	)
	if err != nil {
		t.Fatal(err)
	}
	source, err := newPreviewPageSource(pageURL)
	if err != nil {
		t.Fatal(err)
	}
	mapping, err := source.Start(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	entryMapping, ok := mapping.(development.GameEntryMapping)
	if !ok {
		t.Fatal("Cocos mapping did not provide a temporary game entry")
	}
	if entryMapping.DevelopmentGameEntry() !=
		"web-mobile/task-42/index.html?scene=main&scene=secondary&encoded=%2Fkeep%2forder" {
		t.Fatalf(
			"preview query was not retained in the temporary entry: %q",
			entryMapping.DevelopmentGameEntry(),
		)
	}
	t.Cleanup(func() {
		if err := source.Stop(context.Background()); err != nil {
			t.Errorf("stop preview source: %v", err)
		}
	})

	settings, err := mapping.MapRequest(&url.URL{
		Path:     "/settings.js",
		RawQuery: "scene=current_scene",
	})
	if err != nil {
		t.Fatal(err)
	}
	const expected = "http://127.0.0.1:7456/settings.js?scene=current_scene"
	if settings.String() != expected {
		t.Fatalf("Cocos settings.js mapped to %s, want %s", settings, expected)
	}
	responseMapping, ok := mapping.(development.ResponseMapping)
	if !ok {
		t.Fatal("Cocos mapping did not provide response metadata mapping")
	}
	response := &http.Response{
		StatusCode: http.StatusOK,
		Header: http.Header{
			"Content-Type": []string{"text/html; charset=utf-8"},
		},
		Request: &http.Request{URL: settings},
	}
	if err := responseMapping.MapResponse(response); err != nil {
		t.Fatal(err)
	}
	if response.Header.Get("Content-Type") !=
		"application/javascript; charset=utf-8" {
		t.Fatalf(
			"Cocos settings.js MIME was not corrected: %q",
			response.Header.Get("Content-Type"),
		)
	}
	internalBundle, err := mapping.MapRequest(&url.URL{
		Path: "/assets/internal/index.js",
	})
	if err != nil {
		t.Fatal(err)
	}
	internalResponse := &http.Response{
		StatusCode: http.StatusOK,
		Header: http.Header{
			"Content-Type": []string{"text/html; charset=utf-8"},
		},
		Request: &http.Request{URL: internalBundle},
	}
	if err := responseMapping.MapResponse(internalResponse); err != nil {
		t.Fatal(err)
	}
	if internalResponse.Header.Get("Content-Type") !=
		"application/javascript; charset=utf-8" {
		t.Fatalf(
			"Cocos dynamic bundle MIME was not corrected: %q",
			internalResponse.Header.Get("Content-Type"),
		)
	}
}

func TestCocosPreviewRootUsesTemporaryHTMLManifestEntry(t *testing.T) {
	pageURL, err := url.Parse(
		"http://127.0.0.1:7456/?scene=current_scene#debug",
	)
	if err != nil {
		t.Fatal(err)
	}
	source, err := newPreviewPageSource(pageURL)
	if err != nil {
		t.Fatal(err)
	}
	mapping, err := source.Start(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	entryMapping, ok := mapping.(development.GameEntryMapping)
	if !ok {
		t.Fatal("Cocos mapping did not provide a temporary game entry")
	}
	if entryMapping.DevelopmentGameEntry() !=
		"index.html?scene=current_scene" {
		t.Fatalf(
			"unexpected root preview entry %q",
			entryMapping.DevelopmentGameEntry(),
		)
	}
	entry, err := mapping.MapRequest(&url.URL{
		Path:     "/index.html",
		RawQuery: "scene=current_scene",
	})
	if err != nil {
		t.Fatal(err)
	}
	if entry.String() !=
		"http://127.0.0.1:7456/?scene=current_scene" {
		t.Fatalf("root preview entry was not mapped to the clicked URL: %s", entry)
	}
	alternate, err := mapping.MapRequest(&url.URL{
		Path:     "/index.html",
		RawQuery: "scene=alternate",
	})
	if err != nil {
		t.Fatal(err)
	}
	if alternate.String() !=
		"http://127.0.0.1:7456/?scene=alternate" {
		t.Fatalf(
			"root preview query was not forwarded transparently: %s",
			alternate,
		)
	}
}

func TestRewriteCocosPreviewReloadUsesSafeCoordinator(t *testing.T) {
	source := []byte(
		`n.on("browser:reload",function(){window.location.reload()}),` +
			`n.on("browser:disconnect",function(){window.location.reload()})`,
	)
	response := &http.Response{
		StatusCode:    http.StatusOK,
		Header:        make(http.Header),
		Body:          io.NopCloser(bytes.NewReader(source)),
		ContentLength: int64(len(source)),
	}
	response.Header.Set("Content-Length", "123")
	response.Header.Set("ETag", `"cocos-preview"`)
	if err := rewriteCocosPreviewReload(response); err != nil {
		t.Fatal(err)
	}
	content, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(
		string(content),
		"globalThis.__playmeshCocosReload?",
	) != 2 {
		t.Fatalf("Cocos reload calls were not rewritten: %s", content)
	}
	for _, reason := range []string{"reload", "disconnect"} {
		if !strings.Contains(
			string(content),
			`__playmeshCocosReload("`+reason+`")`,
		) {
			t.Fatalf(
				"Cocos %s handler did not retain its reason: %s",
				reason,
				content,
			)
		}
	}
	if response.ContentLength != int64(len(content)) ||
		response.Header.Get("Content-Length") !=
			fmt.Sprintf("%d", len(content)) {
		t.Fatalf(
			"rewritten response length is inconsistent: field=%d header=%s actual=%d",
			response.ContentLength,
			response.Header.Get("Content-Length"),
			len(content),
		)
	}
	if response.Header.Get("ETag") != "" {
		t.Fatal("rewritten Cocos preview client must not retain the source ETag")
	}
}

func TestInstallCocosPreviewTemplateCreatesAppOnlyGate(t *testing.T) {
	root := t.TempDir()
	if err := installCocosPreviewTemplate(root); err != nil {
		t.Fatal(err)
	}

	indexPath := filepath.Join(root, "preview-template", "index.ejs")
	index, err := os.ReadFile(indexPath)
	if err != nil {
		t.Fatal(err)
	}
	content := string(index)
	if !strings.Contains(content, playmeshPreviewGateStart) ||
		!strings.Contains(content, `<script src="/playmesh-preview-gate.js"></script>`) ||
		!strings.Contains(content, "include(cocosTemplate, {})") ||
		!strings.Contains(content, "include(cocosToolBar, {config: config})") ||
		!strings.Contains(content, `id="GameCanvas"`) ||
		!strings.Contains(content, `class="error-main"`) {
		t.Fatalf("generated preview template is incomplete: %s", content)
	}
	if _, err := os.Stat(
		filepath.Join(root, "preview-template", "playmesh-preview-gate.js"),
	); err != nil {
		t.Fatal(err)
	}
	gate, err := os.ReadFile(
		filepath.Join(root, "preview-template", "playmesh-preview-gate.js"),
	)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(
		string(gate),
		`sessionStorage.setItem(`,
	) || !strings.Contains(
		string(gate),
		`location.replace("/playmesh-preview-handoff.html")`,
	) {
		t.Fatalf(
			"preview gate must redirect the ordinary browser to the handoff page: %s",
			gate,
		)
	}
	handoffHTML, err := os.ReadFile(
		filepath.Join(
			root,
			"preview-template",
			"playmesh-preview-handoff.html",
		),
	)
	if err != nil {
		t.Fatal(err)
	}
	handoffScript, err := os.ReadFile(
		filepath.Join(
			root,
			"preview-template",
			"playmesh-preview-handoff.js",
		),
	)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(
		string(handoffHTML),
		`id="playmesh-preview-status"`,
	) || !strings.Contains(
		string(handoffScript),
		`body: JSON.stringify({ previewURL: previewPageURL })`,
	) {
		t.Fatalf(
			"preview handoff page is incomplete: html=%s script=%s",
			handoffHTML,
			handoffScript,
		)
	}
	ignore, err := os.ReadFile(filepath.Join(root, ".gitignore"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(ignore), playmeshPreviewRuntimeIgnore) != 1 {
		t.Fatalf("runtime port file must be ignored exactly once: %s", ignore)
	}

	runtimePath := filepath.Join(
		root,
		"preview-template",
		"playmesh-preview-runtime.json",
	)
	const runtime = `{"port":43123}` + "\n"
	if err := os.WriteFile(runtimePath, []byte(runtime), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := installCocosPreviewTemplate(root); err != nil {
		t.Fatal(err)
	}
	index, err = os.ReadFile(indexPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(index), playmeshPreviewGateStart) != 1 {
		t.Fatalf("preview gate must be installed idempotently: %s", index)
	}
	ignore, err = os.ReadFile(filepath.Join(root, ".gitignore"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(ignore), playmeshPreviewRuntimeIgnore) != 1 {
		t.Fatalf("runtime ignore must be idempotent: %s", ignore)
	}
	preservedRuntime, err := os.ReadFile(runtimePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(preservedRuntime) != runtime {
		t.Fatalf(
			"preview template update changed the active runtime port: %s",
			preservedRuntime,
		)
	}
}

func TestInstallCocosPreviewTemplateMigratesLegacyGeneratedTemplate(
	t *testing.T,
) {
	root := t.TempDir()
	previewRoot := filepath.Join(root, "preview-template")
	if err := os.MkdirAll(previewRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	indexPath := filepath.Join(previewRoot, "index.ejs")
	legacyWindows := strings.ReplaceAll(
		legacyGeneratedPreviewTemplate,
		"\n",
		"\r\n",
	)
	if err := os.WriteFile(
		indexPath,
		[]byte(legacyWindows+"\r\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}

	if err := installCocosPreviewTemplate(root); err != nil {
		t.Fatal(err)
	}
	index, err := os.ReadFile(indexPath)
	if err != nil {
		t.Fatal(err)
	}
	content := string(index)
	if !strings.Contains(content, `id="GameCanvas"`) ||
		!strings.Contains(content, "include(cocosToolBar, {config: config})") {
		t.Fatalf("legacy generated template was not migrated: %s", content)
	}
}

func TestInstallCocosPreviewTemplatePreservesCustomEJS(t *testing.T) {
	root := t.TempDir()
	previewRoot := filepath.Join(root, "preview-template")
	if err := os.MkdirAll(previewRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	indexPath := filepath.Join(previewRoot, "index.ejs")
	custom := `<!doctype html>
<html>
<head><meta name="custom" content="preserved"></head>
<body><%- include(cocosTemplate, {}) %></body>
</html>`
	if err := os.WriteFile(indexPath, []byte(custom), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := installCocosPreviewTemplate(root); err != nil {
		t.Fatal(err)
	}
	index, err := os.ReadFile(indexPath)
	if err != nil {
		t.Fatal(err)
	}
	content := string(index)
	if !strings.Contains(content, `name="custom"`) {
		t.Fatalf("custom preview content was not preserved: %s", content)
	}
	gate := strings.Index(content, playmeshPreviewGateStart)
	include := strings.Index(content, "<%- include(cocosTemplate, {}) %>")
	if gate < 0 || include < 0 || gate > include {
		t.Fatalf("preview gate must precede Cocos startup: %s", content)
	}

	if err := installCocosPreviewTemplate(root); err != nil {
		t.Fatal(err)
	}
	updated, err := os.ReadFile(indexPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(updated) != content {
		t.Fatalf(
			"custom preview template changed on repeated update:\n%s",
			updated,
		)
	}
}

func TestInstallCocosPreviewTemplateRejectsUnknownCustomEJS(t *testing.T) {
	root := t.TempDir()
	previewRoot := filepath.Join(root, "preview-template")
	if err := os.MkdirAll(previewRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(previewRoot, "index.ejs"),
		[]byte("<!doctype html><p>missing Cocos include</p>"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	if err := installCocosPreviewTemplate(root); err == nil ||
		!strings.Contains(err.Error(), "cocosTemplate include") {
		t.Fatalf("unknown custom template must fail safely, got %v", err)
	}
}

func TestValidateCocosIntegrationRejectsInvalidPreviewBridgePort(t *testing.T) {
	for _, port := range []int{-1, 65536} {
		value := project.Context{
			Config: &project.Config{
				Integration: &project.IntegrationConfig{
					Type:              "cocos",
					Platform:          "web-mobile",
					PreviewBridgePort: port,
				},
			},
		}
		err := validateCocosIntegration(value)
		if err == nil || !strings.Contains(err.Error(), "previewBridgePort") {
			t.Fatalf("port %d must be rejected, got %v", port, err)
		}
	}
}

func TestValidateCocosIntegrationAllowsUserAppOutputDirectory(t *testing.T) {
	value := project.Context{
		AppRoot: filepath.Join(t.TempDir(), "playmesh", "package", "app"),
		Config: &project.Config{
			Integration: &project.IntegrationConfig{
				Type:            "cocos",
				Platform:        "web-mobile",
				OutputDirectory: "app",
				Entry:           "app/index.html",
			},
		},
	}
	if err := validateCocosIntegration(value); err != nil {
		t.Fatalf("用户 app/ 输出目录被拒绝: %v", err)
	}
}

func TestCocosProjectOrientationMapsAutoToFollowSystem(
	t *testing.T,
) {
	root := t.TempDir()
	writeCocosTestFile(
		t,
		filepath.Join(root, "settings", "v2", "packages", "project.json"),
		`{"general":{"designResolution":{"width":240,"height":426}}}`,
	)
	writeCocosTestFile(
		t,
		filepath.Join(root, "profiles", "v2", "packages", "web-mobile.json"),
		`{"builder":{"taskOptionsMap":{
		  "100":{"orientation":"landscape"},
		  "200":{"orientation":"auto"}
		}}}`,
	)
	orientation, found, err := cocosProjectOrientation(root, "web-mobile")
	if err != nil {
		t.Fatal(err)
	}
	if !found || orientation != "system" {
		t.Fatalf(
			"auto orientation must follow the system, got %q found=%v",
			orientation,
			found,
		)
	}

	writeCocosTestFile(
		t,
		filepath.Join(root, "profiles", "v2", "packages", "web-mobile.json"),
		`{"builder":{"taskOptionsMap":{
		  "300":{"orientation":"landscape"}
		}}}`,
	)
	orientation, found, err = cocosProjectOrientation(root, "web-mobile")
	if err != nil {
		t.Fatal(err)
	}
	if !found || orientation != "landscape" {
		t.Fatalf(
			"explicit build orientation must win, got %q found=%v",
			orientation,
			found,
		)
	}
}

func writeCocosTestFile(t *testing.T, path string, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}
