package webpath

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
)

var reservedWebRootSegments = map[string]struct{}{
	"bucket":   {},
	"playmesh": {},
}

func ResolveAppOutputDirectory(appRoot, value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", errors.New(
			"playmesh-cli.json.integration.outputDirectory 不能为空",
		)
	}
	if value == "." {
		return filepath.Clean(appRoot), nil
	}
	if strings.Contains(value, "\\") || filepath.IsAbs(value) {
		return "", errors.New(
			"playmesh-cli.json.integration.outputDirectory 必须是 app/ 内使用正斜杠的相对路径",
		)
	}
	segments := strings.Split(value, "/")
	for _, segment := range segments {
		if segment == "" || segment == "." || segment == ".." {
			return "", errors.New(
				"playmesh-cli.json.integration.outputDirectory 包含非法路径段",
			)
		}
	}
	if IsReservedWebRootSegment(segments[0]) {
		return "", fmt.Errorf(
			"playmesh-cli.json.integration.outputDirectory 不能使用平台保留目录 %q",
			segments[0],
		)
	}
	resolved := filepath.Clean(
		filepath.Join(appRoot, filepath.FromSlash(value)),
	)
	relative, err := filepath.Rel(filepath.Clean(appRoot), resolved)
	if err != nil {
		return "", err
	}
	if relative == ".." ||
		strings.HasPrefix(relative, ".."+string(os.PathSeparator)) {
		return "", errors.New(
			"playmesh-cli.json.integration.outputDirectory 不能越出 packageRoot/app",
		)
	}
	return resolved, nil
}

func ValidateWebEntry(value, field string) error {
	return validateWebEntry(value, field, false)
}

func ValidateWebEntryURL(value, field string) error {
	return validateWebEntry(value, field, true)
}

func validateWebEntry(
	value string,
	field string,
	allowHTMLQuery bool,
) error {
	value = strings.TrimSpace(value)
	if value == "" {
		return fmt.Errorf("%s 不能为空", field)
	}
	entryPath := WebEntryPath(value)
	if strings.Contains(entryPath, "\\") ||
		strings.HasPrefix(value, "/") {
		return fmt.Errorf(
			"%s 必须是使用正斜杠的 Web 根相对路径",
			field,
		)
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.IsAbs() || parsed.Host != "" {
		return fmt.Errorf("%s 不能是外部 URL", field)
	}
	if parsed.Fragment != "" || strings.Contains(value, "#") {
		return fmt.Errorf("%s 不能包含 URL fragment", field)
	}
	if strings.Contains(entryPath, "%") {
		return fmt.Errorf(
			"%s 的路径部分必须是未编码的 Web 根相对路径",
			field,
		)
	}
	if parsed.RawQuery != "" || parsed.ForceQuery {
		if !allowHTMLQuery {
			return fmt.Errorf("%s 不能包含查询参数", field)
		}
		if parsed.RawQuery == "" {
			return fmt.Errorf("%s 不能包含空查询参数", field)
		}
		if !strings.HasSuffix(strings.ToLower(entryPath), ".html") {
			return fmt.Errorf(
				"%s 只有 HTML 入口可以包含查询参数",
				field,
			)
		}
	}
	segments := strings.Split(entryPath, "/")
	for _, segment := range segments {
		if segment == "" || segment == "." || segment == ".." {
			return fmt.Errorf(
				"%s 包含非法路径段",
				field,
			)
		}
	}
	if IsReservedWebRootSegment(segments[0]) {
		return fmt.Errorf(
			"%s 不能使用平台保留目录 %q",
			field,
			segments[0],
		)
	}
	return nil
}

func WebEntryPath(value string) string {
	value = strings.TrimSpace(value)
	if query := strings.IndexByte(value, '?'); query >= 0 {
		return value[:query]
	}
	return value
}

func IsReservedWebRootSegment(segment string) bool {
	normalized := strings.TrimSpace(segment)
	for range 4 {
		canonical := strings.ReplaceAll(normalized, "\\", "/")
		cleaned := strings.TrimPrefix(path.Clean("/"+canonical), "/")
		first := cleaned
		if slash := strings.IndexByte(first, '/'); slash >= 0 {
			first = first[:slash]
		}
		if _, exists := reservedWebRootSegments[strings.ToLower(first)]; exists {
			return true
		}
		decoded, err := url.PathUnescape(normalized)
		if err != nil || decoded == normalized {
			break
		}
		normalized = decoded
	}
	return false
}

func RejectSymlinkPath(root, target string) error {
	root = filepath.Clean(root)
	target = filepath.Clean(target)
	relative, err := filepath.Rel(root, target)
	if err != nil {
		return err
	}
	if relative == ".." ||
		strings.HasPrefix(relative, ".."+string(os.PathSeparator)) {
		return errors.New("路径不能越出项目目录")
	}
	current := root
	if info, err := os.Lstat(current); err == nil &&
		info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("项目路径不允许符号链接: %s", current)
	}
	for _, segment := range strings.Split(relative, string(os.PathSeparator)) {
		if segment == "" || segment == "." {
			continue
		}
		current = filepath.Join(current, segment)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("项目路径不允许符号链接: %s", current)
		}
	}
	return nil
}
