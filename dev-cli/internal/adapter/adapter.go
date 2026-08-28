package adapter

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/development"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/project"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/scaffold"
)

type Adapter interface {
	ID() string
	Detect(root string) error
	Defaults(root string) (scaffold.Defaults, error)
	Configuration(root string) (project.Config, error)
	ProjectManifestPath(project.Context) (string, error)
	Finalize(project.Context) error
	Update(project.Context) error
	PrepareDevelopment(
		context.Context,
		project.Context,
		[]string,
	) (development.Source, error)
	PrepareRelease(context.Context, project.Context) error
}

type Registry struct {
	adapters map[string]Adapter
	platform map[string]struct{}
}

func NewRegistry() *Registry {
	return &Registry{
		adapters: make(map[string]Adapter),
		platform: make(map[string]struct{}),
	}
}

func (registry *Registry) Register(value Adapter, platform bool) error {
	if registry == nil {
		return errors.New("项目适配器注册表未初始化")
	}
	if value == nil {
		return errors.New("不能注册空项目适配器")
	}
	id := strings.ToLower(strings.TrimSpace(value.ID()))
	if id == "" {
		return errors.New("项目适配器 ID 不能为空")
	}
	if _, exists := registry.adapters[id]; exists {
		return fmt.Errorf("项目适配器 %q 已注册", id)
	}
	registry.adapters[id] = value
	if platform {
		registry.platform[id] = struct{}{}
	}
	return nil
}

func (registry *Registry) Lookup(id string) (Adapter, bool) {
	if registry == nil {
		return nil, false
	}
	value, exists := registry.adapters[strings.ToLower(strings.TrimSpace(id))]
	return value, exists
}

func (registry *Registry) ForProject(value project.Context) (Adapter, error) {
	if value.Config == nil || value.Config.Integration == nil {
		return nil, errors.New(
			"playmesh-cli.json 缺少 integration，必须重新初始化当前源码工程",
		)
	}
	id := strings.ToLower(strings.TrimSpace(value.Config.Integration.Type))
	result, exists := registry.Lookup(id)
	if !exists {
		return nil, fmt.Errorf("playmesh-cli.json 使用了未知项目适配器 %q", id)
	}
	return result, nil
}

func (registry *Registry) PlatformIDs() []string {
	if registry == nil {
		return nil
	}
	result := make([]string, 0, len(registry.platform))
	for id := range registry.platform {
		result = append(result, id)
	}
	sort.Strings(result)
	return result
}

func (registry *Registry) IsPlatform(id string) bool {
	if registry == nil {
		return false
	}
	_, exists := registry.platform[strings.ToLower(strings.TrimSpace(id))]
	return exists
}
