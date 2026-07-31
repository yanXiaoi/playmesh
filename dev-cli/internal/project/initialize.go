package project

import (
	"errors"
	"os"
	"path/filepath"
)

func EnsureNotInitialized(root string) error {
	if _, err := os.Lstat(filepath.Join(root, ConfigName)); err == nil {
		return errors.New("当前项目已经执行过 Playmesh 初始化")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	for _, manifest := range []string{
		filepath.Join(root, "main.json"),
		filepath.Join(root, "playmesh", "package", "main.json"),
	} {
		if _, err := os.Lstat(manifest); err == nil {
			return errors.New("当前目录已经是 Playmesh 项目，不能再次初始化")
		} else if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}
