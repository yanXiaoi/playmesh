package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"go-core/appnative"
)

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(2)
	}

	switch os.Args[1] {
	case "sign":
		runSign(os.Args[2:])
	case "info":
		runInfo(os.Args[2:])
	case "verify":
		runVerify(os.Args[2:])
	case "export-android":
		runRuntimeExport("export-android", os.Args[2:], appnative.ExportAndroidRuntime)
	case "export-windows":
		runRuntimeExport("export-windows", os.Args[2:], appnative.ExportWindowsRuntime)
	case "version", "--version", "-version":
		fmt.Println(appnative.ApkSigVersion())
	case "help", "--help", "-h":
		printUsage()
	default:
		fatal("unknown command %q", os.Args[1])
	}
}

func runRuntimeExport(command string, arguments []string, export func(string) (string, error)) {
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	request := flags.String("request", "", "UTF-8 JSON request file; literal JSON is accepted for compatibility")
	requestFile := flags.String("request-file", "", "UTF-8 JSON request file (alias of -request)")
	if err := flags.Parse(arguments); err != nil {
		os.Exit(2)
	}
	if flags.NArg() != 0 {
		fatal("%s accepts only -request or -request-file", command)
	}
	requestJSON, err := resolveRuntimeExportRequest(*request, *requestFile)
	if err != nil {
		fatal("%s: %v", command, err)
	}
	report, err := export(requestJSON)
	if err != nil {
		fatal("%s: %v", command, err)
	}
	if !json.Valid([]byte(report)) {
		fatal("%s returned an invalid JSON report", command)
	}
	fmt.Println(report)
}

func runSign(arguments []string) {
	flags := flag.NewFlagSet("sign", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	input := flags.String("in", "", "final, already-aligned input APK")
	output := flags.String("out", "", "new signed APK path")
	keystore := flags.String("keystore", "", "JKS or PKCS#12 keystore")
	storePass := flags.String("storepass", "", "literal password, env:NAME, or file:PATH")
	keyPass := flags.String("keypass", "", "literal password, env:NAME, or file:PATH; defaults to storepass")
	alias := flags.String("alias", "", "key entry alias; defaults to first private-key entry")
	if err := flags.Parse(arguments); err != nil {
		os.Exit(2)
	}
	if flags.NArg() != 0 || *input == "" || *output == "" || *keystore == "" {
		fatal("sign requires -in, -out, and -keystore")
	}
	storePassword, err := resolvePassword(*storePass)
	if err != nil {
		fatal("storepass: %v", err)
	}
	keyPasswordSpec := *keyPass
	if keyPasswordSpec == "" {
		keyPasswordSpec = *storePass
	}
	keyPassword, err := resolvePassword(keyPasswordSpec)
	if err != nil {
		fatal("keypass: %v", err)
	}
	if err := appnative.SignApk(
		*input,
		*output,
		*keystore,
		storePassword,
		keyPassword,
		*alias,
	); err != nil {
		fatal("sign: %v", err)
	}
	report, err := appnative.VerifyApk(*output, 24, 36)
	if err != nil {
		fatal("verify signed output: %v", err)
	}
	fmt.Println(report)
}

func runInfo(arguments []string) {
	flags := flag.NewFlagSet("info", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	keystore := flags.String("keystore", "", "JKS or PKCS#12 keystore")
	storePass := flags.String("storepass", "", "literal password, env:NAME, or file:PATH")
	keyPass := flags.String("keypass", "", "literal password, env:NAME, or file:PATH; defaults to storepass")
	alias := flags.String("alias", "", "key entry alias; defaults to first private-key entry")
	if err := flags.Parse(arguments); err != nil {
		os.Exit(2)
	}
	if flags.NArg() != 0 || *keystore == "" {
		fatal("info requires -keystore")
	}
	storePassword, keyPassword := resolveKeystorePasswords(*storePass, *keyPass)
	report, err := appnative.ApkSignerInfo(
		*keystore,
		storePassword,
		keyPassword,
		*alias,
	)
	if err != nil {
		fatal("info: %v", err)
	}
	fmt.Println(report)
}

func runVerify(arguments []string) {
	flags := flag.NewFlagSet("verify", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	input := flags.String("in", "", "APK to verify")
	minSDK := flags.Int("min-sdk", 24, "minimum Android SDK")
	maxSDK := flags.Int("max-sdk", 36, "maximum Android SDK")
	if err := flags.Parse(arguments); err != nil {
		os.Exit(2)
	}
	if flags.NArg() != 0 || *input == "" {
		fatal("verify requires -in")
	}
	report, err := appnative.VerifyApk(*input, *minSDK, *maxSDK)
	if err != nil {
		fatal("verify: %v", err)
	}
	fmt.Println(report)
	var result struct {
		Verified bool `json:"verified"`
	}
	if err := json.Unmarshal([]byte(report), &result); err != nil {
		fatal("decode verification result: %v", err)
	}
	if !result.Verified {
		os.Exit(1)
	}
}

func resolveKeystorePasswords(storeSpec, keySpec string) (string, string) {
	storePassword, err := resolvePassword(storeSpec)
	if err != nil {
		fatal("storepass: %v", err)
	}
	if keySpec == "" {
		keySpec = storeSpec
	}
	keyPassword, err := resolvePassword(keySpec)
	if err != nil {
		fatal("keypass: %v", err)
	}
	return storePassword, keyPassword
}

func resolvePassword(specification string) (string, error) {
	if strings.HasPrefix(specification, "env:") {
		return os.Getenv(strings.TrimPrefix(specification, "env:")), nil
	}
	if strings.HasPrefix(specification, "file:") {
		path := strings.TrimPrefix(specification, "file:")
		if path == "" {
			return "", errors.New("password file path is empty")
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return "", err
		}
		defer clear(data)
		return strings.TrimRight(string(data), "\r\n"), nil
	}
	return specification, nil
}

func resolveRuntimeExportRequest(literal, filePath string) (string, error) {
	if literal != "" && filePath != "" {
		return "", errors.New("-request and -request-file are mutually exclusive")
	}
	if literal == "" && filePath == "" {
		return "", errors.New("one of -request or -request-file is required")
	}
	if filePath == "" && (strings.HasPrefix(strings.TrimSpace(literal), "{") || strings.HasPrefix(strings.TrimSpace(literal), "[")) {
		if !json.Valid([]byte(literal)) {
			return "", errors.New("-request is not valid JSON")
		}
		return literal, nil
	}
	if filePath == "" {
		filePath = literal
	}
	file, err := os.Open(filePath)
	if err != nil {
		return "", fmt.Errorf("open request file: %w", err)
	}
	defer file.Close()
	const maximumRequestBytes = 1024 * 1024
	data, err := io.ReadAll(io.LimitReader(file, maximumRequestBytes+1))
	if err != nil {
		return "", fmt.Errorf("read request file: %w", err)
	}
	if len(data) > maximumRequestBytes {
		return "", errors.New("request file exceeds 1 MiB")
	}
	if !json.Valid(data) {
		return "", errors.New("request file is not valid JSON")
	}
	return string(data), nil
}

func printUsage() {
	fmt.Fprintln(os.Stderr, "usage: playmesh-apksign <sign|info|verify|export-android|export-windows|version> [options]")
	fmt.Fprintln(os.Stderr, "sign always writes APK Signature Scheme v2 and never changes ZIP alignment")
	fmt.Fprintln(os.Stderr, "runtime export accepts -request PATH or the compatible -request-file PATH alias")
}

func fatal(format string, arguments ...any) {
	fmt.Fprintf(os.Stderr, "playmesh-apksign: "+format+"\n", arguments...)
	os.Exit(2)
}
