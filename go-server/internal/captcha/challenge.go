package captcha

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"image"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/golang/freetype/truetype"
	"github.com/wenlng/go-captcha-assets/bindata/chars"
	"github.com/wenlng/go-captcha-assets/resources/fonts/fzshengsksjw"
	"github.com/wenlng/go-captcha-assets/resources/tiles"
	"github.com/wenlng/go-captcha/v2/base/option"
	"github.com/wenlng/go-captcha/v2/click"
	"github.com/wenlng/go-captcha/v2/rotate"
	"github.com/wenlng/go-captcha/v2/slide"
)

const (
	clickCaptchaWidth    = 320
	clickCaptchaHeight   = 200
	clickCaptchaPadding  = 6
	motionCaptchaPadding = 6
)

type captchaPoint struct {
	X      int
	Y      int
	Width  int
	Height int
}

type captchaRecord struct {
	expiresAt   time.Time
	scope       string
	mode        string
	points      []captchaPoint
	targetX     int
	targetY     int
	targetAngle int
}

type captchaResponse struct {
	ID             string `json:"id"`
	Mode           string `json:"mode"`
	Image          string `json:"image"`
	PromptImage    string `json:"promptImage,omitempty"`
	RequiredClicks int    `json:"requiredClicks,omitempty"`
	PieceImage     string `json:"pieceImage,omitempty"`
	ImageWidth     int    `json:"imageWidth,omitempty"`
	ImageHeight    int    `json:"imageHeight,omitempty"`
	PieceX         int    `json:"pieceX,omitempty"`
	PieceY         int    `json:"pieceY,omitempty"`
	PieceWidth     int    `json:"pieceWidth,omitempty"`
	PieceHeight    int    `json:"pieceHeight,omitempty"`
}

type generatedCaptcha struct {
	response captchaResponse
	record   captchaRecord
}

var (
	slideGraphsOnce sync.Once
	slideGraphs     []*slide.GraphImage
	slideGraphsErr  error
)

func generateCaptcha(
	mode string,
	customClick click.Captcha,
	customSlide slide.Captcha,
	customRotate rotate.Captcha,
) (generatedCaptcha, error) {
	id, err := newCaptchaID()
	if err != nil {
		return generatedCaptcha{}, err
	}
	expiresAt := time.Now().Add(2 * time.Minute)
	switch mode {
	case "text":
		image, promptImage, points, err := generateClickCaptcha(customClick)
		if err != nil {
			return generatedCaptcha{}, err
		}
		return generatedCaptcha{
			response: captchaResponse{
				ID:             id,
				Mode:           "text",
				Image:          image,
				PromptImage:    promptImage,
				RequiredClicks: len(points),
				ImageWidth:     clickCaptchaWidth,
				ImageHeight:    clickCaptchaHeight,
			},
			record: captchaRecord{
				expiresAt: expiresAt,
				mode:      "text",
				points:    points,
			},
		}, nil
	case "slide":
		masterImage, pieceImage, block, err := generateSlideCaptcha(customSlide)
		if err != nil {
			return generatedCaptcha{}, err
		}
		return generatedCaptcha{
			response: captchaResponse{
				ID:          id,
				Mode:        "slide",
				Image:       masterImage,
				PieceImage:  pieceImage,
				ImageWidth:  clickCaptchaWidth,
				ImageHeight: clickCaptchaHeight,
				PieceX:      block.DX,
				PieceY:      block.DY,
				PieceWidth:  block.Width,
				PieceHeight: block.Height,
			},
			record: captchaRecord{
				expiresAt: expiresAt,
				mode:      "slide",
				targetX:   block.X,
				targetY:   block.Y,
			},
		}, nil
	case "rotate":
		masterImage, pieceImage, block, err := generateRotateCaptcha(customRotate)
		if err != nil {
			return generatedCaptcha{}, err
		}
		return generatedCaptcha{
			response: captchaResponse{
				ID:          id,
				Mode:        "rotate",
				Image:       masterImage,
				PieceImage:  pieceImage,
				ImageWidth:  clickCaptchaHeight,
				ImageHeight: clickCaptchaHeight,
				PieceWidth:  block.Width,
				PieceHeight: block.Height,
			},
			record: captchaRecord{
				expiresAt:   expiresAt,
				mode:        "rotate",
				targetAngle: block.Angle,
			},
		}, nil
	}

	return generatedCaptcha{}, fmt.Errorf("unsupported captcha mode %q", mode)
}

func generateClickCaptcha(generator click.Captcha) (string, string, []captchaPoint, error) {
	if generator == nil {
		return "", "", nil, errors.New("click captcha image source is unavailable")
	}
	data, err := generator.Generate()
	if err != nil {
		return "", "", nil, err
	}
	dots := data.GetData()
	if len(dots) == 0 {
		return "", "", nil, errors.New("click captcha returned no verification points")
	}
	indexes := make([]int, 0, len(dots))
	for index := range dots {
		indexes = append(indexes, index)
	}
	sort.Ints(indexes)
	points := make([]captchaPoint, 0, len(indexes))
	for _, index := range indexes {
		dot := dots[index]
		points = append(points, captchaPoint{
			X: dot.X, Y: dot.Y, Width: dot.Width, Height: dot.Height,
		})
	}
	masterImage, err := data.GetMasterImage().ToBase64()
	if err != nil {
		return "", "", nil, err
	}
	promptImage, err := data.GetThumbImage().ToBase64()
	if err != nil {
		return "", "", nil, err
	}
	return masterImage, promptImage, points, nil
}

func generateSlideCaptcha(generator slide.Captcha) (string, string, *slide.Block, error) {
	if generator == nil {
		return "", "", nil, errors.New("slide captcha image source is unavailable")
	}
	data, err := generator.Generate()
	if err != nil {
		return "", "", nil, err
	}
	block := data.GetData()
	if block == nil {
		return "", "", nil, errors.New("slide captcha returned no block")
	}
	masterImage, err := data.GetMasterImage().ToBase64()
	if err != nil {
		return "", "", nil, err
	}
	pieceImage, err := data.GetTileImage().ToBase64()
	if err != nil {
		return "", "", nil, err
	}
	return masterImage, pieceImage, block, nil
}

func generateRotateCaptcha(generator rotate.Captcha) (string, string, *rotate.Block, error) {
	if generator == nil {
		return "", "", nil, errors.New("rotate captcha image source is unavailable")
	}
	data, err := generator.Generate()
	if err != nil {
		return "", "", nil, err
	}
	block := data.GetData()
	if block == nil {
		return "", "", nil, errors.New("rotate captcha returned no block")
	}
	masterImage, err := data.GetMasterImage().ToBase64()
	if err != nil {
		return "", "", nil, err
	}
	pieceImage, err := data.GetThumbImage().ToBase64()
	if err != nil {
		return "", "", nil, err
	}
	return masterImage, pieceImage, block, nil
}

func makeClickGenerator(backgrounds []image.Image) (click.Captcha, error) {
	font, err := fzshengsksjw.GetFont()
	if err != nil {
		return nil, err
	}
	builder := click.NewBuilder(
		click.WithImageSize(option.Size{
			Width: clickCaptchaWidth, Height: clickCaptchaHeight,
		}),
		click.WithRangeLen(option.RangeVal{Min: 5, Max: 5}),
		click.WithRangeVerifyLen(option.RangeVal{Min: 2, Max: 2}),
		click.WithRangeThumbImageSize(option.Size{Width: 120, Height: 44}),
		click.WithRangeThumbBgDistort(option.DistortLevel2),
		click.WithRangeThumbBgCirclesNum(2),
		click.WithRangeThumbBgSlimLineNum(2),
	)
	builder.SetResources(
		click.WithChars(chars.GetAlphaChars()),
		click.WithFonts([]*truetype.Font{font}),
		click.WithBackgrounds(backgrounds),
	)
	return builder.Make(), nil
}

func makeSlideGenerator(backgrounds []image.Image) (slide.Captcha, error) {
	slideGraphsOnce.Do(func() {
		tileImages, err := tiles.GetTiles()
		if err != nil {
			slideGraphsErr = err
			return
		}
		slideGraphs = make([]*slide.GraphImage, 0, len(tileImages))
		for _, tile := range tileImages {
			slideGraphs = append(slideGraphs, &slide.GraphImage{
				OverlayImage: tile.OverlayImage,
				ShadowImage:  tile.ShadowImage,
				MaskImage:    tile.MaskImage,
			})
		}
	})
	if slideGraphsErr != nil {
		return nil, slideGraphsErr
	}
	builder := slide.NewBuilder(
		slide.WithImageSize(option.Size{
			Width: clickCaptchaWidth, Height: clickCaptchaHeight,
		}),
		slide.WithRangeGraphSize(option.RangeVal{Min: 52, Max: 60}),
	)
	builder.SetResources(
		slide.WithBackgrounds(backgrounds),
		slide.WithGraphImages(slideGraphs),
	)
	return builder.Make(), nil
}

func makeRotateGenerator(backgrounds []image.Image) rotate.Captcha {
	builder := rotate.NewBuilder(
		rotate.WithImageSquareSize(clickCaptchaHeight),
		rotate.WithRangeThumbImageSquareSize([]int{128, 136, 144}),
	)
	builder.SetResources(rotate.WithImages(backgrounds))
	return builder.Make()
}

func newCaptchaID() (string, error) {
	idBytes := make([]byte, 18)
	if _, err := rand.Read(idBytes); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(idBytes), nil
}

func validateClickCaptcha(expected []captchaPoint, answer string) bool {
	clicks, ok := parseClickAnswer(answer)
	if !ok || len(clicks) != len(expected) {
		return false
	}
	for index, target := range expected {
		if !click.Validate(
			clicks[index][0],
			clicks[index][1],
			target.X,
			target.Y,
			target.Width,
			target.Height,
			clickCaptchaPadding,
		) {
			return false
		}
	}
	return true
}

func validateSlideCaptcha(targetX, targetY int, answer string) bool {
	values, ok := parseMotionAnswer(answer, "slide:", 2)
	if !ok ||
		values[0] < 0 || values[0] >= clickCaptchaWidth ||
		values[1] < 0 || values[1] >= clickCaptchaHeight {
		return false
	}
	return slide.Validate(
		values[0], values[1], targetX, targetY, motionCaptchaPadding,
	)
}

func validateRotateCaptcha(targetAngle int, answer string) bool {
	values, ok := parseMotionAnswer(answer, "rotate:", 1)
	if !ok || values[0] < 0 || values[0] > 360 {
		return false
	}
	return rotate.Validate(values[0], targetAngle, motionCaptchaPadding)
}

func parseMotionAnswer(answer, prefix string, count int) ([]int, bool) {
	value := strings.TrimSpace(answer)
	if !strings.HasPrefix(value, prefix) {
		return nil, false
	}
	parts := strings.Split(strings.TrimPrefix(value, prefix), ",")
	if len(parts) != count {
		return nil, false
	}
	values := make([]int, 0, count)
	for _, part := range parts {
		parsed, err := strconv.Atoi(part)
		if err != nil {
			return nil, false
		}
		values = append(values, parsed)
	}
	return values, true
}

func parseClickAnswer(answer string) ([][2]int, bool) {
	value := strings.TrimSpace(answer)
	if !strings.HasPrefix(value, "click:") {
		return nil, false
	}
	parts := strings.Split(strings.TrimPrefix(value, "click:"), "|")
	clicks := make([][2]int, 0, len(parts))
	for _, part := range parts {
		coordinates := strings.Split(part, ",")
		if len(coordinates) != 2 {
			return nil, false
		}
		x, errX := strconv.Atoi(coordinates[0])
		y, errY := strconv.Atoi(coordinates[1])
		if errX != nil || errY != nil ||
			x < 0 || x >= clickCaptchaWidth ||
			y < 0 || y >= clickCaptchaHeight {
			return nil, false
		}
		clicks = append(clicks, [2]int{x, y})
	}
	return clicks, len(clicks) > 0
}
