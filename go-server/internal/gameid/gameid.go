package gameid

import "regexp"

const MaxLength = 64

var pattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func Valid(value string) bool {
	return pattern.MatchString(value)
}
