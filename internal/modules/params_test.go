package modules

import "testing"

func TestStringParam(t *testing.T) {
	v, err := stringParam(map[string]any{"path": "/tmp/x"}, "path", true, "")
	if err != nil || v != "/tmp/x" {
		t.Errorf("got (%q, %v), want (/tmp/x, nil)", v, err)
	}
}

func TestStringParam_MissingRequired(t *testing.T) {
	if _, err := stringParam(map[string]any{}, "path", true, ""); err == nil {
		t.Fatal("expected error for missing required string param")
	}
}

func TestStringParam_MissingOptionalUsesDefault(t *testing.T) {
	v, err := stringParam(map[string]any{}, "path", false, "default")
	if err != nil || v != "default" {
		t.Errorf("got (%q, %v), want (default, nil)", v, err)
	}
}

func TestStringParam_WrongType(t *testing.T) {
	if _, err := stringParam(map[string]any{"path": 42}, "path", true, ""); err == nil {
		t.Fatal("expected error for non-string value")
	}
}

func TestBoolParam(t *testing.T) {
	v, err := boolParam(map[string]any{"recurse": true}, "recurse", false)
	if err != nil || v != true {
		t.Errorf("got (%v, %v), want (true, nil)", v, err)
	}
}

func TestBoolParam_DefaultWhenMissing(t *testing.T) {
	v, err := boolParam(map[string]any{}, "recurse", true)
	if err != nil || v != true {
		t.Errorf("got (%v, %v), want (true, nil)", v, err)
	}
}

func TestBoolParam_WrongType(t *testing.T) {
	if _, err := boolParam(map[string]any{"recurse": "yes"}, "recurse", false); err == nil {
		t.Fatal("expected error for non-bool value")
	}
}

func TestStringSliceParam_NativeSlice(t *testing.T) {
	v, err := stringSliceParam(map[string]any{"paths": []string{"/a", "/b"}}, "paths", true)
	if err != nil || len(v) != 2 || v[0] != "/a" || v[1] != "/b" {
		t.Errorf("got (%v, %v)", v, err)
	}
}

func TestStringSliceParam_AnySlice(t *testing.T) {
	// Mirrors what json.Unmarshal into map[string]any produces for a JSON array.
	v, err := stringSliceParam(map[string]any{"paths": []any{"/a", "/b"}}, "paths", true)
	if err != nil || len(v) != 2 || v[0] != "/a" || v[1] != "/b" {
		t.Errorf("got (%v, %v)", v, err)
	}
}

func TestStringSliceParam_MissingRequired(t *testing.T) {
	if _, err := stringSliceParam(map[string]any{}, "paths", true); err == nil {
		t.Fatal("expected error for missing required slice param")
	}
}

func TestStringSliceParam_NonStringElement(t *testing.T) {
	if _, err := stringSliceParam(map[string]any{"paths": []any{"/a", 42}}, "paths", true); err == nil {
		t.Fatal("expected error for non-string element")
	}
}
