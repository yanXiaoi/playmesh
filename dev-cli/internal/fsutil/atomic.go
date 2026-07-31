package fsutil

import (
	"io/fs"
	"os"
	"path/filepath"
)

func ReplaceFile(source, target string) error {
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

func ReplaceDirectory(source, target string) error {
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

func WriteAtomicFile(path string, data []byte, mode fs.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	temporary := path + ".playmesh-tmp"
	if err := os.WriteFile(temporary, data, mode); err != nil {
		return err
	}
	return ReplaceFile(temporary, path)
}
