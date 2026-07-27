package gameid

import (
	"strings"
	"testing"
)

func TestValidUsesUnifiedOneToSixtyFourCharacterContract(t *testing.T) {
	for _, value := range []string{
		"a",
		"A",
		"com.example.game",
		"game_name-1.2",
		strings.Repeat("a", MaxLength),
	} {
		if !Valid(value) {
			t.Fatalf("合法 gameId 被拒绝: %q", value)
		}
	}
	for _, value := range []string{
		"",
		".hidden",
		"-prefixed",
		"_prefixed",
		"../escape",
		"a/b",
		"a\\b",
		"a b",
		" a ",
		strings.Repeat("a", MaxLength+1),
	} {
		if Valid(value) {
			t.Fatalf("非法 gameId 被接受: %q", value)
		}
	}
}
