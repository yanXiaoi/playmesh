package main

// projectManifest keeps only the fields that belong to the current manifest
// contract. Unknown JSON members are intentionally treated like ordinary
// redundant input: readers do not report them and writers do not reproduce
// them.
func projectManifest(source map[string]any) map[string]any {
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
		// Keep malformed known fields intact so the normal validator reports the
		// actual type error instead of turning it into a missing-field error.
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
