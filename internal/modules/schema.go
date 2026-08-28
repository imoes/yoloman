package modules

// objectSchema builds a JSON Schema object with the given properties and
// required field names.
func objectSchema(properties map[string]any, required ...string) map[string]any {
	s := map[string]any{
		"type":       "object",
		"properties": properties,
	}
	if len(required) > 0 {
		s["required"] = required
	}
	return s
}

// stringProp builds a JSON Schema "string" property with a description.
func stringProp(description string) map[string]any {
	return map[string]any{"type": "string", "description": description}
}

// stringEnumProp builds a JSON Schema "string" property restricted to one of
// values, with a description.
func stringEnumProp(description string, values ...string) map[string]any {
	return map[string]any{"type": "string", "description": description, "enum": values}
}

// boolProp builds a JSON Schema "boolean" property with a description and
// default value.
func boolProp(description string, def bool) map[string]any {
	return map[string]any{"type": "boolean", "description": description, "default": def}
}

// stringArrayProp builds a JSON Schema array-of-strings property with a
// description.
func stringArrayProp(description string) map[string]any {
	return map[string]any{
		"type":        "array",
		"items":       map[string]any{"type": "string"},
		"description": description,
	}
}

// objectMapProp describes a free-form object whose values are all strings — e.g. a set of
// environment variables. Kept next to the other prop helpers so every module describes such a
// parameter the same way.
func objectMapProp(description string) map[string]any {
	return map[string]any{
		"type":                 "object",
		"description":          description,
		"additionalProperties": map[string]any{"type": "string"},
	}
}
