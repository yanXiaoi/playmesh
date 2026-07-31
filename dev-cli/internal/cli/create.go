package cli

import (
	"bufio"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strconv"
	"strings"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/project"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/scaffold"
)

type createProjectRequest struct {
	ID                             string   `json:"id"`
	Name                           string   `json:"name"`
	Version                        string   `json:"-"`
	Description                    string   `json:"description"`
	Tags                           []string `json:"tags"`
	RequiredCapabilities           []string `json:"requiredCapabilities"`
	ControllerRequiredCapabilities []string `json:"controllerRequiredCapabilities,omitempty"`
	Mode                           string   `json:"mode"`
	Orientation                    string   `json:"orientation"`
	ControllerOrientation          string   `json:"controllerOrientation,omitempty"`
	ControllerEntry                string   `json:"-"`
	AuthorityEntry                 string   `json:"-"`
	DisplayMode                    string   `json:"displayMode"`
	MinPlayers                     int      `json:"minPlayers"`
	MaxPlayers                     int      `json:"maxPlayers"`
	ClientID                       string   `json:"clientId"`
}

type capabilityOption struct {
	Code               string               `json:"code"`
	Name               string               `json:"name"`
	Description        string               `json:"description"`
	SupportedPlatforms []capabilityPlatform `json:"supportedPlatforms"`
}

type capabilityRegistry struct {
	Capabilities []capabilityOption `json:"capabilities"`
}

type capabilityPlatform string

const (
	capabilityPlatformWindows capabilityPlatform = "WINDOWS"
	capabilityPlatformAndroid capabilityPlatform = "ANDROID"
	capabilityPlatformHTML    capabilityPlatform = "HTML"
)

var projectIDPattern = regexp.MustCompile(`^[a-z0-9]+(?:[.-][a-z0-9]+)+$`)

func createProjectAtWithDefaults(
	ctx context.Context,
	input io.Reader,
	projectContext project.Context,
	defaults scaffold.Defaults,
) error {
	targetConfig, err := targetStore.Load()
	if err != nil {
		return err
	}
	client := newTargetClient(targetConfig)

	registry, err := fetchCapabilityRegistry(ctx, client)
	if err != nil {
		return err
	}

	reader := bufio.NewReader(input)
	fmt.Println("创建 Playmesh 项目（选项与开发者工作区一致）")
	request, err := promptCreateProjectWithDefaults(reader, registry.Capabilities, defaults)
	if err != nil {
		return err
	}
	var created struct {
		Project struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"project"`
	}
	if err := client.JSON(ctx, "POST", "/dev/api/projects", request, &created); err != nil {
		return err
	}
	if created.Project.ID == "" {
		return errors.New("Developer API 创建项目后未返回项目 ID")
	}
	fmt.Printf("已在目标 App 创建 %s（%s），正在下载到当前目录…\n", created.Project.Name, created.Project.ID)
	if err := downloadProjectTo(
		ctx,
		client,
		created.Project.ID,
		projectContext.PackageRoot,
		projectContext.SDKRoot,
	); err != nil {
		return err
	}
	_, manifest, manifestPath, err := readConfigureRequest(projectContext)
	if err != nil {
		return err
	}
	return applyConfigureRequest(
		projectContext,
		manifestPath,
		manifest,
		configureRequestFromCreate(request),
	)
}

func configureRequestFromCreate(
	request createProjectRequest,
) configureRequest {
	return configureRequest{
		Manifest: configureManifest{
			Name:                  request.Name,
			Version:               request.Version,
			Remarks:               request.Description,
			Tags:                  request.Tags,
			Orientation:           request.Orientation,
			Mode:                  request.Mode,
			DisplayMode:           request.DisplayMode,
			ControllerOrientation: request.ControllerOrientation,
			ControllerEntry:       request.ControllerEntry,
			AuthorityEntry:        request.AuthorityEntry,
			MinPlayers:            request.MinPlayers,
			MaxPlayers:            request.MaxPlayers,
		},
		Capabilities: configureCapabilities{
			Required:           request.RequiredCapabilities,
			ControllerRequired: request.ControllerRequiredCapabilities,
		},
	}
}

func fetchCapabilityRegistry(
	ctx context.Context,
	client interface {
		JSON(context.Context, string, string, any, any) error
	},
) (capabilityRegistry, error) {
	var registry capabilityRegistry
	if err := client.JSON(
		ctx,
		"GET",
		"/dev/api/capabilities",
		nil,
		&registry,
	); err != nil {
		return capabilityRegistry{}, err
	}
	return registry, nil
}

func promptCreateProjectWithDefaults(
	reader *bufio.Reader,
	capabilities []capabilityOption,
	defaults scaffold.Defaults,
) (createProjectRequest, error) {
	generatedID, err := randomProjectID()
	if err != nil {
		return createProjectRequest{}, err
	}
	if defaults.ID == "" {
		defaults.ID = generatedID
	}
	id, err := promptValidated(reader, "项目 ID", defaults.ID, func(value string) error {
		if !projectIDPattern.MatchString(value) {
			return errors.New("必须是小写反向域名格式，例如 com.example.my-game")
		}
		return nil
	})
	if err != nil {
		return createProjectRequest{}, err
	}
	configured, err := promptConfigureRequestWithCapabilities(
		reader,
		configureRequest{
			Manifest: configureManifest{
				Name:                  defaults.Name,
				Version:               defaultString(defaults.Version, "0.1.0"),
				Remarks:               defaults.Description,
				Tags:                  splitUnique(defaults.Tags),
				Orientation:           defaultString(defaults.Orientation, "landscape"),
				Mode:                  defaultString(defaults.Mode, "multiplayer"),
				DisplayMode:           defaultString(defaults.DisplayMode, "multi_screen"),
				ControllerOrientation: defaultString(defaults.ControllerOrientation, "portrait"),
				ControllerEntry:       defaultString(defaults.ControllerEntry, "controller/index.html"),
				AuthorityEntry:        defaultString(defaults.AuthorityEntry, "static/js/service/index.js"),
				MinPlayers:            max(defaults.MinPlayers, 2),
				MaxPlayers:            max(defaults.MaxPlayers, 5),
			},
		},
		capabilities,
	)
	if err != nil {
		return createProjectRequest{}, err
	}
	if err := validateConfigureRequest(
		project.Context{},
		configured,
	); err != nil {
		return createProjectRequest{}, err
	}
	return createProjectRequest{
		ID:                             id,
		Name:                           configured.Manifest.Name,
		Version:                        configured.Manifest.Version,
		Description:                    configured.Manifest.Remarks,
		Tags:                           configured.Manifest.Tags,
		RequiredCapabilities:           configured.Capabilities.Required,
		ControllerRequiredCapabilities: configured.Capabilities.ControllerRequired,
		Mode:                           configured.Manifest.Mode,
		Orientation:                    configured.Manifest.Orientation,
		ControllerOrientation:          configured.Manifest.ControllerOrientation,
		ControllerEntry:                configured.Manifest.ControllerEntry,
		AuthorityEntry:                 configured.Manifest.AuthorityEntry,
		DisplayMode:                    configured.Manifest.DisplayMode,
		MinPlayers:                     configured.Manifest.MinPlayers,
		MaxPlayers:                     configured.Manifest.MaxPlayers,
		ClientID:                       "cli",
	}, nil
}

func defaultString(value string, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func choiceDefaultIndex(options []promptOption, value string, fallback int) int {
	for index, option := range options {
		if option.value == value {
			return index
		}
	}
	return fallback
}

type promptOption struct {
	value string
	label string
}

func promptChoice(reader *bufio.Reader, label string, options []promptOption, defaultIndex int) (string, error) {
	for index, option := range options {
		fmt.Printf("  %d) %s (%s)\n", index+1, option.label, option.value)
	}
	for {
		value, err := promptLine(reader, label, strconv.Itoa(defaultIndex+1))
		if err != nil {
			return "", err
		}
		for index, option := range options {
			if value == strconv.Itoa(index+1) {
				return option.value, nil
			}
		}
		fmt.Println("请输入列表编号。")
	}
}

func promptInteger(reader *bufio.Reader, label string, defaultValue, minimum, maximum int) (int, error) {
	for {
		value, err := promptLine(reader, label, strconv.Itoa(defaultValue))
		if err != nil {
			return 0, err
		}
		parsed, parseErr := strconv.Atoi(value)
		if parseErr == nil && parsed >= minimum && parsed <= maximum {
			return parsed, nil
		}
		fmt.Printf("请输入 %d 到 %d 的整数。\n", minimum, maximum)
	}
}

func promptValidated(reader *bufio.Reader, label, defaultValue string, validate func(string) error) (string, error) {
	for {
		value, err := promptLine(reader, label, defaultValue)
		if err != nil {
			return "", err
		}
		if validationErr := validate(value); validationErr != nil {
			fmt.Printf("%s：%v。\n", label, validationErr)
			continue
		}
		return value, nil
	}
}

func promptLine(reader *bufio.Reader, label, defaultValue string) (string, error) {
	if defaultValue == "" {
		fmt.Printf("%s: ", label)
	} else {
		fmt.Printf("%s [%s]: ", label, defaultValue)
	}
	line, err := reader.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	if errors.Is(err, io.EOF) && strings.TrimSpace(line) == "" {
		return "", io.EOF
	}
	value := strings.TrimSpace(line)
	if value == "" {
		value = defaultValue
	}
	return value, nil
}

func promptCapabilities(reader *bufio.Reader, capabilities []capabilityOption) ([]string, error) {
	if len(capabilities) == 0 {
		return nil, nil
	}
	fmt.Println("平台能力（输入编号，多个用逗号分隔，留空表示不声明）：")
	for index, capability := range capabilities {
		fmt.Printf("  %d) %s (%s)", index+1, capability.Name, capability.Code)
		if platforms := capabilityPlatformNames(capability.SupportedPlatforms); len(platforms) != 0 {
			fmt.Printf(" [支持平台:%s]", strings.Join(platforms, "/"))
		}
		fmt.Println()
		if capability.Description != "" {
			fmt.Printf("     %s\n", capability.Description)
		}
	}
	value, err := promptLine(reader, "选择能力", "")
	if err != nil || value == "" {
		return nil, err
	}
	selected := make([]string, 0)
	seen := make(map[string]bool)
	for _, item := range splitUnique(value) {
		index, parseErr := strconv.Atoi(item)
		if parseErr != nil || index < 1 || index > len(capabilities) {
			return nil, fmt.Errorf("未知能力选项 %q", item)
		}
		code := capabilities[index-1].Code
		if !seen[code] {
			seen[code] = true
			selected = append(selected, code)
		}
	}
	return selected, nil
}

func splitUnique(value string) []string {
	seen := make(map[string]bool)
	result := make([]string, 0)
	for _, item := range strings.FieldsFunc(value, func(r rune) bool { return r == ',' || r == '，' || r == '\n' }) {
		item = strings.TrimSpace(item)
		if item != "" && !seen[item] {
			seen[item] = true
			result = append(result, item)
		}
	}
	return result
}

func capabilityPlatformNames(platforms []capabilityPlatform) []string {
	names := make([]string, 0, len(platforms))
	for _, platform := range platforms {
		switch platform {
		case capabilityPlatformWindows, capabilityPlatformAndroid, capabilityPlatformHTML:
			names = append(names, string(platform))
		}
	}
	return names
}

func randomProjectID() (string, error) {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	bytes := make([]byte, 10)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	for index := range bytes {
		bytes[index] = alphabet[int(bytes[index])%len(alphabet)]
	}
	return "com.playmesh.game-" + string(bytes), nil
}

func ensureCreateDestination(root string) error {
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if len(entries) != 0 {
		return errors.New("当前目录必须为空，避免覆盖现有文件")
	}
	return nil
}
