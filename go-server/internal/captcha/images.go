package captcha

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"log/slog"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/image/draw"
)

const (
	maxCaptchaImageBytes  = 8 << 20
	maxCaptchaImagePixels = 36_000_000
)

type imageProvider struct {
	source     string
	directory  string
	remoteURL  string
	cacheSize  int
	logger     *slog.Logger
	httpClient *http.Client

	mutex       sync.Mutex
	localImages []image.Image
	buckets     map[string]*imageBucket
	requestID   atomic.Uint64
}

type imageBucket struct {
	width   int
	height  int
	images  []image.Image
	filling bool
}

func newImageProvider(options Options, logger *slog.Logger) *imageProvider {
	return &imageProvider{
		source:    options.ImageSource,
		directory: options.LocalImageDirectory,
		remoteURL: options.RemoteImageURL,
		cacheSize: options.RemoteImageCacheSize,
		logger:    logger,
		httpClient: &http.Client{
			Timeout: 8 * time.Second,
			CheckRedirect: func(request *http.Request, via []*http.Request) error {
				if len(via) >= 3 {
					return errors.New("captcha image redirect limit exceeded")
				}
				if request.URL.Scheme != "http" && request.URL.Scheme != "https" {
					return errors.New("captcha image redirect must use HTTP or HTTPS")
				}
				return nil
			},
		},
		buckets: make(map[string]*imageBucket),
	}
}

func (p *imageProvider) Warm(ctx context.Context, width, height int) error {
	if p.source == "local" {
		return p.loadLocalImages()
	}
	if p.source != "remote" {
		return fmt.Errorf("unsupported CAPTCHA image source %q", p.source)
	}
	return p.fillRemote(ctx, width, height, true)
}

func (p *imageProvider) Take(
	ctx context.Context,
	width int,
	height int,
) (image.Image, error) {
	if p.source == "local" {
		p.mutex.Lock()
		if len(p.localImages) > 0 {
			result := p.localImages[rand.Intn(len(p.localImages))] // #nosec G404
			p.mutex.Unlock()
			return result, nil
		}
		p.mutex.Unlock()
		if err := p.loadLocalImages(); err != nil {
			return nil, err
		}
		p.mutex.Lock()
		defer p.mutex.Unlock()
		return p.localImages[rand.Intn(len(p.localImages))], nil // #nosec G404
	}
	if p.source != "remote" {
		return nil, fmt.Errorf("unsupported CAPTCHA image source %q", p.source)
	}

	key := imageBucketKey(width, height)
	p.mutex.Lock()
	bucket := p.bucketLocked(key, width, height)
	if len(bucket.images) > 0 {
		result := bucket.images[0]
		bucket.images = bucket.images[1:]
		needsFill := len(bucket.images) < p.cacheSize && !bucket.filling
		if needsFill {
			bucket.filling = true
		}
		p.mutex.Unlock()
		if needsFill {
			go p.refillRemote(key, width, height)
		}
		return result, nil
	}
	p.mutex.Unlock()

	source, err := p.download(ctx)
	if err != nil {
		return nil, err
	}
	result := cropAndScale(source, width, height)
	p.mutex.Lock()
	bucket = p.bucketLocked(key, width, height)
	needsFill := len(bucket.images) < p.cacheSize && !bucket.filling
	if needsFill {
		bucket.filling = true
	}
	p.mutex.Unlock()
	if needsFill {
		go p.refillRemote(key, width, height)
	}
	return result, nil
}

func (p *imageProvider) loadLocalImages() error {
	entries, err := os.ReadDir(p.directory)
	if err != nil {
		return fmt.Errorf("read local CAPTCHA image directory: %w", err)
	}
	images := make([]image.Image, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		extension := strings.ToLower(filepath.Ext(entry.Name()))
		if extension != ".jpg" && extension != ".jpeg" &&
			extension != ".png" && extension != ".gif" {
			continue
		}
		path := filepath.Join(p.directory, entry.Name())
		content, err := os.ReadFile(path) // #nosec G304 -- operator-configured image directory.
		if err != nil || len(content) == 0 || len(content) > maxCaptchaImageBytes {
			continue
		}
		decoded, err := decodeCaptchaImage(content)
		if err == nil {
			images = append(images, decoded)
		}
	}
	if len(images) == 0 {
		return errors.New("local CAPTCHA image directory contains no usable images")
	}
	p.mutex.Lock()
	p.localImages = images
	p.mutex.Unlock()
	return nil
}

func (p *imageProvider) refillRemote(key string, width, height int) {
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if err := p.fillRemote(ctx, width, height, false); err != nil && p.logger != nil {
		p.logger.Warn("captcha image cache refill failed", "error", err)
	}
	p.mutex.Lock()
	if bucket := p.buckets[key]; bucket != nil {
		bucket.filling = false
	}
	p.mutex.Unlock()
}

func (p *imageProvider) fillRemote(
	ctx context.Context,
	width int,
	height int,
	markFilling bool,
) error {
	key := imageBucketKey(width, height)
	p.mutex.Lock()
	bucket := p.bucketLocked(key, width, height)
	if markFilling {
		if bucket.filling {
			p.mutex.Unlock()
			return nil
		}
		bucket.filling = true
	}
	required := p.cacheSize - len(bucket.images)
	p.mutex.Unlock()
	if required <= 0 {
		if markFilling {
			p.finishFill(key)
		}
		return nil
	}

	type result struct {
		image image.Image
		err   error
	}
	results := make(chan result, required)
	limit := make(chan struct{}, 4)
	var wait sync.WaitGroup
	for index := 0; index < required; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			select {
			case limit <- struct{}{}:
				defer func() { <-limit }()
			case <-ctx.Done():
				results <- result{err: ctx.Err()}
				return
			}
			source, err := p.download(ctx)
			if err != nil {
				results <- result{err: err}
				return
			}
			results <- result{image: cropAndScale(source, width, height)}
		}()
	}
	wait.Wait()
	close(results)

	downloaded := make([]image.Image, 0, required)
	var lastError error
	for item := range results {
		if item.err != nil {
			lastError = item.err
			continue
		}
		downloaded = append(downloaded, item.image)
	}
	p.mutex.Lock()
	bucket = p.bucketLocked(key, width, height)
	available := p.cacheSize - len(bucket.images)
	if available > len(downloaded) {
		available = len(downloaded)
	}
	bucket.images = append(bucket.images, downloaded[:available]...)
	if markFilling {
		bucket.filling = false
	}
	total := len(bucket.images)
	p.mutex.Unlock()
	if total == 0 {
		if lastError != nil {
			return fmt.Errorf("fill remote CAPTCHA image cache: %w", lastError)
		}
		return errors.New("remote CAPTCHA image cache is empty")
	}
	if p.logger != nil && len(downloaded) > 0 {
		p.logger.Debug(
			"captcha image cache filled",
			"size", fmt.Sprintf("%dx%d", width, height),
			"cached", total,
		)
	}
	return nil
}

func (p *imageProvider) finishFill(key string) {
	p.mutex.Lock()
	if bucket := p.buckets[key]; bucket != nil {
		bucket.filling = false
	}
	p.mutex.Unlock()
}

func (p *imageProvider) bucketLocked(
	key string,
	width int,
	height int,
) *imageBucket {
	bucket := p.buckets[key]
	if bucket == nil {
		bucket = &imageBucket{width: width, height: height}
		p.buckets[key] = bucket
	}
	return bucket
}

func (p *imageProvider) download(ctx context.Context) (image.Image, error) {
	parsed, err := url.Parse(p.remoteURL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return nil, errors.New("remote CAPTCHA image URL is invalid")
	}
	query := parsed.Query()
	query.Set(
		"_playmesh_captcha",
		fmt.Sprintf("%d-%d", time.Now().UnixNano(), p.requestID.Add(1)),
	)
	parsed.RawQuery = query.Encode()
	request, err := http.NewRequestWithContext(
		ctx, http.MethodGet, parsed.String(), nil,
	)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "image/avif,image/webp,image/png,image/jpeg,image/gif")
	request.Header.Set("Cache-Control", "no-cache, no-store")
	request.Header.Set("Pragma", "no-cache")
	request.Header.Set("User-Agent", "Playmesh-Captcha/1.0")
	response, err := p.httpClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf(
			"remote CAPTCHA image server returned HTTP %d",
			response.StatusCode,
		)
	}
	content, err := io.ReadAll(io.LimitReader(response.Body, maxCaptchaImageBytes+1))
	if err != nil {
		return nil, err
	}
	if len(content) == 0 || len(content) > maxCaptchaImageBytes {
		return nil, errors.New("remote CAPTCHA image is empty or exceeds 8 MiB")
	}
	return decodeCaptchaImage(content)
}

func decodeCaptchaImage(content []byte) (image.Image, error) {
	dimensions, _, err := image.DecodeConfig(bytes.NewReader(content))
	if err != nil {
		return nil, errors.New("CAPTCHA image format is unsupported")
	}
	if dimensions.Width < 64 || dimensions.Height < 64 ||
		dimensions.Width > 8192 || dimensions.Height > 8192 ||
		dimensions.Width*dimensions.Height > maxCaptchaImagePixels {
		return nil, errors.New("CAPTCHA image dimensions are outside safe limits")
	}
	decoded, _, err := image.Decode(bytes.NewReader(content))
	if err != nil {
		return nil, errors.New("CAPTCHA image could not be decoded")
	}
	return decoded, nil
}

func cropAndScale(source image.Image, width, height int) image.Image {
	bounds := source.Bounds()
	sourceWidth := bounds.Dx()
	sourceHeight := bounds.Dy()
	targetRatio := float64(width) / float64(height)
	sourceRatio := float64(sourceWidth) / float64(sourceHeight)
	crop := bounds
	if sourceRatio > targetRatio {
		cropWidth := int(float64(sourceHeight) * targetRatio)
		offset := (sourceWidth - cropWidth) / 2
		crop.Min.X += offset
		crop.Max.X = crop.Min.X + cropWidth
	} else if sourceRatio < targetRatio {
		cropHeight := int(float64(sourceWidth) / targetRatio)
		offset := (sourceHeight - cropHeight) / 2
		crop.Min.Y += offset
		crop.Max.Y = crop.Min.Y + cropHeight
	}
	destination := image.NewNRGBA(image.Rect(0, 0, width, height))
	draw.CatmullRom.Scale(
		destination,
		destination.Bounds(),
		source,
		crop,
		draw.Src,
		nil,
	)
	return destination
}

func imageBucketKey(width, height int) string {
	return fmt.Sprintf("%dx%d", width, height)
}
