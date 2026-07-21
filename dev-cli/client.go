package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type apiClient struct {
	target targetConfig
	http   *http.Client
}

func newAPIClient(target targetConfig) *apiClient {
	return &apiClient{
		target: target,
		http:   &http.Client{Timeout: 30 * time.Second},
	}
}

func (client *apiClient) endpoint(path string) string {
	return strings.TrimRight(client.target.BaseURL, "/") + path
}

func (client *apiClient) request(
	ctx context.Context,
	method string,
	path string,
	body io.Reader,
	contentType string,
) (*http.Response, error) {
	request, err := http.NewRequestWithContext(ctx, method, client.endpoint(path), body)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+client.target.Token)
	request.Header.Set("User-Agent", "playmesh-cli/"+cliVersion)
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	return client.http.Do(request)
}

func (client *apiClient) json(
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
	response, err := client.request(ctx, method, path, body, "application/json")
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return decodeAPIError(response)
	}
	if result == nil {
		_, err = io.Copy(io.Discard, response.Body)
		return err
	}
	return json.NewDecoder(response.Body).Decode(result)
}

func decodeAPIError(response *http.Response) error {
	data, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	var payload struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(data, &payload) == nil && payload.Error.Message != "" {
		return fmt.Errorf("Developer API %s: %s", payload.Error.Code, payload.Error.Message)
	}
	return fmt.Errorf("Developer API 返回 HTTP %d: %s", response.StatusCode, strings.TrimSpace(string(data)))
}

func escapedProjectPath(projectID, suffix string) string {
	return "/dev/api/projects/" + url.PathEscape(projectID) + suffix
}
