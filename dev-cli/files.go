package main

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	rootIconName      = "icon.png"
	maxRootIconBytes  = 2 << 20
	maxRootIconEdge   = 8192
	maxRootIconPixels = 4 * 1024 * 1024
)

func replaceFile(source, target string) error {
	backup := target + ".playmesh-backup"
	_ = os.Remove(backup)
	if _, err := os.Stat(target); err == nil {
		if err := os.Rename(target, backup); err != nil {
			return err
		}
	}
	if err := os.Rename(source, target); err != nil {
		_ = os.Rename(backup, target)
		return err
	}
	_ = os.Remove(backup)
	return nil
}

func replaceDirectory(source, target string) error {
	backup := target + ".playmesh-backup"
	_ = os.RemoveAll(backup)
	if _, err := os.Stat(target); err == nil {
		if err := os.Rename(target, backup); err != nil {
			return err
		}
	}
	if err := os.Rename(source, target); err != nil {
		_ = os.Rename(backup, target)
		return err
	}
	_ = os.RemoveAll(backup)
	return nil
}

func buildPackage(projectRoot string) ([]byte, error) {
	requiredFiles := []string{"main.json", "capabilities.json"}
	for _, name := range requiredFiles {
		if info, err := os.Stat(filepath.Join(projectRoot, name)); err != nil || info.IsDir() {
			return nil, fmt.Errorf("当前项目缺少 %s", name)
		}
	}
	appRoot := filepath.Join(projectRoot, "app")
	if info, err := os.Stat(appRoot); err != nil || !info.IsDir() {
		return nil, errors.New("当前项目缺少 app/ 目录；请先执行 playmesh-cli get")
	}
	paths := append([]string{}, requiredFiles...)
	iconPath := filepath.Join(projectRoot, rootIconName)
	if info, err := os.Lstat(iconPath); err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("游戏包不允许符号链接: %s", iconPath)
		}
		if !info.Mode().IsRegular() {
			return nil, errors.New("icon.png 必须是普通文件")
		}
		if info.Size() <= maxRootIconBytes {
			icon, err := os.ReadFile(iconPath)
			if err != nil {
				return nil, err
			}
			if isSafeRootIcon(icon) {
				paths = append(paths, rootIconName)
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	err := filepath.WalkDir(appRoot, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("游戏包不允许符号链接: %s", path)
		}
		if !entry.IsDir() {
			relative, err := filepath.Rel(projectRoot, path)
			if err != nil {
				return err
			}
			paths = append(paths, filepath.ToSlash(relative))
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(paths)
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for _, relative := range paths {
		if relative != "main.json" && relative != "capabilities.json" &&
			relative != rootIconName && !strings.HasPrefix(relative, "app/") {
			return nil, fmt.Errorf("拒绝打包越界文件: %s", relative)
		}
		data, err := os.ReadFile(filepath.Join(projectRoot, filepath.FromSlash(relative)))
		if err != nil {
			writer.Close()
			return nil, err
		}
		if relative == "main.json" {
			var manifest map[string]any
			if err := json.Unmarshal(data, &manifest); err != nil {
				writer.Close()
				return nil, fmt.Errorf("main.json 无效: %w", err)
			}
			manifest = projectManifest(manifest)
			data, err = json.MarshalIndent(manifest, "", "  ")
			if err != nil {
				writer.Close()
				return nil, err
			}
			data = append(data, '\n')
		}
		entry, err := writer.Create(relative)
		if err != nil {
			writer.Close()
			return nil, err
		}
		if _, err := entry.Write(data); err != nil {
			writer.Close()
			return nil, err
		}
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}

func extractProjectPackage(data []byte, target string) error {
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return fmt.Errorf("项目包无效: %w", err)
	}
	temporary, err := os.MkdirTemp(filepath.Dir(target), ".playmesh-get-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temporary)
	seen := make(map[string]struct{}, len(reader.File))
	for _, entry := range reader.File {
		name := strings.ReplaceAll(entry.Name, "\\", "/")
		if name == "" || strings.HasPrefix(name, "/") || strings.Contains(name, "../") {
			return fmt.Errorf("项目包包含非法路径: %s", entry.Name)
		}
		if name != "main.json" && name != "capabilities.json" &&
			name != rootIconName && !strings.HasPrefix(name, "app/") {
			return fmt.Errorf("项目包包含不允许的路径: %s", name)
		}
		if _, exists := seen[name]; exists {
			return fmt.Errorf("项目包包含重复路径: %s", name)
		}
		seen[name] = struct{}{}
		if entry.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("项目包不允许符号链接: %s", name)
		}
		if entry.FileInfo().IsDir() {
			if name == rootIconName {
				return errors.New("项目包中的 icon.png 必须是普通文件")
			}
			continue
		}
		if name == rootIconName && entry.UncompressedSize64 > maxRootIconBytes {
			continue
		}
		output := filepath.Join(temporary, filepath.FromSlash(name))
		cleanRoot := filepath.Clean(temporary) + string(os.PathSeparator)
		if !strings.HasPrefix(filepath.Clean(output), cleanRoot) {
			return fmt.Errorf("项目包路径越界: %s", name)
		}
		if err := os.MkdirAll(filepath.Dir(output), 0o755); err != nil {
			return err
		}
		input, err := entry.Open()
		if err != nil {
			return err
		}
		file, err := os.OpenFile(output, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
		if err != nil {
			input.Close()
			return err
		}
		limit := int64((32 << 20) + 1)
		if name == rootIconName {
			limit = maxRootIconBytes + 1
		}
		written, copyErr := io.Copy(file, io.LimitReader(input, limit))
		closeErr := file.Close()
		input.Close()
		if copyErr != nil {
			return copyErr
		}
		if name == rootIconName && written > maxRootIconBytes {
			_ = os.Remove(output)
			continue
		}
		if written > 32<<20 {
			return fmt.Errorf("项目包中的文件超过 32 MiB 限制: %s", name)
		}
		if closeErr != nil {
			return closeErr
		}
		if name == rootIconName {
			icon, err := os.ReadFile(output)
			if err != nil {
				return err
			}
			if !isSafeRootIcon(icon) {
				if err := os.Remove(output); err != nil {
					return err
				}
			}
		}
	}
	if _, err := os.Stat(filepath.Join(temporary, "main.json")); err != nil {
		return errors.New("项目包缺少 main.json")
	}
	if _, err := os.Stat(filepath.Join(temporary, "capabilities.json")); os.IsNotExist(err) {
		if err := os.WriteFile(filepath.Join(temporary, "capabilities.json"), []byte("{\n  \"required\": []\n}\n"), 0o644); err != nil {
			return err
		}
	}
	for _, mapping := range []struct{ source, destination string }{
		{source: "main.json", destination: "main.json"},
		{source: rootIconName, destination: rootIconName},
		{source: "capabilities.json", destination: "capabilities.json"},
		{source: "app", destination: "app"},
	} {
		source := filepath.Join(temporary, mapping.source)
		destination := filepath.Join(target, mapping.destination)
		if _, err := os.Stat(source); os.IsNotExist(err) {
			if mapping.source == rootIconName {
				if err := os.Remove(destination); err != nil && !errors.Is(err, os.ErrNotExist) {
					return err
				}
			}
			continue
		}
		if mapping.source == "app" {
			if err := replaceDirectory(source, destination); err != nil {
				return err
			}
		} else {
			if err := replaceFile(source, destination); err != nil {
				return err
			}
		}
	}
	return nil
}

func isSafeRootIcon(data []byte) bool {
	if len(data) == 0 || len(data) > maxRootIconBytes {
		return false
	}
	config, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil || config.Width < 1 || config.Height < 1 ||
		config.Width > maxRootIconEdge || config.Height > maxRootIconEdge {
		return false
	}
	if int64(config.Width)*int64(config.Height) > maxRootIconPixels {
		return false
	}
	_, err = png.Decode(bytes.NewReader(data))
	return err == nil
}
