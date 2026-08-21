package appnative

import (
	"bytes"
	"errors"
	"fmt"
	"image/png"
	"path/filepath"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/tc-hib/winres"
	winversion "github.com/tc-hib/winres/version"
)

const (
	windowsRuntimeMaxExecutableBytes = 64 << 20
	windowsRuntimeMaxIconPNG         = 8 << 20
	windowsRuntimeMaxIconDimension   = 4096
	windowsRuntimeIconResourceID     = 101
	windowsRuntimeVersionResourceID  = 1
	windowsRuntimeMaxLabelRunes      = 160
	windowsRuntimeMaxExeNameRunes    = 120
)

var windowsReservedExecutableBaseNames = map[string]struct{}{
	"CON": {}, "PRN": {}, "AUX": {}, "NUL": {},
	"CONIN$": {}, "CONOUT$": {},
	"COM1": {}, "COM2": {}, "COM3": {}, "COM4": {}, "COM5": {},
	"COM6": {}, "COM7": {}, "COM8": {}, "COM9": {},
	"COM¹": {}, "COM²": {}, "COM³": {},
	"LPT1": {}, "LPT2": {}, "LPT3": {}, "LPT4": {}, "LPT5": {},
	"LPT6": {}, "LPT7": {}, "LPT8": {}, "LPT9": {},
	"LPT¹": {}, "LPT²": {}, "LPT³": {},
}

func validateWindowsRuntimeExecutableName(name string) error {
	if name == "" || name != strings.TrimSpace(name) ||
		filepath.Base(name) != name || strings.ContainsAny(name, `<>:"/\|?*`) ||
		strings.HasSuffix(name, ".") || strings.HasSuffix(name, " ") ||
		!strings.EqualFold(filepath.Ext(name), ".exe") {
		return errors.New("runtime export: executableName must be a safe Windows .exe filename")
	}
	if !utf8.ValidString(name) || utf8.RuneCountInString(name) > windowsRuntimeMaxExeNameRunes {
		return errors.New("runtime export: executableName is invalid or too long")
	}
	for _, char := range name {
		if char == 0 || unicode.IsControl(char) {
			return errors.New("runtime export: executableName contains a control character")
		}
	}
	base := strings.TrimSuffix(name, filepath.Ext(name))
	if base == "" {
		return errors.New("runtime export: executableName has an empty base name")
	}
	deviceBase := base
	if dot := strings.IndexByte(deviceBase, '.'); dot >= 0 {
		deviceBase = deviceBase[:dot]
	}
	if _, reserved := windowsReservedExecutableBaseNames[strings.ToUpper(deviceBase)]; reserved {
		return errors.New("runtime export: executableName uses a reserved Windows device name")
	}
	return nil
}

func validateWindowsRuntimeLabel(label string) error {
	if label == "" || label != strings.TrimSpace(label) || !utf8.ValidString(label) ||
		utf8.RuneCountInString(label) > windowsRuntimeMaxLabelRunes {
		return errors.New("runtime export: label is empty, invalid, or too long")
	}
	for _, char := range label {
		if char == 0 || unicode.IsControl(char) {
			return errors.New("runtime export: label contains a control character")
		}
	}
	return nil
}

func parseWindowsRuntimeVersion(value string) ([4]uint16, error) {
	var result [4]uint16
	parts := strings.Split(value, ".")
	if len(parts) != 3 {
		return result, errors.New("runtime export: versionName must be MAJOR.MINOR.PATCH")
	}
	for index, part := range parts {
		if part == "" || (len(part) > 1 && part[0] == '0') {
			return result, errors.New("runtime export: versionName contains an invalid numeric component")
		}
		number, err := strconv.ParseUint(part, 10, 16)
		if err != nil {
			return result, errors.New("runtime export: versionName component exceeds 65535")
		}
		result[index] = uint16(number)
	}
	return result, nil
}

func customizeWindowsRuntimeExecutable(
	executable []byte,
	executableName string,
	label string,
	versionName string,
	iconPNG []byte,
) ([]byte, error) {
	if len(executable) == 0 || len(executable) > windowsRuntimeMaxExecutableBytes {
		return nil, errors.New("fixed executable is empty or exceeds the size limit")
	}
	if err := validateWindowsRuntimeExecutableName(executableName); err != nil {
		return nil, err
	}
	if err := validateWindowsRuntimeLabel(label); err != nil {
		return nil, err
	}
	versionParts, err := parseWindowsRuntimeVersion(versionName)
	if err != nil {
		return nil, err
	}

	resources, err := winres.LoadFromEXE(bytes.NewReader(executable))
	if err != nil {
		return nil, fmt.Errorf("load PE resources: %w", err)
	}
	versionBytes := resources.Get(
		winres.RT_VERSION,
		winres.ID(windowsRuntimeVersionResourceID),
		winres.LCIDDefault,
	)
	if len(versionBytes) == 0 {
		return nil, errors.New("fixed executable is missing en-US VERSIONINFO resource #1")
	}
	// Build a canonical Unicode VERSIONINFO rather than carrying the template's
	// legacy 1252 string-table marker forward. Runtime storage uses an explicit
	// gameId-derived directory, so ProductName can safely follow the game-facing
	// label without becoming the persistence identity.
	versionInfo := &winversion.Info{
		FileVersion:    versionParts,
		ProductVersion: versionParts,
	}
	for key, value := range map[string]string{
		winversion.CompanyName:      "top.zfjmm",
		winversion.FileDescription:  label,
		winversion.FileVersion:      versionName,
		winversion.InternalName:     strings.TrimSuffix(executableName, filepath.Ext(executableName)),
		winversion.LegalCopyright:   "Copyright (C) 2026 top.zfjmm. All rights reserved.",
		winversion.OriginalFilename: executableName,
		winversion.ProductName:      label,
		winversion.ProductVersion:   versionName,
	} {
		if err := versionInfo.Set(winres.LCIDDefault, key, value); err != nil {
			return nil, fmt.Errorf("set VERSIONINFO %s: %w", key, err)
		}
	}
	resources.SetVersionInfo(*versionInfo)

	if len(iconPNG) != 0 {
		if len(iconPNG) > windowsRuntimeMaxIconPNG {
			return nil, errors.New("icon PNG exceeds the size limit")
		}
		config, err := png.DecodeConfig(bytes.NewReader(iconPNG))
		if err != nil {
			return nil, fmt.Errorf("decode icon PNG header: %w", err)
		}
		if config.Width <= 0 || config.Height <= 0 ||
			config.Width > windowsRuntimeMaxIconDimension ||
			config.Height > windowsRuntimeMaxIconDimension ||
			int64(config.Width)*int64(config.Height) > 16_000_000 {
			return nil, errors.New("icon PNG dimensions exceed the limit")
		}
		image, err := png.Decode(bytes.NewReader(iconPNG))
		if err != nil {
			return nil, fmt.Errorf("decode icon PNG: %w", err)
		}
		icon, err := winres.NewIconFromResizedImage(image, nil)
		if err != nil {
			return nil, fmt.Errorf("build Windows icon resources: %w", err)
		}
		if err := resources.SetIconTranslation(
			winres.ID(windowsRuntimeIconResourceID),
			winres.LCIDDefault,
			icon,
		); err != nil {
			return nil, fmt.Errorf("replace Windows icon resource: %w", err)
		}
	}

	var output bytes.Buffer
	if err := resources.WriteToEXE(&output, bytes.NewReader(executable)); err != nil {
		return nil, fmt.Errorf("write customized PE resources: %w", err)
	}
	if output.Len() == 0 || output.Len() > windowsRuntimeMaxExecutableBytes {
		return nil, errors.New("customized executable has an invalid size")
	}
	return output.Bytes(), nil
}
