package version

import "testing"

func TestParseStrictSemanticVersion(t *testing.T) {
	valid := []string{"0.0.0", "1.2.3", "9223372036854775807.0.1"}
	for _, input := range valid {
		if _, err := Parse(input); err != nil {
			t.Fatalf("Parse(%q) = %v", input, err)
		}
	}
	invalid := []string{
		"", "1", "1.2", "v1.2.3", "1.2.3-beta", "1.2.3+4",
		"01.2.3", "1.02.3", "1.2.03", " 1.2.3", "1.2.3 ",
	}
	for _, input := range invalid {
		if _, err := Parse(input); err == nil {
			t.Fatalf("Parse(%q) 未拒绝非法版本", input)
		}
	}
}

func TestCompareUsesNumericSegments(t *testing.T) {
	left, _ := Parse("1.10.0")
	right, _ := Parse("1.9.99")
	if Compare(left, right) <= 0 {
		t.Fatal("语义版本仍按字符串比较")
	}
}
