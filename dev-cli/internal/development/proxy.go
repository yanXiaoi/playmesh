package development

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path"
	"strings"
	"time"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/webpath"
)

const (
	CredentialHeader           = "X-Playmesh-Development-Credential"
	developmentSessionLifetime = 12 * time.Hour
)

// 项目适配器与开发代理通过 Source 共用生命周期边界。
// 引擎适配器负责准备资源源；CLI 核心负责启动、消费引擎无关的 HTTP 映射并停止资源源。
// 代理无需知道映射来自哪种项目集成。
type Source interface {
	Start(context.Context) (Mapping, error)
	Stop(context.Context) error
}

// Mapping 描述游戏资源请求如何映射到已准备的 HTTP 源。
// 平台适配器可以提供路径或 Header 映射，无需在代理中增加平台分支。
type Mapping interface {
	SourceURI() *url.URL
	MapRequest(*url.URL) (*url.URL, error)
	RequestHeaders() http.Header
}

// ResponseMapping 允许适配器修正开发服务器的响应元数据。
// CLI 核心只调用该通用钩子，不读取适配器类型或引擎专用路径。
type ResponseMapping interface {
	MapResponse(*http.Response) error
}

// GameEntryMapping allows an adapter to choose the HTML path written only to
// the uploaded development main.json. The project manifest on disk is never
// changed. Requests for this path still pass through the ordinary Mapping.
type GameEntryMapping interface {
	DevelopmentGameEntry() string
}

type HTTPMapping struct {
	sourceURI *url.URL
	headers   http.Header
}

func NewHTTPMapping(
	sourceURI *url.URL,
	headers http.Header,
) (*HTTPMapping, error) {
	if err := ValidateUpstream(sourceURI); err != nil {
		return nil, err
	}
	copiedURI := *sourceURI
	copiedHeaders := make(http.Header, len(headers))
	for name, values := range headers {
		copiedHeaders[name] = append([]string(nil), values...)
	}
	return &HTTPMapping{
		sourceURI: &copiedURI,
		headers:   copiedHeaders,
	}, nil
}

func (mapping *HTTPMapping) SourceURI() *url.URL {
	copy := *mapping.sourceURI
	return &copy
}

func (mapping *HTTPMapping) MapRequest(
	requestURI *url.URL,
) (*url.URL, error) {
	if err := validateDevelopmentRequestPath(requestURI); err != nil {
		return nil, err
	}
	mapped := *mapping.sourceURI
	basePath := strings.TrimSuffix(mapped.Path, "/")
	requestPath := strings.TrimPrefix(requestURI.Path, "/")
	if requestPath == "" {
		mapped.Path = basePath + "/"
	} else {
		mapped.Path = basePath + "/" + requestPath
	}
	mapped.RawPath = ""
	mapped.RawQuery = requestURI.RawQuery
	mapped.Fragment = ""
	return &mapped, nil
}

func (mapping *HTTPMapping) RequestHeaders() http.Header {
	headers := make(http.Header, len(mapping.headers))
	for name, values := range mapping.headers {
		headers[name] = append([]string(nil), values...)
	}
	return headers
}

type fixedSource struct {
	baseURL *url.URL
}

func NewFixedSource(baseURL *url.URL) (Source, error) {
	if err := ValidateUpstream(baseURL); err != nil {
		return nil, err
	}
	copied := *baseURL
	return fixedSource{baseURL: &copied}, nil
}

func (source fixedSource) Start(
	ctx context.Context,
) (Mapping, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return NewHTTPMapping(source.baseURL, nil)
}

func (fixedSource) Stop(context.Context) error {
	return nil
}

type SessionRequest struct {
	ResourceBaseURL string `json:"resourceBaseUrl"`
	Credential      string `json:"credential"`
	ExpiresAt       int64  `json:"expiresAt"`
}

const RestartControlPath = "/.playmesh-development/restart"

type ProxyControls struct {
	Restart func(context.Context) error
}

type Proxy struct {
	server          *http.Server
	transport       *http.Transport
	resourceBaseURL *url.URL
	credential      string
	expiresAt       time.Time
}

func StartProxy(
	mapping Mapping,
	targetBaseURL string,
	controlOptions ...ProxyControls,
) (*Proxy, error) {
	if mapping == nil {
		return nil, errors.New("项目适配器未提供开发资源映射")
	}
	if len(controlOptions) > 1 {
		return nil, errors.New("开发资源代理只能配置一组控制处理器")
	}
	var controls ProxyControls
	if len(controlOptions) == 1 {
		controls = controlOptions[0]
	}
	upstream := mapping.SourceURI()
	if err := ValidateUpstream(upstream); err != nil {
		return nil, err
	}
	credentialBytes := make([]byte, 32)
	if _, err := rand.Read(credentialBytes); err != nil {
		return nil, err
	}
	credential := base64.RawURLEncoding.EncodeToString(credentialBytes)
	expiresAt := time.Now().Add(developmentSessionLifetime)
	listener, err := net.Listen("tcp4", "0.0.0.0:0")
	if err != nil {
		return nil, err
	}
	transport, err := pinnedDevelopmentTransport(upstream)
	if err != nil {
		_ = listener.Close()
		return nil, err
	}
	reverseProxy := &httputil.ReverseProxy{
		Transport: transport,
		Director: func(request *http.Request) {
			request.Host = request.URL.Host
			request.Header.Del(CredentialHeader)
			for name, values := range mapping.RequestHeaders() {
				request.Header.Del(name)
				for _, value := range values {
					request.Header.Add(name, value)
				}
			}
		},
		ErrorLog: log.New(os.Stderr, "[dev 资源代理] ", log.LstdFlags),
		ModifyResponse: func(response *http.Response) error {
			if responseMapping, ok := mapping.(ResponseMapping); ok {
				if err := responseMapping.MapResponse(response); err != nil {
					return fmt.Errorf("映射开发资源响应失败: %w", err)
				}
			}
			if response.StatusCode >= http.StatusBadRequest {
				fmt.Fprintf(
					os.Stderr,
					"[dev 资源代理] 上游返回 HTTP %d：%s %s\n",
					response.StatusCode,
					response.Request.Method,
					response.Request.URL.Path,
				)
			}
			return nil
		},
		ErrorHandler: func(
			response http.ResponseWriter,
			request *http.Request,
			proxyErr error,
		) {
			fmt.Fprintf(
				os.Stderr,
				"[dev 资源代理] 上游请求失败：%s %s: %v\n",
				request.Method,
				request.URL.Path,
				proxyErr,
			)
			http.Error(
				response,
				"Playmesh 开发资源上游暂不可用",
				http.StatusBadGateway,
			)
		},
	}
	handler := http.HandlerFunc(func(
		response http.ResponseWriter,
		request *http.Request,
	) {
		if time.Now().After(expiresAt) {
			http.Error(response, "开发资源凭据已过期", http.StatusUnauthorized)
			return
		}
		provided := request.Header.Get(CredentialHeader)
		if !sameSecret(provided, credential) {
			http.Error(response, "开发资源凭据无效", http.StatusUnauthorized)
			return
		}
		if request.URL.Path == RestartControlPath {
			if request.Method != http.MethodPost {
				response.Header().Set("Allow", http.MethodPost)
				http.Error(
					response,
					"开发刷新控制口只允许 POST",
					http.StatusMethodNotAllowed,
				)
				return
			}
			if controls.Restart == nil {
				http.Error(
					response,
					"当前开发会话未启用刷新控制",
					http.StatusNotFound,
				)
				return
			}
			response.Header().Set("Content-Type", "application/json; charset=utf-8")
			response.WriteHeader(http.StatusAccepted)
			_, _ = response.Write([]byte(`{"accepted":true}`))
			if flusher, ok := response.(http.Flusher); ok {
				flusher.Flush()
			}
			fmt.Fprintln(os.Stderr, "[dev 刷新] 已接收资源刷新信号，正在请求 App 重启当前开发游戏页面。")
			go func() {
				if err := controls.Restart(context.Background()); err != nil {
					fmt.Fprintf(
						os.Stderr,
						"[dev 刷新] App 重启开发游戏页面失败：%v\n",
						err,
					)
					return
				}
				fmt.Fprintln(
					os.Stderr,
					"[dev 刷新] App 开发游戏页面已重启；开发会话与资源代理保持运行。",
				)
			}()
			return
		}
		if request.Method != http.MethodGet &&
			request.Method != http.MethodHead {
			http.Error(
				response,
				"开发资源代理只允许 GET 和 HEAD",
				http.StatusMethodNotAllowed,
			)
			return
		}
		if err := validateDevelopmentRequestPath(request.URL); err != nil {
			fmt.Fprintf(
				os.Stderr,
				"[dev 资源代理] 请求路径被拒绝：%s %s: %v\n",
				request.Method,
				request.URL.RequestURI(),
				err,
			)
			http.Error(response, err.Error(), http.StatusForbidden)
			return
		}
		mappedURI, err := mapping.MapRequest(request.URL)
		if err != nil {
			fmt.Fprintf(
				os.Stderr,
				"[dev 资源代理] 适配器路径映射被拒绝：%s %s: %v\n",
				request.Method,
				request.URL.RequestURI(),
				err,
			)
			http.Error(response, err.Error(), http.StatusForbidden)
			return
		}
		if err := validateMappedDevelopmentRequest(upstream, mappedURI); err != nil {
			fmt.Fprintf(
				os.Stderr,
				"[dev 资源代理] 映射目标被拒绝：%s %s -> %s: %v\n",
				request.Method,
				request.URL.RequestURI(),
				mappedURI,
				err,
			)
			http.Error(response, err.Error(), http.StatusForbidden)
			return
		}
		proxied := request.Clone(request.Context())
		proxied.URL = mappedURI
		proxied.RequestURI = ""
		reverseProxy.ServeHTTP(response, proxied)
	})
	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       90 * time.Second,
	}
	port := listener.Addr().(*net.TCPAddr).Port
	host := advertisedDevelopmentHost(targetBaseURL)
	resourceBaseURL := &url.URL{
		Scheme: "http",
		Host:   net.JoinHostPort(host, fmt.Sprintf("%d", port)),
	}
	proxy := &Proxy{
		server:          server,
		transport:       transport,
		resourceBaseURL: resourceBaseURL,
		credential:      credential,
		expiresAt:       expiresAt,
	}
	go func() {
		_ = server.Serve(listener)
	}()
	return proxy, nil
}

func validateMappedDevelopmentRequest(
	sourceURI *url.URL,
	mappedURI *url.URL,
) error {
	if mappedURI == nil ||
		mappedURI.Scheme != sourceURI.Scheme ||
		!strings.EqualFold(mappedURI.Host, sourceURI.Host) ||
		mappedURI.User != nil ||
		mappedURI.Fragment != "" {
		return errors.New("项目适配器将开发资源映射到了来源之外")
	}
	return nil
}

func pinnedDevelopmentTransport(
	upstream *url.URL,
) (*http.Transport, error) {
	host := upstream.Hostname()
	port := upstream.Port()
	if port == "" {
		if upstream.Scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	}
	var pinnedIP net.IP
	if parsed := net.ParseIP(host); parsed != nil {
		pinnedIP = parsed
	} else {
		lookupContext, cancel := context.WithTimeout(
			context.Background(),
			5*time.Second,
		)
		defer cancel()
		addresses, err := net.DefaultResolver.LookupIPAddr(
			lookupContext,
			host,
		)
		if err != nil || len(addresses) == 0 {
			return nil, fmt.Errorf(
				"无法解析开发服务器主机 %s",
				host,
			)
		}
		pinnedIP = addresses[0].IP
	}
	pinnedAddress := net.JoinHostPort(pinnedIP.String(), port)
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	transport.DialContext = func(
		ctx context.Context,
		network, address string,
	) (net.Conn, error) {
		return dialer.DialContext(ctx, "tcp", pinnedAddress)
	}
	return transport, nil
}

func (proxy *Proxy) Request() SessionRequest {
	return SessionRequest{
		ResourceBaseURL: proxy.resourceBaseURL.String(),
		Credential:      proxy.credential,
		ExpiresAt:       proxy.expiresAt.UnixMilli(),
	}
}

func (proxy *Proxy) Close() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err := proxy.server.Shutdown(ctx)
	proxy.transport.CloseIdleConnections()
	return err
}

func ValidateUpstream(upstream *url.URL) error {
	if upstream == nil ||
		(upstream.Scheme != "http" && upstream.Scheme != "https") ||
		upstream.Host == "" {
		return errors.New("项目适配器未提供有效的 HTTP 开发服务器地址")
	}
	if upstream.User != nil ||
		upstream.Fragment != "" ||
		upstream.RawQuery != "" {
		return errors.New("开发服务器地址不能包含凭据、查询参数或 Fragment")
	}
	return nil
}

func validateDevelopmentRequestPath(requestURL *url.URL) error {
	if requestURL == nil {
		return errors.New("开发资源路径无效")
	}
	decoded, err := url.PathUnescape(requestURL.EscapedPath())
	if err != nil || strings.Contains(decoded, "\\") {
		return errors.New("开发资源路径无效")
	}
	if decoded == "" {
		decoded = "/"
	}
	if !strings.HasPrefix(decoded, "/") || strings.HasPrefix(decoded, "//") {
		return errors.New("开发资源路径无效")
	}
	relative := strings.TrimPrefix(decoded, "/")
	segments := strings.Split(relative, "/")
	for index, segment := range segments {
		if segment == "" && index == len(segments)-1 {
			// 目录式 HTTP 路由的末尾斜杠不代表额外路径层级；
			// 中间空段仍按路径穿越拒绝。
			continue
		}
		if relative != "" &&
			(segment == "" || segment == "." || segment == "..") {
			return errors.New("开发资源路径不允许路径穿越")
		}
	}
	cleaned := path.Clean("/" + decoded)
	first := strings.TrimPrefix(cleaned, "/")
	if slash := strings.IndexByte(first, '/'); slash >= 0 {
		first = first[:slash]
	}
	if webpath.IsReservedWebRootSegment(first) {
		return errors.New("开发资源路径属于 Playmesh 平台保留命名空间")
	}
	return nil
}

func sameSecret(first, second string) bool {
	if len(first) != len(second) || len(first) == 0 {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(first), []byte(second)) == 1
}

func advertisedDevelopmentHost(targetBaseURL string) string {
	parsed, err := url.Parse(targetBaseURL)
	if err == nil {
		host := parsed.Hostname()
		if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
			return "127.0.0.1"
		}
		port := parsed.Port()
		if port == "" {
			if parsed.Scheme == "https" {
				port = "443"
			} else {
				port = "80"
			}
		}
		if host != "" {
			connection, dialErr := net.DialTimeout(
				"udp4",
				net.JoinHostPort(host, port),
				time.Second,
			)
			if dialErr == nil {
				localHost, _, splitErr := net.SplitHostPort(
					connection.LocalAddr().String(),
				)
				_ = connection.Close()
				if splitErr == nil {
					if ip := net.ParseIP(localHost); ip != nil &&
						ip.To4() != nil && !ip.IsUnspecified() {
						return ip.String()
					}
				}
			}
		}
	}
	interfaces, _ := net.Interfaces()
	for _, networkInterface := range interfaces {
		if networkInterface.Flags&net.FlagUp == 0 ||
			networkInterface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, _ := networkInterface.Addrs()
		for _, address := range addresses {
			var ip net.IP
			switch value := address.(type) {
			case *net.IPNet:
				ip = value.IP
			case *net.IPAddr:
				ip = value.IP
			}
			if ip != nil && ip.To4() != nil && !ip.IsLoopback() {
				return ip.String()
			}
		}
	}
	return "127.0.0.1"
}
