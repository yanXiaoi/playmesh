package manifest

// ConfigValue 统一读取 main.json.config 中的嵌套字段。config、任一中间对象
// 或目标字段不存在时返回 nil；调用方不得为某个配置项重复实现 Map 取值逻辑。
func ConfigValue(config any, fieldPath ...string) any {
	if len(fieldPath) == 0 {
		return nil
	}
	current := config
	for _, field := range fieldPath {
		if field == "" {
			return nil
		}
		object, ok := current.(map[string]any)
		if !ok {
			return nil
		}
		value, exists := object[field]
		if !exists {
			return nil
		}
		current = value
	}
	return current
}

// Project 只保留当前清单契约字段。config 是不校验内容的可选扩展字段；
// 其他未知 JSON 字段属于普通冗余输入，后续写入时不再保留。
func Project(source map[string]any) map[string]any {
	projected := projectObject(source, []string{
		"id",
		"name",
		"author",
		"lastModifiedAt",
		"remarks",
		"version",
		"sdkVersion",
		"appSdkVersion",
		"orientation",
		"controllerOrientation",
		"modes",
		"displayModes",
		"players",
		"entries",
		"tags",
		"authority",
		"config",
	})
	projectNestedObject(projected, "players", []string{"min", "max"})
	projectNestedObject(projected, "entries", []string{"game", "controller"})
	projectNestedObject(projected, "authority", []string{"entry"})
	return projected
}

func projectNestedObject(parent map[string]any, field string, fields []string) {
	value, exists := parent[field]
	if !exists {
		return
	}
	object, ok := value.(map[string]any)
	if !ok {
		// 保留类型错误的已知字段，让统一校验器报告真实类型问题，而不是误报字段缺失。
		return
	}
	parent[field] = projectObject(object, fields)
}

func projectObject(source map[string]any, fields []string) map[string]any {
	projected := make(map[string]any, len(fields))
	for _, field := range fields {
		if value, exists := source[field]; exists {
			projected[field] = value
		}
	}
	return projected
}
