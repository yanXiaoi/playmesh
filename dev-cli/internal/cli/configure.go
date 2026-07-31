package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/fsutil"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/project"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/webpath"
)

type configureRequest struct {
	Manifest          configureManifest     `json:"manifest"`
	Capabilities      configureCapabilities `json:"capabilities"`
	Integration       *configureIntegration `json:"integration,omitempty"`
	CapabilityOptions []capabilityOption    `json:"capabilityOptions"`
	CapabilityWarning string                `json:"capabilityWarning,omitempty"`
}

type configureManifest struct {
	ID                    string   `json:"id,omitempty"`
	Name                  string   `json:"name"`
	Version               string   `json:"version"`
	SDKVersion            string   `json:"sdkVersion,omitempty"`
	AppSDKVersion         string   `json:"appSdkVersion,omitempty"`
	Remarks               string   `json:"remarks"`
	Tags                  []string `json:"tags"`
	Orientation           string   `json:"orientation"`
	Mode                  string   `json:"mode"`
	DisplayMode           string   `json:"displayMode"`
	ControllerOrientation string   `json:"controllerOrientation,omitempty"`
	ControllerEntry       string   `json:"controllerEntry,omitempty"`
	AuthorityEntry        string   `json:"authorityEntry,omitempty"`
	MinPlayers            int      `json:"minPlayers"`
	MaxPlayers            int      `json:"maxPlayers"`
	HasControllerEntry    bool     `json:"hasControllerEntry,omitempty"`
	HasAuthorityEntry     bool     `json:"hasAuthorityEntry,omitempty"`
}

type configureCapabilities struct {
	Required           []string `json:"required"`
	ControllerRequired []string `json:"controllerRequired,omitempty"`
}

type configureIntegration struct {
	Platform          string `json:"platform"`
	AutoRunAfterBuild bool   `json:"autoRunAfterBuild"`
	PreviewBridgePort int    `json:"previewBridgePort"`
}

var configureCapabilityCodePattern = regexp.MustCompile(
	`^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)+$`,
)

func commandConfigure(
	ctx context.Context,
	args []string,
) error {
	return commandConfigureFrom(ctx, args, os.Stdin, os.Stdout)
}

func commandConfigureFrom(
	ctx context.Context,
	args []string,
	input io.Reader,
	output io.Writer,
) error {
	value, err := project.Current()
	if err != nil {
		return err
	}
	switch {
	case len(args) == 0:
		current, manifest, manifestPath, err := readConfigureRequest(value)
		if err != nil {
			return err
		}
		configured, err := promptConfigureRequest(
			ctx,
			bufio.NewReader(input),
			current,
		)
		if err != nil {
			return err
		}
		if err := applyConfigureRequest(
			value,
			manifestPath,
			manifest,
			configured,
		); err != nil {
			return err
		}
		fmt.Fprintln(output, "当前项目配置已更新。")
		return nil
	case len(args) == 1 && args[0] == "--json":
		decoder := json.NewDecoder(io.LimitReader(input, 1<<20))
		decoder.DisallowUnknownFields()
		var request configureRequest
		if err := decoder.Decode(&request); err != nil {
			return fmt.Errorf("configure JSON 无效: %w", err)
		}
		var extra any
		if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
			if err == nil {
				return errors.New("configure JSON 只能包含一个对象")
			}
			return fmt.Errorf("configure JSON 无效: %w", err)
		}
		_, manifest, manifestPath, err := readConfigureRequest(value)
		if err != nil {
			return err
		}
		if err := applyConfigureRequest(
			value,
			manifestPath,
			manifest,
			request,
		); err != nil {
			return err
		}
		encoder := json.NewEncoder(output)
		encoder.SetEscapeHTML(false)
		return encoder.Encode(map[string]any{"saved": true})
	case len(args) == 1 && args[0] == "--out":
		request, _, _, err := readConfigureRequest(value)
		if err != nil {
			return err
		}
		populateConfigureCapabilityOptions(ctx, &request)
		encoder := json.NewEncoder(output)
		encoder.SetEscapeHTML(false)
		encoder.SetIndent("", "  ")
		return encoder.Encode(request)
	default:
		return errors.New(
			"用法：playmesh-cli configure、playmesh-cli configure --json 或 playmesh-cli configure --out",
		)
	}
}

func populateConfigureCapabilityOptions(
	ctx context.Context,
	request *configureRequest,
) {
	targetConfig, err := targetStore.Load()
	if err != nil {
		request.CapabilityWarning = err.Error()
		return
	}
	registry, err := fetchCapabilityRegistry(
		ctx,
		newTargetClient(targetConfig),
	)
	if err != nil {
		request.CapabilityWarning = err.Error()
		return
	}
	request.CapabilityOptions = append(
		[]capabilityOption(nil),
		registry.Capabilities...,
	)
	known := make(map[string]struct{}, len(request.CapabilityOptions))
	for _, option := range request.CapabilityOptions {
		known[option.Code] = struct{}{}
	}
	for _, code := range append(
		append([]string{}, request.Capabilities.Required...),
		request.Capabilities.ControllerRequired...,
	) {
		if _, exists := known[code]; exists {
			continue
		}
		known[code] = struct{}{}
		request.CapabilityOptions = append(
			request.CapabilityOptions,
			capabilityOption{
				Code:        code,
				Name:        code,
				Description: "当前项目已声明；目标 App 的能力目录中未返回该项。",
			},
		)
	}
}

func readConfigureRequest(
	value project.Context,
) (configureRequest, map[string]any, string, error) {
	manifestPath, err := configurableManifestPath(value)
	if err != nil {
		return configureRequest{}, nil, "", err
	}
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return configureRequest{}, nil, "", err
	}
	var manifest map[string]any
	if err := json.Unmarshal(data, &manifest); err != nil {
		return configureRequest{}, nil, "", fmt.Errorf("main.json 无效: %w", err)
	}
	entries, ok := manifest["entries"].(map[string]any)
	if !ok {
		return configureRequest{}, nil, "", errors.New("main.json.entries 必须是对象")
	}
	players, ok := manifest["players"].(map[string]any)
	if !ok {
		return configureRequest{}, nil, "", errors.New("main.json.players 必须是对象")
	}
	mode := "solo"
	if anyStringListContains(manifest["modes"], "multiplayer") {
		mode = "multiplayer"
	}
	displayMode := "multi_screen"
	if anyStringListContains(
		manifest["displayModes"],
		"single_screen_multiplayer",
	) {
		displayMode = "single_screen_multiplayer"
	}
	request := configureRequest{
		Manifest: configureManifest{
			ID:                    anyString(manifest["id"]),
			Name:                  anyString(manifest["name"]),
			Version:               anyString(manifest["version"]),
			SDKVersion:            anyString(manifest["sdkVersion"]),
			AppSDKVersion:         anyString(manifest["appSdkVersion"]),
			Remarks:               anyString(manifest["remarks"]),
			Tags:                  anyStringList(manifest["tags"]),
			Orientation:           anyString(manifest["orientation"]),
			Mode:                  mode,
			DisplayMode:           displayMode,
			ControllerOrientation: anyString(manifest["controllerOrientation"]),
			ControllerEntry:       anyString(entries["controller"]),
			AuthorityEntry:        nestedString(manifest["authority"], "entry"),
			MinPlayers:            anyInteger(players["min"]),
			MaxPlayers:            anyInteger(players["max"]),
			HasControllerEntry:    anyString(entries["controller"]) != "",
			HasAuthorityEntry:     nestedString(manifest["authority"], "entry") != "",
		},
		Capabilities: configureCapabilities{
			Required: []string{},
		},
		CapabilityOptions: []capabilityOption{},
	}
	if request.Manifest.Tags == nil {
		request.Manifest.Tags = []string{}
	}
	capabilitiesPath := filepath.Join(
		filepath.Dir(manifestPath),
		"capabilities.json",
	)
	if data, err := os.ReadFile(capabilitiesPath); err == nil {
		var capabilities map[string]any
		if json.Unmarshal(data, &capabilities) != nil {
			return configureRequest{}, nil, "", errors.New(
				"capabilities.json 无效",
			)
		}
		request.Capabilities.Required = anyStringList(
			capabilities["required"],
		)
		request.Capabilities.ControllerRequired = anyStringList(
			capabilities["controllerRequired"],
		)
	} else if !errors.Is(err, os.ErrNotExist) {
		return configureRequest{}, nil, "", err
	}
	if value.Config.Integration != nil &&
		value.Config.Integration.Type == "cocos" {
		request.Integration = &configureIntegration{
			Platform:          value.Config.Integration.Platform,
			AutoRunAfterBuild: value.Config.Integration.AutoRunAfterBuild,
			PreviewBridgePort: value.Config.Integration.PreviewBridgePort,
		}
	}
	return request, manifest, manifestPath, nil
}

func promptConfigureRequest(
	ctx context.Context,
	reader *bufio.Reader,
	current configureRequest,
) (configureRequest, error) {
	targetConfig, err := targetStore.Load()
	if err != nil {
		return configureRequest{}, err
	}
	registry, err := fetchCapabilityRegistry(
		ctx,
		newTargetClient(targetConfig),
	)
	if err != nil {
		return configureRequest{}, err
	}
	fmt.Println("配置当前 Playmesh 项目；直接按回车保留当前值。")
	return promptConfigureRequestWithCapabilities(
		reader,
		current,
		registry.Capabilities,
	)
}

func promptConfigureRequestWithCapabilities(
	reader *bufio.Reader,
	current configureRequest,
	capabilities []capabilityOption,
) (configureRequest, error) {
	var err error
	current.Manifest.Name, err = promptValidated(
		reader,
		"游戏名称",
		current.Manifest.Name,
		func(value string) error {
			return validateConfigureText(value, "游戏名称", 1, 80)
		},
	)
	if err != nil {
		return configureRequest{}, err
	}
	current.Manifest.Version, err = promptValidated(
		reader,
		"版本",
		current.Manifest.Version,
		func(value string) error {
			return validateConfigureText(value, "版本", 1, 64)
		},
	)
	if err != nil {
		return configureRequest{}, err
	}
	current.Manifest.Remarks, err = promptLine(
		reader,
		"项目备注",
		current.Manifest.Remarks,
	)
	if err != nil {
		return configureRequest{}, err
	}
	current.Manifest.Mode, err = promptChoice(
		reader,
		"游戏模式",
		[]promptOption{
			{"multiplayer", "多人游戏"},
			{"solo", "单机游戏"},
		},
		choiceDefaultIndex(
			[]promptOption{
				{"multiplayer", "多人游戏"},
				{"solo", "单机游戏"},
			},
			current.Manifest.Mode,
			1,
		),
	)
	if err != nil {
		return configureRequest{}, err
	}
	current.Manifest.Orientation, err = promptChoice(
		reader,
		"游戏方向",
		[]promptOption{
			{"landscape", "横屏"},
			{"portrait", "竖屏"},
		},
		choiceDefaultIndex(
			[]promptOption{
				{"landscape", "横屏"},
				{"portrait", "竖屏"},
			},
			current.Manifest.Orientation,
			0,
		),
	)
	if err != nil {
		return configureRequest{}, err
	}
	if current.Manifest.Mode == "solo" {
		current.Manifest.DisplayMode = "multi_screen"
		current.Manifest.MinPlayers = 1
		current.Manifest.MaxPlayers = 1
		current.Manifest.AuthorityEntry = ""
	} else {
		current.Manifest.DisplayMode, err = promptChoice(
			reader,
			"显示模式",
			[]promptOption{
				{"multi_screen", "多人多屏"},
				{"single_screen_multiplayer", "单屏多人"},
			},
			choiceDefaultIndex(
				[]promptOption{
					{"multi_screen", "多人多屏"},
					{"single_screen_multiplayer", "单屏多人"},
				},
				current.Manifest.DisplayMode,
				0,
			),
		)
		if err != nil {
			return configureRequest{}, err
		}
		current.Manifest.MinPlayers, err = promptInteger(
			reader,
			"最少玩家",
			max(current.Manifest.MinPlayers, 1),
			1,
			32,
		)
		if err != nil {
			return configureRequest{}, err
		}
		current.Manifest.MaxPlayers, err = promptInteger(
			reader,
			"最多玩家",
			max(current.Manifest.MaxPlayers, current.Manifest.MinPlayers),
			current.Manifest.MinPlayers,
			32,
		)
		if err != nil {
			return configureRequest{}, err
		}
		current.Manifest.AuthorityEntry, err = promptValidated(
			reader,
			"多人权威服务 JS 地址",
			current.Manifest.AuthorityEntry,
			validateAuthorityEntry,
		)
		if err != nil {
			return configureRequest{}, err
		}
	}
	tags, err := promptLine(
		reader,
		"标签（逗号分隔）",
		strings.Join(current.Manifest.Tags, ", "),
	)
	if err != nil {
		return configureRequest{}, err
	}
	current.Manifest.Tags = splitUnique(tags)
	if current.Manifest.DisplayMode == "single_screen_multiplayer" {
		current.Manifest.ControllerOrientation, err = promptChoice(
			reader,
			"控制器方向",
			[]promptOption{
				{"portrait", "竖屏"},
				{"landscape", "横屏"},
			},
			choiceDefaultIndex(
				[]promptOption{
					{"portrait", "竖屏"},
					{"landscape", "横屏"},
				},
				current.Manifest.ControllerOrientation,
				0,
			),
		)
		if err != nil {
			return configureRequest{}, err
		}
		if current.Manifest.ControllerEntry == "" {
			current.Manifest.ControllerEntry = "controller/index.html"
		}
		current.Manifest.ControllerEntry, err = promptValidated(
			reader,
			"控制器 HTML 地址",
			current.Manifest.ControllerEntry,
			validateControllerEntry,
		)
		if err != nil {
			return configureRequest{}, err
		}
	} else {
		current.Manifest.ControllerOrientation = ""
		current.Manifest.ControllerEntry = ""
		current.Capabilities.ControllerRequired = nil
	}
	current.Capabilities.Required, err = promptCapabilitiesWithDefaults(
		reader,
		capabilities,
		current.Capabilities.Required,
	)
	if err != nil {
		return configureRequest{}, err
	}
	if current.Manifest.DisplayMode == "single_screen_multiplayer" {
		fmt.Println("控制器能力（与主画面独立声明）：")
		current.Capabilities.ControllerRequired, err =
			promptCapabilitiesWithDefaults(
				reader,
				capabilities,
				current.Capabilities.ControllerRequired,
			)
		if err != nil {
			return configureRequest{}, err
		}
	}
	if current.Integration != nil {
		current.Integration.Platform, err = promptChoice(
			reader,
			"Cocos Web 构建平台",
			[]promptOption{
				{"web-mobile", "Web Mobile"},
				{"web-desktop", "Web Desktop"},
			},
			choiceDefaultIndex(
				[]promptOption{
					{"web-mobile", "Web Mobile"},
					{"web-desktop", "Web Desktop"},
				},
				current.Integration.Platform,
				0,
			),
		)
		if err != nil {
			return configureRequest{}, err
		}
		autoRun, err := promptChoice(
			reader,
			"构建后自动运行",
			[]promptOption{{"true", "是"}, {"false", "否"}},
			map[bool]int{true: 0, false: 1}[current.Integration.AutoRunAfterBuild],
		)
		if err != nil {
			return configureRequest{}, err
		}
		current.Integration.AutoRunAfterBuild = autoRun == "true"
		current.Integration.PreviewBridgePort, err = promptInteger(
			reader,
			"预览桥端口（0 为自动）",
			current.Integration.PreviewBridgePort,
			0,
			65535,
		)
		if err != nil {
			return configureRequest{}, err
		}
	}
	return current, nil
}

func applyConfigureRequest(
	value project.Context,
	manifestPath string,
	manifest map[string]any,
	request configureRequest,
) error {
	if err := validateConfigureRequest(value, request); err != nil {
		return err
	}
	entries := manifest["entries"].(map[string]any)
	manifest["name"] = strings.TrimSpace(request.Manifest.Name)
	manifest["version"] = strings.TrimSpace(request.Manifest.Version)
	if remarks := strings.TrimSpace(request.Manifest.Remarks); remarks == "" {
		delete(manifest, "remarks")
	} else {
		manifest["remarks"] = remarks
	}
	manifest["tags"] = uniqueTrimmed(request.Manifest.Tags)
	manifest["orientation"] = request.Manifest.Orientation
	manifest["modes"] = []string{request.Manifest.Mode}
	manifest["displayModes"] = []string{request.Manifest.DisplayMode}
	manifest["players"] = map[string]int{
		"min": request.Manifest.MinPlayers,
		"max": request.Manifest.MaxPlayers,
	}
	if request.Manifest.Mode == "multiplayer" {
		manifest["authority"] = map[string]string{
			"entry": request.Manifest.AuthorityEntry,
		}
	} else {
		delete(manifest, "authority")
	}
	if request.Manifest.DisplayMode == "single_screen_multiplayer" {
		previousController, _ := entries["controller"].(string)
		if err := copyCreatedControllerEntry(
			filepath.Dir(manifestPath),
			previousController,
			request.Manifest.ControllerEntry,
		); err != nil {
			return err
		}
		entries["controller"] = request.Manifest.ControllerEntry
		manifest["controllerOrientation"] =
			request.Manifest.ControllerOrientation
	} else {
		delete(entries, "controller")
		delete(manifest, "controllerOrientation")
	}
	manifest["entries"] = entries

	capabilities := map[string]any{
		"required": uniqueTrimmed(request.Capabilities.Required),
	}
	if request.Manifest.DisplayMode == "single_screen_multiplayer" {
		capabilities["controllerRequired"] = uniqueTrimmed(
			request.Capabilities.ControllerRequired,
		)
	}
	manifestData, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	capabilitiesData, err := json.MarshalIndent(capabilities, "", "  ")
	if err != nil {
		return err
	}
	if err := fsutil.WriteAtomicFile(
		manifestPath,
		append(manifestData, '\n'),
		0o644,
	); err != nil {
		return err
	}
	if err := fsutil.WriteAtomicFile(
		filepath.Join(filepath.Dir(manifestPath), "capabilities.json"),
		append(capabilitiesData, '\n'),
		0o644,
	); err != nil {
		return err
	}
	if request.Integration != nil {
		value.Config.Integration.Platform = request.Integration.Platform
		value.Config.Integration.AutoRunAfterBuild =
			request.Integration.AutoRunAfterBuild
		value.Config.Integration.PreviewBridgePort =
			request.Integration.PreviewBridgePort
		if err := project.WriteConfig(value.WorkspaceRoot, *value.Config); err != nil {
			return err
		}
	}
	return nil
}

func configurableManifestPath(
	value project.Context,
) (string, error) {
	projectAdapter, err := adapterForProject(value)
	if err != nil {
		return "", err
	}
	candidate, err := projectAdapter.ProjectManifestPath(value)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(candidate) == "" {
		return "", errors.New("项目适配器未返回 main.json 路径")
	}
	if !filepath.IsAbs(candidate) {
		return "", errors.New(
			"项目适配器返回的 main.json 路径必须是绝对路径",
		)
	}
	candidate = filepath.Clean(candidate)
	relative, err := filepath.Rel(value.WorkspaceRoot, candidate)
	if err != nil ||
		relative == ".." ||
		strings.HasPrefix(
			relative,
			".."+string(os.PathSeparator),
		) {
		return "", errors.New("项目适配器返回的 main.json 路径越出项目")
	}
	if filepath.Base(candidate) != "main.json" {
		return "", errors.New(
			"项目适配器返回的清单文件必须命名为 main.json",
		)
	}
	if err := webpath.RejectSymlinkPath(
		value.WorkspaceRoot,
		candidate,
	); err != nil {
		return "", err
	}
	info, err := os.Stat(candidate)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", errors.New("项目 main.json 必须是普通文件")
	}
	return candidate, nil
}

func validateConfigureRequest(
	value project.Context,
	request configureRequest,
) error {
	if err := validateConfigureText(
		request.Manifest.Name,
		"游戏名称",
		1,
		80,
	); err != nil {
		return err
	}
	if err := validateConfigureText(
		request.Manifest.Version,
		"版本",
		1,
		64,
	); err != nil {
		return err
	}
	if len([]rune(strings.TrimSpace(request.Manifest.Remarks))) > 500 {
		return errors.New("项目备注不能超过 500 个字符")
	}
	if request.Manifest.Orientation != "landscape" &&
		request.Manifest.Orientation != "portrait" {
		return errors.New("游戏方向无效")
	}
	if request.Manifest.Mode != "solo" &&
		request.Manifest.Mode != "multiplayer" {
		return errors.New("游戏模式无效")
	}
	if request.Manifest.Mode == "solo" {
		if request.Manifest.DisplayMode != "multi_screen" ||
			request.Manifest.MinPlayers != 1 ||
			request.Manifest.MaxPlayers != 1 {
			return errors.New(
				"单机游戏必须使用 multi_screen 且玩家人数为 1",
			)
		}
	} else {
		if request.Manifest.DisplayMode != "multi_screen" &&
			request.Manifest.DisplayMode != "single_screen_multiplayer" {
			return errors.New("多人游戏显示模式无效")
		}
		if request.Manifest.MinPlayers < 1 ||
			request.Manifest.MaxPlayers < request.Manifest.MinPlayers ||
			request.Manifest.MaxPlayers > 32 {
			return errors.New("玩家人数必须满足 1 <= min <= max <= 32")
		}
		if err := validateAuthorityEntry(
			request.Manifest.AuthorityEntry,
		); err != nil {
			return err
		}
	}
	tags := uniqueTrimmed(request.Manifest.Tags)
	if len(tags) > 5 {
		return errors.New("标签最多 5 项")
	}
	for _, tag := range tags {
		if len([]rune(tag)) > 64 {
			return fmt.Errorf("标签 %q 超过 64 个字符", tag)
		}
	}
	if request.Manifest.DisplayMode == "single_screen_multiplayer" {
		if request.Manifest.ControllerOrientation != "portrait" &&
			request.Manifest.ControllerOrientation != "landscape" {
			return errors.New("控制器方向无效")
		}
		if err := validateControllerEntry(
			request.Manifest.ControllerEntry,
		); err != nil {
			return err
		}
	}
	for _, code := range append(
		append([]string{}, request.Capabilities.Required...),
		request.Capabilities.ControllerRequired...,
	) {
		if !configureCapabilityCodePattern.MatchString(code) {
			return fmt.Errorf("能力 code 无效: %q", code)
		}
	}
	if request.Integration != nil {
		if value.Config.Integration == nil ||
			value.Config.Integration.Type != "cocos" {
			return errors.New("只有 Cocos 项目可以设置 Cocos integration")
		}
		if request.Integration.Platform != "web-mobile" &&
			request.Integration.Platform != "web-desktop" {
			return errors.New("Cocos Web 构建平台无效")
		}
		if request.Integration.PreviewBridgePort < 0 ||
			request.Integration.PreviewBridgePort > 65535 {
			return errors.New("预览桥端口必须是 0-65535")
		}
	}
	return nil
}

func validateConfigureText(
	value string,
	field string,
	minimum int,
	maximum int,
) error {
	length := len([]rune(strings.TrimSpace(value)))
	if length < minimum || length > maximum {
		return fmt.Errorf(
			"%s长度必须为 %d-%d 个字符",
			field,
			minimum,
			maximum,
		)
	}
	return nil
}

func validateAuthorityEntry(value string) error {
	if err := webpath.ValidateWebEntry(
		value,
		"authority.entry",
	); err != nil {
		return err
	}
	if !strings.HasSuffix(
		strings.ToLower(webpath.WebEntryPath(value)),
		".js",
	) {
		return errors.New("authority.entry 必须是 JavaScript 文件")
	}
	return nil
}

func validateControllerEntry(value string) error {
	if err := webpath.ValidateWebEntry(
		value,
		"entries.controller",
	); err != nil {
		return err
	}
	if !strings.HasSuffix(
		strings.ToLower(webpath.WebEntryPath(value)),
		".html",
	) {
		return errors.New("entries.controller 必须是 HTML 文件")
	}
	return nil
}

func copyCreatedControllerEntry(
	packageRoot string,
	previous string,
	next string,
) error {
	if previous == "" || previous == next {
		return nil
	}
	appRoot := filepath.Join(packageRoot, "app")
	source := filepath.Join(
		appRoot,
		filepath.FromSlash(webpath.WebEntryPath(previous)),
	)
	target := filepath.Join(
		appRoot,
		filepath.FromSlash(webpath.WebEntryPath(next)),
	)
	if err := webpath.RejectSymlinkPath(appRoot, source); err != nil {
		return err
	}
	if err := webpath.RejectSymlinkPath(appRoot, target); err != nil {
		return err
	}
	if info, err := os.Stat(target); err == nil {
		if !info.Mode().IsRegular() {
			return errors.New(
				"entries.controller 目标必须是普通文件",
			)
		}
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	content, err := os.ReadFile(source)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	return fsutil.WriteAtomicFile(target, content, 0o644)
}

func promptCapabilitiesWithDefaults(
	reader *bufio.Reader,
	capabilities []capabilityOption,
	defaults []string,
) ([]string, error) {
	if len(capabilities) == 0 {
		return append([]string(nil), defaults...), nil
	}
	fmt.Println("平台能力（输入编号，多个用逗号分隔，留空保留当前值）：")
	indices := make([]string, 0)
	selected := make(map[string]struct{}, len(defaults))
	for _, code := range defaults {
		selected[code] = struct{}{}
	}
	for index, capability := range capabilities {
		fmt.Printf("  %d) %s (%s)\n", index+1, capability.Name, capability.Code)
		if _, exists := selected[capability.Code]; exists {
			indices = append(indices, fmt.Sprint(index+1))
		}
	}
	value, err := promptLine(
		reader,
		"选择能力",
		strings.Join(indices, ","),
	)
	if err != nil || value == "" {
		return nil, err
	}
	result := make([]string, 0)
	seen := make(map[string]bool)
	for _, item := range splitUnique(value) {
		index := 0
		if _, err := fmt.Sscan(item, &index); err != nil ||
			index < 1 ||
			index > len(capabilities) {
			return nil, fmt.Errorf("未知能力选项 %q", item)
		}
		code := capabilities[index-1].Code
		if !seen[code] {
			seen[code] = true
			result = append(result, code)
		}
	}
	return result, nil
}

func anyString(value any) string {
	text, _ := value.(string)
	return text
}

func nestedString(value any, key string) string {
	object, _ := value.(map[string]any)
	return anyString(object[key])
}

func anyStringList(value any) []string {
	values, _ := value.([]any)
	result := make([]string, 0, len(values))
	for _, value := range values {
		if text, ok := value.(string); ok {
			result = append(result, text)
		}
	}
	return result
}

func anyStringListContains(value any, expected string) bool {
	for _, value := range anyStringList(value) {
		if value == expected {
			return true
		}
	}
	return false
}

func anyInteger(value any) int {
	number, _ := value.(float64)
	return int(number)
}

func uniqueTrimmed(values []string) []string {
	result := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}
