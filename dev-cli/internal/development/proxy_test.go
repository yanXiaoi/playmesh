package development

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/testutil"
)

func writeTestFile(t *testing.T, path, value string) {
	t.Helper()
	testutil.WriteFile(t, path, value)
}

type fakeThirdPartyDevelopmentSource struct {
	mapping Mapping
	started atomic.Bool
	stopped atomic.Bool
}

type fakeResponseMapping struct {
	Mapping
}

func (mapping *fakeResponseMapping) MapResponse(
	response *http.Response,
) error {
	response.Header.Set("Content-Type", "application/javascript")
	response.Header.Set("X-Test-Response-Mapped", "true")
	return nil
}

func (source *fakeThirdPartyDevelopmentSource) Start(
	ctx context.Context,
) (Mapping, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if source.stopped.Load() {
		return nil, errors.New("third-party source stopped")
	}
	source.started.Store(true)
	return source.mapping, nil
}

func (source *fakeThirdPartyDevelopmentSource) Stop(
	context.Context,
) error {
	source.stopped.Store(true)
	return nil
}

func TestDevelopmentProxyUsesGenericThirdPartyMapping(t *testing.T) {
	var receivedPath string
	var receivedQuery string
	var receivedEngineHeader string
	var receivedProxyCredential string
	upstream := httptest.NewServer(http.HandlerFunc(func(
		response http.ResponseWriter,
		request *http.Request,
	) {
		receivedPath = request.URL.Path
		receivedQuery = request.URL.RawQuery
		receivedEngineHeader = request.Header.Get("X-Engine-Preview")
		receivedProxyCredential = request.Header.Get(
			CredentialHeader,
		)
		response.WriteHeader(http.StatusOK)
		_, _ = response.Write([]byte("THIRD_PARTY_RESOURCE"))
	}))
	defer upstream.Close()

	sourceURI, err := url.Parse(upstream.URL + "/godot-preview/")
	if err != nil {
		t.Fatal(err)
	}
	baseMapping, err := NewHTTPMapping(
		sourceURI,
		http.Header{"X-Engine-Preview": []string{"godot-like"}},
	)
	if err != nil {
		t.Fatal(err)
	}
	mapping := &fakeResponseMapping{Mapping: baseMapping}
	source := &fakeThirdPartyDevelopmentSource{mapping: mapping}
	activeMapping, err := source.Start(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	proxy, err := StartProxy(
		activeMapping,
		upstream.URL,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()

	request, err := http.NewRequest(
		http.MethodGet,
		proxy.resourceBaseURL.String()+"/assets/main.js?v=7",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(CredentialHeader, proxy.credential)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusOK ||
		string(body) != "THIRD_PARTY_RESOURCE" {
		t.Fatalf(
			"generic mapped resource failed: code=%d body=%q",
			response.StatusCode,
			body,
		)
	}
	if response.Header.Get("Content-Type") != "application/javascript" ||
		response.Header.Get("X-Test-Response-Mapped") != "true" {
		t.Fatalf(
			"generic response mapping was not applied: content-type=%q mapped=%q",
			response.Header.Get("Content-Type"),
			response.Header.Get("X-Test-Response-Mapped"),
		)
	}
	if receivedPath != "/godot-preview/assets/main.js" ||
		receivedQuery != "v=7" ||
		receivedEngineHeader != "godot-like" ||
		receivedProxyCredential != "" {
		t.Fatalf(
			"unexpected mapped request: path=%q query=%q engine=%q credential=%q",
			receivedPath,
			receivedQuery,
			receivedEngineHeader,
			receivedProxyCredential,
		)
	}

	appRequest, err := http.NewRequest(
		http.MethodGet,
		proxy.resourceBaseURL.String()+"/app/index.html",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	appRequest.Header.Set(CredentialHeader, proxy.credential)
	appResponse, err := http.DefaultClient.Do(appRequest)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, appResponse.Body)
	appResponse.Body.Close()
	if appResponse.StatusCode != http.StatusOK ||
		receivedPath != "/godot-preview/app/index.html" {
		t.Fatalf(
			"用户 /app/** 路径未透传: code=%d path=%q",
			appResponse.StatusCode,
			receivedPath,
		)
	}

	for _, reservedPath := range []string{
		"/playmesh/sdk/v1/playmesh-main.js",
		"/bucket/save/data.json",
	} {
		reservedRequest, requestErr := http.NewRequest(
			http.MethodGet,
			proxy.resourceBaseURL.String()+reservedPath,
			nil,
		)
		if requestErr != nil {
			t.Fatal(requestErr)
		}
		reservedRequest.Header.Set(
			CredentialHeader,
			proxy.credential,
		)
		reservedResponse, requestErr := http.DefaultClient.Do(reservedRequest)
		if requestErr != nil {
			t.Fatal(requestErr)
		}
		_, _ = io.Copy(io.Discard, reservedResponse.Body)
		reservedResponse.Body.Close()
		if reservedResponse.StatusCode != http.StatusForbidden {
			t.Fatalf(
				"reserved route %s reached third-party source: %d",
				reservedPath,
				reservedResponse.StatusCode,
			)
		}
	}

	if !source.started.Load() {
		t.Fatal("third-party source was not started through common lifecycle")
	}
	if err := source.Stop(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !source.stopped.Load() {
		t.Fatal("third-party source was not stopped through common lifecycle")
	}
	if _, err := source.Start(context.Background()); err == nil {
		t.Fatal("stopped third-party source unexpectedly restarted")
	}
}

func TestDevelopmentProxyHandlesAuthenticatedRestartControl(t *testing.T) {
	var upstreamRequests atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(
		response http.ResponseWriter,
		request *http.Request,
	) {
		upstreamRequests.Add(1)
		response.WriteHeader(http.StatusNotFound)
	}))
	defer upstream.Close()
	sourceURI, err := url.Parse(upstream.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	mapping, err := NewHTTPMapping(sourceURI, nil)
	if err != nil {
		t.Fatal(err)
	}
	restarted := make(chan struct{}, 1)
	proxy, err := StartProxy(
		mapping,
		upstream.URL,
		ProxyControls{
			Restart: func(context.Context) error {
				restarted <- struct{}{}
				return nil
			},
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()

	request, err := http.NewRequest(
		http.MethodPost,
		proxy.resourceBaseURL.String()+RestartControlPath,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set(CredentialHeader, proxy.credential)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusAccepted {
		t.Fatalf("restart control returned %d", response.StatusCode)
	}
	select {
	case <-restarted:
	case <-time.After(3 * time.Second):
		t.Fatal("restart control handler was not called")
	}
	if upstreamRequests.Load() != 0 {
		t.Fatal("restart control request leaked to development upstream")
	}

	methodRequest, err := http.NewRequest(
		http.MethodGet,
		proxy.resourceBaseURL.String()+RestartControlPath,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	methodRequest.Header.Set(CredentialHeader, proxy.credential)
	methodResponse, err := http.DefaultClient.Do(methodRequest)
	if err != nil {
		t.Fatal(err)
	}
	methodResponse.Body.Close()
	if methodResponse.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("restart GET returned %d", methodResponse.StatusCode)
	}
}

func TestDevelopmentRequestPathAllowsTrailingSlashOnly(t *testing.T) {
	for _, rawURL := range []string{
		"/engine_external/?url=external:emscripten/spine/3.8/spine.wasm",
		"/socket.io/?EIO=3&transport=polling",
		"/assets/",
	} {
		requestURL, err := url.Parse(rawURL)
		if err != nil {
			t.Fatal(err)
		}
		if err := validateDevelopmentRequestPath(requestURL); err != nil {
			t.Fatalf("合法目录式开发路径 %q 被拒绝: %v", rawURL, err)
		}
	}
	for _, rawURL := range []string{
		"/assets//main.js",
		"/assets/./main.js",
		"/assets/../secret.js",
	} {
		requestURL, err := url.Parse(rawURL)
		if err != nil {
			t.Fatal(err)
		}
		if err := validateDevelopmentRequestPath(requestURL); err == nil {
			t.Fatalf("非法开发路径 %q 未被拒绝", rawURL)
		}
	}
}

func TestStaticDevelopmentSourceStopClosesListener(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "index.html"), "STATIC_RESOURCE")
	source, err := NewStaticSource(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	mapping, err := source.Start(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.Get(mapping.SourceURI().ResolveReference(
		&url.URL{Path: "/index.html"},
	).String())
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("static development source returned %d", response.StatusCode)
	}

	stopContext, cancel := context.WithTimeout(
		context.Background(),
		5*time.Second,
	)
	defer cancel()
	if err := source.Stop(stopContext); err != nil {
		t.Fatal(err)
	}
	client := &http.Client{
		Timeout: time.Second,
		Transport: &http.Transport{
			DisableKeepAlives: true,
		},
	}
	if response, requestErr := client.Get(
		mapping.SourceURI().ResolveReference(
			&url.URL{Path: "/index.html"},
		).String(),
	); requestErr == nil {
		response.Body.Close()
		t.Fatal("stopped static source still accepted a new connection")
	}
	if _, err := source.Start(context.Background()); err == nil {
		t.Fatal("stopped static source unexpectedly restarted")
	}
}
