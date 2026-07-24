package main

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
)

type createProjectRequest struct {
	ID                             string   `json:"id"`
	Name                           string   `json:"name"`
	Description                    string   `json:"description"`
	Tags                           []string `json:"tags"`
	RequiredCapabilities           []string `json:"requiredCapabilities"`
	ControllerRequiredCapabilities []string `json:"controllerRequiredCapabilities,omitempty"`
	Mode                           string   `json:"mode"`
	Orientation                    string   `json:"orientation"`
	ControllerOrientation          string   `json:"controllerOrientation,omitempty"`
	DisplayMode                    string   `json:"displayMode"`
	MinPlayers                     int      `json:"minPlayers"`
	MaxPlayers                     int      `json:"maxPlayers"`
	ClientID                       string   `json:"clientId"`
}

type capabilityOption struct {
	Code          string `json:"code"`
	Name          string `json:"name"`
	Description   string `json:"description"`
	AppSupported  bool   `json:"appSupported"`
	HTMLSupported bool   `json:"htmlSupported"`
}

var projectIDPattern = regexp.MustCompile(`^[a-z0-9]+(?:[.-][a-z0-9]+)+$`)

func commandCreate(ctx context.Context) error {
	return commandCreateFrom(ctx, os.Stdin)
}

func commandCreateFrom(ctx context.Context, input io.Reader) error {
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	if err := ensureCreateDestination(root); err != nil {
		return err
	}
	target, err := loadTarget()
	if err != nil {
		return err
	}
	client := newAPIClient(target)

	var registry struct {
		Capabilities []capabilityOption `json:"capabilities"`
	}
	if err := client.json(ctx, "GET", "/dev/api/capabilities", nil, &registry); err != nil {
		return err
	}

	reader := bufio.NewReader(input)
	fmt.Println("创建 Playmesh 项目（选项与开发者工作区一致）")
	request, err := promptCreateProject(reader, registry.Capabilities)
	if err != nil {
		return err
	}
	var created struct {
		Project struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"project"`
	}
	if err := client.json(ctx, "POST", "/dev/api/projects", request, &created); err != nil {
		return err
	}
	if created.Project.ID == "" {
		return errors.New("Developer API 创建项目后未返回项目 ID")
	}
	fmt.Printf("已在目标 App 创建 %s（%s），正在下载到当前目录…\n", created.Project.Name, created.Project.ID)
	return downloadProject(ctx, client, created.Project.ID, root)
}

func promptCreateProject(reader *bufio.Reader, capabilities []capabilityOption) (createProjectRequest, error) {
	generatedID, err := randomProjectID()
	if err != nil {
		return createProjectRequest{}, err
	}
	id, err := promptValidated(reader, "项目 ID", generatedID, func(value string) error {
		if !projectIDPattern.MatchString(value) {
			return errors.New("必须是小写反向域名格式，例如 com.example.my-game")
		}
		return nil
	})
	if err != nil {
		return createProjectRequest{}, err
	}
	name, err := promptValidated(reader, "名称", "", func(value string) error {
		if len([]rune(value)) < 1 || len([]rune(value)) > 80 {
			return errors.New("长度必须为 1 到 80 个字符")
		}
		return nil
	})
	if err != nil {
		return createProjectRequest{}, err
	}
	description, err := promptValidated(reader, "描述", "", func(value string) error {
		if len([]rune(value)) > 500 {
			return errors.New("不能超过 500 个字符")
		}
		return nil
	})
	if err != nil {
		return createProjectRequest{}, err
	}
	mode, err := promptChoice(reader, "游戏模式", []promptOption{{"multiplayer", "联机游戏"}, {"solo", "单机游戏"}}, 0)
	if err != nil {
		return createProjectRequest{}, err
	}
	orientation, err := promptChoice(reader, "方向", []promptOption{{"landscape", "横屏"}, {"portrait", "竖屏"}}, 0)
	if err != nil {
		return createProjectRequest{}, err
	}

	displayMode, controllerOrientation, minPlayers, maxPlayers := "multi_screen", "", 1, 1
	if mode == "multiplayer" {
		displayMode, err = promptChoice(reader, "显示模式", []promptOption{{"multi_screen", "多人多屏"}, {"single_screen_multiplayer", "单屏多人"}}, 0)
		if err != nil {
			return createProjectRequest{}, err
		}
		minPlayers, err = promptInteger(reader, "最少玩家", 2, 1, 32)
		if err != nil {
			return createProjectRequest{}, err
		}
		maxPlayers, err = promptInteger(reader, "最多玩家", 5, minPlayers, 32)
		if err != nil {
			return createProjectRequest{}, err
		}
	}
	tagText, err := promptLine(reader, "标签（逗号分隔）", "")
	if err != nil {
		return createProjectRequest{}, err
	}
	tags := splitUnique(tagText)
	if displayMode == "single_screen_multiplayer" {
		controllerOrientation, err = promptChoice(
			reader,
			"控制器方向",
			[]promptOption{{"portrait", "竖屏"}, {"landscape", "横屏"}},
			0,
		)
		if err != nil {
			return createProjectRequest{}, err
		}
	}
	if len(tags) > 20 {
		return createProjectRequest{}, errors.New("标签最多 20 个")
	}
	for _, tag := range tags {
		if len([]rune(tag)) > 64 {
			return createProjectRequest{}, fmt.Errorf("标签 %q 超过 64 个字符", tag)
		}
	}
	requiredCapabilities, err := promptCapabilities(reader, capabilities)
	if err != nil {
		return createProjectRequest{}, err
	}
	var controllerRequiredCapabilities []string
	if displayMode == "single_screen_multiplayer" {
		fmt.Println("控制器能力（与主画面独立声明）：")
		controllerRequiredCapabilities, err = promptCapabilities(
			reader,
			capabilities,
		)
		if err != nil {
			return createProjectRequest{}, err
		}
	}
	return createProjectRequest{
		ID: id, Name: name, Description: description, Tags: tags,
		RequiredCapabilities: requiredCapabilities, Mode: mode,
		ControllerRequiredCapabilities: controllerRequiredCapabilities,
		Orientation:                    orientation, ControllerOrientation: controllerOrientation, DisplayMode: displayMode,
		MinPlayers: minPlayers, MaxPlayers: maxPlayers, ClientID: "cli",
	}, nil
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
			if value == strconv.Itoa(index+1) || value == option.value {
				return option.value, nil
			}
		}
		fmt.Println("请输入列表编号或选项值。")
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
	fmt.Println("平台能力（输入编号或 code，多个用逗号分隔，留空表示不声明）：")
	for index, capability := range capabilities {
		fmt.Printf("  %d) %s (%s) [App:%s HTML:%s]\n", index+1, capability.Name, capability.Code, supportLabel(capability.AppSupported), supportLabel(capability.HTMLSupported))
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
		var code string
		if index, parseErr := strconv.Atoi(item); parseErr == nil && index >= 1 && index <= len(capabilities) {
			code = capabilities[index-1].Code
		} else {
			for _, capability := range capabilities {
				if item == capability.Code {
					code = capability.Code
					break
				}
			}
		}
		if code == "" {
			return nil, fmt.Errorf("未知能力选项 %q", item)
		}
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

func supportLabel(supported bool) string {
	if supported {
		return "已适配"
	}
	return "暂未适配"
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
	if err != nil {
		return err
	}
	if len(entries) != 0 {
		return errors.New("当前目录必须为空，避免覆盖现有文件")
	}
	return nil
}
