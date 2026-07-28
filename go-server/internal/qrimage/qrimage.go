package qrimage

import (
	"bytes"

	qrcode "github.com/yeqown/go-qrcode/v2"
	"github.com/yeqown/go-qrcode/writer/standard"
)

type bufferWriteCloser struct {
	*bytes.Buffer
}

func (bufferWriteCloser) Close() error { return nil }

func PNG(payload string) ([]byte, error) {
	code, err := qrcode.New(payload)
	if err != nil {
		return nil, err
	}
	var output bytes.Buffer
	writer := standard.NewWithWriter(
		bufferWriteCloser{Buffer: &output},
		standard.WithBuiltinImageEncoder(standard.PNG_FORMAT),
		standard.WithQRWidth(7),
		standard.WithBorderWidth(18),
		standard.WithBgColorRGBHex("#ffffff"),
		standard.WithFgColorRGBHex("#071018"),
	)
	if err := code.Save(writer); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}
