package captcha

import (
	"bytes"
	"context"
	"encoding/base64"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestWebPDecoderIsRegistered(t *testing.T) {
	content, err := base64.StdEncoding.DecodeString(
		"UklGRkYAAABXRUJQVlA4IDoAAABwAgCdASoEAAQAAYcIhYWIhYSIiQIADAzdrBLe" +
			"ABAAAAEAAAEAAPKn5Nn/0v8//Zxn/6H3QAAAAAA=",
	)
	if err != nil {
		t.Fatal(err)
	}
	// The common browser feature-detection sample omits the RIFF alignment
	// byte. Go's decoder intentionally requires the complete container.
	content = append(content, 0)
	if _, format, err := image.Decode(bytes.NewReader(content)); err != nil {
		t.Fatalf("decode WebP: %v", err)
	} else if format != "webp" {
		t.Fatalf("decoded format = %q, want webp", format)
	}
}

func TestLocalImageProviderChoosesRandomImages(t *testing.T) {
	directory := t.TempDir()
	writeTestPNG(t, filepath.Join(directory, "red.png"), color.NRGBA{R: 255, A: 255})
	writeTestPNG(t, filepath.Join(directory, "blue.png"), color.NRGBA{B: 255, A: 255})

	provider := newImageProvider(Options{
		ImageSource:         "local",
		LocalImageDirectory: directory,
	}, nil)
	if err := provider.Warm(context.Background(), 320, 200); err != nil {
		t.Fatal(err)
	}
	seen := make(map[color.Color]struct{})
	for index := 0; index < 100; index++ {
		selected, err := provider.Take(context.Background(), 320, 200)
		if err != nil {
			t.Fatal(err)
		}
		seen[selected.At(selected.Bounds().Min.X, selected.Bounds().Min.Y)] = struct{}{}
	}
	if len(seen) != 2 {
		t.Fatalf("local random selection saw %d image(s), want 2", len(seen))
	}
}

func TestRemoteImageProviderConsumesAndRefillsCache(t *testing.T) {
	var requests atomic.Int32
	var cacheBusters sync.Map
	var missingCacheBuster atomic.Bool
	var duplicateCacheBuster atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		cacheBuster := request.URL.Query().Get("_playmesh_captcha")
		if cacheBuster == "" {
			missingCacheBuster.Store(true)
		} else if _, loaded := cacheBusters.LoadOrStore(cacheBuster, struct{}{}); loaded {
			duplicateCacheBuster.Store(true)
		}
		number := requests.Add(1)
		writer.Header().Set("Content-Type", "image/png")
		source := image.NewNRGBA(image.Rect(0, 0, 640, 480))
		fill := color.NRGBA{R: uint8(number), G: 80, B: 120, A: 255}
		for y := 0; y < source.Bounds().Dy(); y++ {
			for x := 0; x < source.Bounds().Dx(); x++ {
				source.SetNRGBA(x, y, fill)
			}
		}
		if err := png.Encode(writer, source); err != nil {
			t.Error(err)
		}
	}))
	defer server.Close()

	provider := newImageProvider(Options{
		ImageSource:          "remote",
		RemoteImageURL:       server.URL,
		RemoteImageCacheSize: 3,
	}, nil)
	if err := provider.Warm(context.Background(), 320, 200); err != nil {
		t.Fatal(err)
	}
	if requests.Load() != 3 {
		t.Fatalf("pre-cache requests = %d, want 3", requests.Load())
	}
	selected, err := provider.Take(context.Background(), 320, 200)
	if err != nil {
		t.Fatal(err)
	}
	if selected.Bounds().Dx() != 320 || selected.Bounds().Dy() != 200 {
		t.Fatalf("remote image size = %v, want 320x200", selected.Bounds())
	}
	deadline := time.Now().Add(3 * time.Second)
	for requests.Load() < 4 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if requests.Load() < 4 {
		t.Fatal("remote cache was not refilled after an image was consumed")
	}
	if missingCacheBuster.Load() || duplicateCacheBuster.Load() {
		t.Fatal("remote image requests must carry a unique cache-busting query")
	}
}

func TestRemoteImageProviderFollowsImageRedirect(t *testing.T) {
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(
		writer http.ResponseWriter,
		request *http.Request,
	) {
		if request.URL.Path == "/random" {
			http.Redirect(writer, request, server.URL+"/image.webp", http.StatusMovedPermanently)
			return
		}
		if accept := request.Header.Get("Accept"); accept !=
			"image/webp,image/png,image/jpeg,image/gif" {
			t.Errorf("Accept = %q", accept)
		}
		writer.Header().Set("Content-Type", "image/png")
		source := image.NewNRGBA(image.Rect(0, 0, 96, 96))
		if err := png.Encode(writer, source); err != nil {
			t.Error(err)
		}
	}))
	defer server.Close()

	provider := newImageProvider(Options{
		ImageSource:          "remote",
		RemoteImageURL:       server.URL + "/random",
		RemoteImageCacheSize: 1,
	}, nil)
	if err := provider.Warm(context.Background(), 64, 64); err != nil {
		t.Fatal(err)
	}
}

func TestCropAndScaleUsesCenterCrop(t *testing.T) {
	source := image.NewNRGBA(image.Rect(0, 0, 400, 200))
	for y := 0; y < 200; y++ {
		for x := 0; x < 400; x++ {
			value := color.NRGBA{G: 255, A: 255}
			if x < 100 {
				value = color.NRGBA{R: 255, A: 255}
			} else if x >= 300 {
				value = color.NRGBA{B: 255, A: 255}
			}
			source.SetNRGBA(x, y, value)
		}
	}
	result := cropAndScale(source, 200, 200)
	center := color.NRGBAModel.Convert(result.At(100, 100)).(color.NRGBA)
	if center.G < 250 || center.R > 5 || center.B > 5 {
		t.Fatalf("center pixel = %#v, want green center crop", center)
	}
}

func TestMotionCaptchaValidation(t *testing.T) {
	if !validateSlideCaptcha(120, 80, "slide:124,78") {
		t.Fatal("slide answer inside tolerance was rejected")
	}
	if validateSlideCaptcha(120, 80, "slide:150,80") {
		t.Fatal("slide answer outside tolerance was accepted")
	}
	if !validateRotateCaptcha(130, "rotate:230") {
		t.Fatal("matching rotation answer was rejected")
	}
	if validateRotateCaptcha(130, "rotate:180") {
		t.Fatal("incorrect rotation answer was accepted")
	}
}

func writeTestPNG(t *testing.T, path string, fill color.NRGBA) {
	t.Helper()
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	source := image.NewNRGBA(image.Rect(0, 0, 96, 96))
	for y := 0; y < source.Bounds().Dy(); y++ {
		for x := 0; x < source.Bounds().Dx(); x++ {
			source.SetNRGBA(x, y, fill)
		}
	}
	if err := png.Encode(file, source); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
}
