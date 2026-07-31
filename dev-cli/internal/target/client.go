package target

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type Client struct {
	target     Config
	http       *http.Client
	streamHTTP *http.Client
	userAgent  string
}

type APIError struct {
	StatusCode int
	Code       string
	Message    string
	Validation *ValidationReport
}

type ValidationReport struct {
	ErrorCount   int                    `json:"errorCount"`
	WarningCount int                    `json:"warningCount"`
	Diagnostics  []ValidationDiagnostic `json:"diagnostics"`
}

type ValidationDiagnostic struct {
	Code     string `json:"code"`
	Severity string `json:"severity"`
	Message  string `json:"message"`
	Path     string `json:"path"`
	Line     *int   `json:"line"`
	Column   *int   `json:"column"`
	Hint     string `json:"hint"`
}

func (err *APIError) Error() string {
	var message string
	if err.Code != "" {
		message = fmt.Sprintf("Developer API %s: %s", err.Code, err.Message)
	} else {
		message = fmt.Sprintf(
			"Developer API 返回 HTTP %d: %s",
			err.StatusCode,
			err.Message,
		)
	}
	if err.Validation == nil || len(err.Validation.Diagnostics) == 0 {
		return message
	}
	var builder strings.Builder
	builder.WriteString(message)
	fmt.Fprintf(
		&builder,
		"\n项目校验明细（%d 个错误，%d 个警告）：",
		err.Validation.ErrorCount,
		err.Validation.WarningCount,
	)
	for _, diagnostic := range err.Validation.Diagnostics {
		builder.WriteString("\n- ")
		if diagnostic.Code != "" {
			fmt.Fprintf(&builder, "[%s] ", diagnostic.Code)
		}
		if location := diagnosticLocation(diagnostic); location != "" {
			builder.WriteString(location)
			builder.WriteString(": ")
		}
		builder.WriteString(diagnostic.Message)
		if diagnostic.Hint != "" {
			builder.WriteString("；建议：")
			builder.WriteString(diagnostic.Hint)
		}
	}
	return builder.String()
}

func diagnosticLocation(diagnostic ValidationDiagnostic) string {
	location := diagnostic.Path
	if diagnostic.Line != nil {
		location += fmt.Sprintf(":%d", *diagnostic.Line)
		if diagnostic.Column != nil {
			location += fmt.Sprintf(":%d", *diagnostic.Column)
		}
	}
	return location
}

func IsAPIErrorCode(err error, code string) bool {
	var apiError *APIError
	return errors.As(err, &apiError) && apiError.Code == code
}

func NewClient(target Config, userAgent string) *Client {
	return &Client{
		target:     target,
		http:       &http.Client{Timeout: 30 * time.Second},
		streamHTTP: &http.Client{},
		userAgent:  userAgent,
	}
}

func (client *Client) Endpoint(path string) string {
	return strings.TrimRight(client.target.BaseURL, "/") + path
}

func (client *Client) BaseURL() string {
	return client.target.BaseURL
}

func (client *Client) Request(
	ctx context.Context,
	method string,
	path string,
	body io.Reader,
	contentType string,
) (*http.Response, error) {
	return client.requestWith(
		ctx,
		client.http,
		method,
		path,
		body,
		contentType,
	)
}

// StreamRequest performs a request whose response body is expected to stay
// open for the lifetime of ctx. It intentionally has no http.Client total
// timeout; connection termination is controlled by the caller's context.
func (client *Client) StreamRequest(
	ctx context.Context,
	method string,
	path string,
	body io.Reader,
	contentType string,
) (*http.Response, error) {
	return client.requestWith(
		ctx,
		client.streamHTTP,
		method,
		path,
		body,
		contentType,
	)
}

func (client *Client) requestWith(
	ctx context.Context,
	httpClient *http.Client,
	method string,
	path string,
	body io.Reader,
	contentType string,
) (*http.Response, error) {
	request, err := http.NewRequestWithContext(ctx, method, client.Endpoint(path), body)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+client.target.Token)
	if client.userAgent != "" {
		request.Header.Set("User-Agent", client.userAgent)
	}
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	return httpClient.Do(request)
}

func (client *Client) JSON(
	ctx context.Context,
	method string,
	path string,
	requestBody any,
	result any,
) error {
	var body io.Reader
	if requestBody != nil {
		encoded, err := json.Marshal(requestBody)
		if err != nil {
			return err
		}
		body = bytes.NewReader(encoded)
	}
	response, err := client.Request(ctx, method, path, body, "application/json")
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return DecodeAPIError(response)
	}
	if result == nil {
		_, err = io.Copy(io.Discard, response.Body)
		return err
	}
	return json.NewDecoder(response.Body).Decode(result)
}

func DecodeAPIError(response *http.Response) error {
	data, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	var payload struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
		Validation *ValidationReport `json:"validation"`
	}
	if json.Unmarshal(data, &payload) == nil && payload.Error.Message != "" {
		return &APIError{
			StatusCode: response.StatusCode,
			Code:       payload.Error.Code,
			Message:    payload.Error.Message,
			Validation: payload.Validation,
		}
	}
	return &APIError{
		StatusCode: response.StatusCode,
		Message:    strings.TrimSpace(string(data)),
	}
}

func ProjectPath(projectID, suffix string) string {
	return "/dev/api/projects/" + url.PathEscape(projectID) + suffix
}
