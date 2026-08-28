package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/project"
)

func TestConfigureJSONUsesAdapterManifestAndFullyReplacesModeFields(
	t *testing.T,
) {
	root := setupConfigureCocosProject(t)
	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(previous) })

	var output bytes.Buffer
	if err := commandConfigureFrom(
		context.Background(),
		[]string{"--out"},
		strings.NewReader(""),
		&output,
	); err != nil {
		t.Fatal(err)
	}
	var current configureRequest
	if err := json.Unmarshal(output.Bytes(), &current); err != nil {
		t.Fatal(err)
	}
	if current.Manifest.ControllerEntry != "controller/index.html" ||
		current.Manifest.DisplayMode != "single_screen_multiplayer" {
		t.Fatalf("configure --out did not collect current settings: %#v", current)
	}
	if current.Manifest.WebRuntimeMultithreading {
		t.Fatalf("configure --out read an unexpected web runtime setting: %#v", current)
	}

	current.Manifest.DisplayMode = "multi_screen"
	current.Manifest.WebRuntimeMultithreading = true
	current.Manifest.ControllerEntry = ""
	current.Manifest.ControllerOrientation = ""
	current.Capabilities.ControllerRequired = nil
	current.Integration.Platform = "web-desktop"
	current.Integration.AutoRunAfterBuild = false
	encoded, err := json.Marshal(current)
	if err != nil {
		t.Fatal(err)
	}
	output.Reset()
	if err := commandConfigureFrom(
		context.Background(),
		[]string{"--json"},
		bytes.NewReader(encoded),
		&output,
	); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), `"saved":true`) {
		t.Fatalf("configure JSON response is invalid: %q", output.String())
	}

	manifest := readTestJSONObject(
		t,
		filepath.Join(root, "playmesh", "package", "main.json"),
	)
	entries := manifest["entries"].(map[string]any)
	if _, exists := entries["controller"]; exists {
		t.Fatalf("multi-screen overwrite retained controller: %#v", entries)
	}
	if _, exists := manifest["controllerOrientation"]; exists {
		t.Fatalf(
			"multi-screen overwrite retained controller orientation: %#v",
			manifest,
		)
	}
	configValue := manifest["config"].(map[string]any)
	webRuntime := configValue["webRuntime"].(map[string]any)
	if webRuntime["multithreading"] != true ||
		webRuntime["future"] != "kept" ||
		configValue["future"].(map[string]any)["kept"] != float64(42) {
		t.Fatalf("configure did not preserve opaque config fields: %#v", configValue)
	}
	capabilities := readTestJSONObject(
		t,
		filepath.Join(root, "playmesh", "package", "capabilities.json"),
	)
	if _, exists := capabilities["controllerRequired"]; exists {
		t.Fatalf(
			"multi-screen overwrite retained controller capabilities: %#v",
			capabilities,
		)
	}
	config := readTestJSONObject(
		t,
		filepath.Join(root, projectConfigName),
	)
	integration := config["integration"].(map[string]any)
	autoRun, autoRunDeclared := integration["autoRunAfterBuild"]
	if integration["platform"] != "web-desktop" ||
		(autoRunDeclared && autoRun != false) {
		t.Fatalf("Cocos integration was not fully overwritten: %#v", integration)
	}
}

func TestConfigureJSONAcceptsCustomSingleScreenControllerPath(
	t *testing.T,
) {
	root := setupConfigureCocosProject(t)
	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(previous) })

	request := configureRequest{
		Manifest: configureManifest{
			Name:                  "Configured",
			Version:               "2.0.0",
			Orientation:           "portrait",
			Mode:                  "multiplayer",
			DisplayMode:           "single_screen_multiplayer",
			ControllerOrientation: "landscape",
			ControllerEntry:       "controls/pad.html",
			AuthorityEntry:        "static/js/service/index.js",
			MinPlayers:            2,
			MaxPlayers:            4,
		},
		Capabilities: configureCapabilities{
			Required:           []string{"sensor.accelerometer"},
			ControllerRequired: []string{"device.vibration"},
		},
		Integration: &configureIntegration{
			Platform:          "web-mobile",
			AutoRunAfterBuild: true,
			PreviewBridgePort: 0,
		},
	}
	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := commandConfigureFrom(
		context.Background(),
		[]string{"--json"},
		bytes.NewReader(encoded),
		&bytes.Buffer{},
	); err != nil {
		t.Fatal(err)
	}
	manifest := readTestJSONObject(
		t,
		filepath.Join(root, "playmesh", "package", "main.json"),
	)
	entries := manifest["entries"].(map[string]any)
	if entries["controller"] != "controls/pad.html" {
		t.Fatalf("custom controller path was not written: %#v", entries)
	}
	if _, err := os.Stat(
		filepath.Join(
			root,
			"playmesh",
			"package",
			"app",
			"controls",
			"pad.html",
		),
	); err != nil {
		t.Fatalf("default controller skeleton was not copied: %v", err)
	}
}

func TestConfigureOutDoesNotAcceptRedundantFormatArgument(t *testing.T) {
	root := setupConfigureCocosProject(t)
	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(previous) })
	err = commandConfigureFrom(
		context.Background(),
		[]string{"--out", "json"},
		strings.NewReader(""),
		&bytes.Buffer{},
	)
	if err == nil || !strings.Contains(err.Error(), "configure --out") {
		t.Fatalf("redundant output format must be rejected, got %v", err)
	}
}

func TestConfigureOutStateUsesStableEmptyArrays(t *testing.T) {
	root := setupConfigureCocosProject(t)
	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(previous) })
	if err := os.Remove(
		filepath.Join(root, "playmesh", "package", "capabilities.json"),
	); err != nil {
		t.Fatal(err)
	}

	value, err := project.Current()
	if err != nil {
		t.Fatal(err)
	}
	current, _, _, err := readConfigureRequest(value)
	if err != nil {
		t.Fatal(err)
	}
	if current.Capabilities.Required == nil ||
		current.CapabilityOptions == nil {
		t.Fatalf("configure arrays must not be nil: %#v", current)
	}
}

func TestConfigureNormalizesOpaqueConfigToCurrentBoolean(t *testing.T) {
	root := setupConfigureCocosProject(t)
	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(previous) })

	value, err := project.Current()
	if err != nil {
		t.Fatal(err)
	}
	current, manifest, manifestPath, err := readConfigureRequest(value)
	if err != nil {
		t.Fatal(err)
	}
	manifest["config"] = "opaque-legacy-value"
	current.Manifest.WebRuntimeMultithreading = false
	if err := applyConfigureRequest(
		value,
		manifestPath,
		manifest,
		current,
	); err != nil {
		t.Fatal(err)
	}

	saved := readTestJSONObject(t, manifestPath)
	config := saved["config"].(map[string]any)
	webRuntime := config["webRuntime"].(map[string]any)
	if webRuntime["multithreading"] != false {
		t.Fatalf("configure did not write the current boolean: %#v", config)
	}
}

func setupConfigureCocosProject(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, projectConfigName), `{
	  "schemaVersion":1,
	  "packageRoot":"playmesh/package",
	  "sdkRoot":"playmesh/sdk",
	  "integration":{
	    "type":"cocos",
	    "projectRoot":".",
	    "platform":"web-mobile",
	    "outputDirectory":".",
	    "entry":"index.html",
	    "autoRunAfterBuild":true
	  }
	}`)
	writeTestFile(
		t,
		filepath.Join(root, "playmesh", "package", "main.json"),
		`{
		  "id":"com.example.configure",
		  "name":"Configure",
		  "version":"1.0.0",
		  "sdkVersion":"4.1.0",
		  "appSdkVersion":"3.3.0",
		  "orientation":"landscape",
		  "controllerOrientation":"portrait",
		  "modes":["multiplayer"],
		  "displayModes":["single_screen_multiplayer"],
		  "players":{"min":2,"max":4},
		  "entries":{
		    "game":"index.html",
		    "controller":"controller/index.html"
		  },
		  "authority":{"entry":"static/js/service/index.js"},
		  "tags":["cocos"],
		  "config":{
		    "future":{"kept":42},
		    "webRuntime":{"future":"kept","multithreading":false}
		  }
		}`,
	)
	writeTestFile(
		t,
		filepath.Join(root, "playmesh", "package", "capabilities.json"),
		`{
		  "required":["sensor.accelerometer"],
		  "controllerRequired":["device.vibration"]
		}`,
	)
	writeTestFile(
		t,
		filepath.Join(
			root,
			"playmesh",
			"package",
			"app",
			"controller",
			"index.html",
		),
		"<!doctype html><title>Controller</title>",
	)
	return root
}

func readTestJSONObject(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(data, &value); err != nil {
		t.Fatal(err)
	}
	return value
}
