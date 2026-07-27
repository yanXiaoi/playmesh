package version

import (
	"errors"
	"strconv"
	"strings"
)

var ErrInvalid = errors.New("版本必须是无前缀的 MAJOR.MINOR.PATCH")

type Value struct {
	Major int64
	Minor int64
	Patch int64
}

func Parse(input string) (Value, error) {
	if input == "" || strings.TrimSpace(input) != input {
		return Value{}, ErrInvalid
	}
	parts := strings.Split(input, ".")
	if len(parts) != 3 {
		return Value{}, ErrInvalid
	}
	values := [3]int64{}
	for index, part := range parts {
		if part == "" || len(part) > 1 && part[0] == '0' {
			return Value{}, ErrInvalid
		}
		for _, character := range part {
			if character < '0' || character > '9' {
				return Value{}, ErrInvalid
			}
		}
		value, err := strconv.ParseInt(part, 10, 64)
		if err != nil {
			return Value{}, ErrInvalid
		}
		values[index] = value
	}
	return Value{Major: values[0], Minor: values[1], Patch: values[2]}, nil
}

func Compare(left Value, right Value) int {
	if left.Major != right.Major {
		if left.Major < right.Major {
			return -1
		}
		return 1
	}
	if left.Minor != right.Minor {
		if left.Minor < right.Minor {
			return -1
		}
		return 1
	}
	if left.Patch < right.Patch {
		return -1
	}
	if left.Patch > right.Patch {
		return 1
	}
	return 0
}
