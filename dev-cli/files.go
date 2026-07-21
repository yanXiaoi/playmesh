package main

import (
	"archive/zip"
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
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
		if relative != "main.json" && relative != "capabilities.json" && !strings.HasPrefix(relative, "app/") {
			return nil, fmt.Errorf("拒绝打包越界文件: %s", relative)
		}
		data, err := os.ReadFile(filepath.Join(projectRoot, filepath.FromSlash(relative)))
		if err != nil {
			writer.Close()
			return nil, err
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
	for _, entry := range reader.File {
		name := strings.ReplaceAll(entry.Name, "\\", "/")
		if name == "" || strings.HasPrefix(name, "/") || strings.Contains(name, "../") {
			return fmt.Errorf("项目包包含非法路径: %s", entry.Name)
		}
		if name != "main.json" && name != "capabilities.json" && !strings.HasPrefix(name, "app/") {
			return fmt.Errorf("项目包包含不允许的路径: %s", name)
		}
		if entry.FileInfo().IsDir() {
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
		written, copyErr := io.Copy(file, io.LimitReader(input, (32<<20)+1))
		closeErr := file.Close()
		input.Close()
		if copyErr != nil {
			return copyErr
		}
		if written > 32<<20 {
			return fmt.Errorf("项目包中的文件超过 32 MiB 限制: %s", name)
		}
		if closeErr != nil {
			return closeErr
		}
	}
	if _, err := os.Stat(filepath.Join(temporary, "main.json")); err != nil {
		return errors.New("项目包缺少 main.json")
	}
	if _, err := os.Stat(filepath.Join(temporary, "app")); err != nil {
		return errors.New("项目包缺少 app/")
	}
	if _, err := os.Stat(filepath.Join(temporary, "capabilities.json")); os.IsNotExist(err) {
		if err := os.WriteFile(filepath.Join(temporary, "capabilities.json"), []byte("{\n  \"required\": []\n}\n"), 0o644); err != nil {
			return err
		}
	}
	for _, mapping := range []struct{ source, destination string }{
		{source: "main.json", destination: "main.json"},
		{source: "capabilities.json", destination: "capabilities.json"},
		{source: "app", destination: "app"},
	} {
		source := filepath.Join(temporary, mapping.source)
		destination := filepath.Join(target, mapping.destination)
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
