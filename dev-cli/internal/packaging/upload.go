package packaging

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/webpath"
)

// UploadManifest contains only the fields the CLI needs to route an upload.
// The App gateway remains the authoritative parser and validator for the
// package manifest itself.
type UploadManifest struct {
	ID        string
	GameEntry string
}

func LoadUploadManifest(packageRoot string) (UploadManifest, []byte, error) {
	manifestPath := filepath.Join(packageRoot, "main.json")
	info, err := os.Lstat(manifestPath)
	if err != nil {
		return UploadManifest{}, nil, errors.New("当前项目缺少 main.json，无法确定上传项目 ID")
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return UploadManifest{}, nil, errors.New("main.json 必须是可上传的普通文件")
	}
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return UploadManifest{}, nil, err
	}
	var manifest map[string]any
	if err := json.Unmarshal(data, &manifest); err != nil {
		return UploadManifest{}, nil, fmt.Errorf("无法从 main.json 读取上传项目 ID: %w", err)
	}
	id, _ := manifest["id"].(string)
	if strings.TrimSpace(id) == "" {
		return UploadManifest{}, nil, errors.New("main.json.id 不能为空，CLI 需要它确定上传地址")
	}
	gameEntry := ""
	if entries, ok := manifest["entries"].(map[string]any); ok {
		gameEntry, _ = entries["game"].(string)
	}
	return UploadManifest{ID: id, GameEntry: gameEntry}, data, nil
}

// BuildUpload archives the package surface without interpreting or
// normalizing its contents. Package validation and SDK compatibility belong
// to the App gateway so a newer gateway cannot be blocked by an older CLI.
func BuildUpload(packageRoot string) ([]byte, error) {
	files := map[string][]byte{}
	for _, name := range []string{"main.json", "capabilities.json", RootIconName} {
		if err := addOptionalUploadFile(files, packageRoot, name); err != nil {
			return nil, err
		}
	}
	if err := addUploadAppTree(files, packageRoot); err != nil {
		return nil, err
	}
	return zipFileMap(files)
}

// BuildDevelopmentUpload builds the small declaration package required by
// the development resource proxy. It only derives placeholder paths; the App
// gateway validates every manifest and capability rule after upload.
func BuildDevelopmentUpload(
	packageRoot string,
	gameEntryOverride string,
) ([]byte, string, error) {
	uploadManifest, data, err := LoadUploadManifest(packageRoot)
	if err != nil {
		return nil, "", err
	}
	var manifest map[string]any
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, "", err
	}
	if gameEntryOverride != "" {
		entries, _ := manifest["entries"].(map[string]any)
		if entries == nil {
			entries = map[string]any{}
			manifest["entries"] = entries
		}
		entries["game"] = gameEntryOverride
		uploadManifest.GameEntry = gameEntryOverride
		data, err = json.MarshalIndent(manifest, "", "  ")
		if err != nil {
			return nil, "", err
		}
		data = append(data, '\n')
	}
	files := map[string][]byte{"main.json": data}
	for _, entry := range developmentManifestEntries(manifest) {
		if archivePath, ok := developmentPlaceholderPath(entry); ok {
			files[archivePath] = developmentPlaceholder(archivePath)
		}
	}
	for _, name := range []string{"capabilities.json", RootIconName} {
		if err := addOptionalUploadFile(files, packageRoot, name); err != nil {
			return nil, "", err
		}
	}
	packageBytes, err := zipFileMap(files)
	return packageBytes, uploadManifest.ID, err
}

func addOptionalUploadFile(
	files map[string][]byte,
	packageRoot string,
	name string,
) error {
	filePath := filepath.Join(packageRoot, filepath.FromSlash(name))
	info, err := os.Lstat(filePath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("无法安全上传非普通文件: %s", name)
	}
	data, err := os.ReadFile(filePath)
	if err != nil {
		return err
	}
	files[name] = data
	return nil
}

func addUploadAppTree(files map[string][]byte, packageRoot string) error {
	appRoot := filepath.Join(packageRoot, "app")
	info, err := os.Lstat(appRoot)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return errors.New("无法安全上传非目录 app")
	}
	paths := []string{}
	err = filepath.WalkDir(appRoot, func(filePath string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("无法安全上传符号链接: %s", filePath)
		}
		if entry.IsDir() {
			return nil
		}
		if !entry.Type().IsRegular() {
			return fmt.Errorf("无法安全上传非普通文件: %s", filePath)
		}
		relative, err := filepath.Rel(packageRoot, filePath)
		if err != nil {
			return err
		}
		paths = append(paths, filepath.ToSlash(relative))
		return nil
	})
	if err != nil {
		return err
	}
	sort.Strings(paths)
	for _, relative := range paths {
		data, err := os.ReadFile(filepath.Join(packageRoot, filepath.FromSlash(relative)))
		if err != nil {
			return err
		}
		files[relative] = data
	}
	return nil
}

func developmentManifestEntries(manifest map[string]any) []string {
	entries := []string{}
	if values, ok := manifest["entries"].(map[string]any); ok {
		for _, field := range []string{"game", "controller"} {
			if value, ok := values[field].(string); ok {
				entries = append(entries, value)
			}
		}
	}
	if authority, ok := manifest["authority"].(map[string]any); ok {
		if value, ok := authority["entry"].(string); ok {
			entries = append(entries, value)
		}
	}
	return entries
}

func developmentPlaceholderPath(entry string) (string, bool) {
	entry = webpath.WebEntryPath(entry)
	if entry == "" || strings.Contains(entry, "\\") || strings.HasPrefix(entry, "/") {
		return "", false
	}
	cleaned := path.Clean(entry)
	if cleaned != entry || cleaned == "." || strings.HasPrefix(cleaned, "../") {
		return "", false
	}
	return "app/" + cleaned, true
}

func developmentPlaceholder(archivePath string) []byte {
	if strings.HasSuffix(strings.ToLower(archivePath), ".js") {
		return []byte("// Playmesh development placeholder.\n")
	}
	return []byte("<!doctype html><meta charset=\"utf-8\"><title>Playmesh development</title>\n")
}
