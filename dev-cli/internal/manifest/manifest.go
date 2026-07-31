package manifest

// projectManifest 只保留当前清单契约字段。未知 JSON 字段属于普通冗余输入，
// 读取时不单独报错，后续写入时也不再保留。
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
