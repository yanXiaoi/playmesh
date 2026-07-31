package testutil

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

func WriteFile(testingContext testing.TB, path, value string) {
	testingContext.Helper()
	WriteBytes(testingContext, path, []byte(value))
}

func WriteBytes(testingContext testing.TB, path string, value []byte) {
	testingContext.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		testingContext.Fatal(err)
	}
	if err := os.WriteFile(path, value, 0o644); err != nil {
		testingContext.Fatal(err)
	}
}

func ValidPNG(testingContext testing.TB) []byte {
	testingContext.Helper()
	var buffer bytes.Buffer
	icon := image.NewRGBA(image.Rect(0, 0, 2, 2))
	icon.Set(0, 0, color.RGBA{R: 0x25, G: 0xb8, B: 0x7a, A: 0xff})
	if err := png.Encode(&buffer, icon); err != nil {
		testingContext.Fatal(err)
	}
	return buffer.Bytes()
}
