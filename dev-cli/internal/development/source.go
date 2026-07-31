package development

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/webpath"
)

type httpSource struct {
	handler http.Handler
	lock    sync.Mutex
	server  *http.Server
	baseURL *url.URL
	stopped bool
}

func NewStaticSource(
	webRoot string,
	handler http.Handler,
) (Source, error) {
	if handler == nil {
		handler = safeDevelopmentFileHandler(webRoot)
	}
	return &httpSource{handler: handler}, nil
}

func (source *httpSource) Start(
	ctx context.Context,
) (Mapping, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	source.lock.Lock()
	defer source.lock.Unlock()
	if source.stopped {
		return nil, errors.New("开发资源源已经停止")
	}
	if source.server != nil {
		return NewHTTPMapping(source.baseURL, nil)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	server := &http.Server{
		Handler:           source.handler,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       90 * time.Second,
	}
	baseURL := &url.URL{
		Scheme: "http",
		Host:   listener.Addr().String(),
	}
	mapping, err := NewHTTPMapping(baseURL, nil)
	if err != nil {
		_ = listener.Close()
		return nil, err
	}
	source.server = server
	source.baseURL = baseURL
	go func() {
		_ = server.Serve(listener)
	}()
	return mapping, nil
}

func (source *httpSource) Stop(ctx context.Context) error {
	source.lock.Lock()
	if source.stopped {
		source.lock.Unlock()
		return nil
	}
	source.stopped = true
	server := source.server
	source.lock.Unlock()
	if server == nil {
		return nil
	}
	return server.Shutdown(ctx)
}

func safeDevelopmentFileHandler(webRoot string) http.Handler {
	root := filepath.Clean(webRoot)
	return http.HandlerFunc(func(
		response http.ResponseWriter,
		request *http.Request,
	) {
		decoded, err := url.PathUnescape(request.URL.EscapedPath())
		if err != nil || strings.Contains(decoded, "\\") {
			http.NotFound(response, request)
			return
		}
		if !strings.HasPrefix(decoded, "/") ||
			strings.HasPrefix(decoded, "//") {
			http.NotFound(response, request)
			return
		}
		relativeURL := strings.TrimPrefix(decoded, "/")
		segments := strings.Split(relativeURL, "/")
		for _, segment := range segments {
			if relativeURL != "" &&
				(segment == "" || segment == "." || segment == "..") {
				http.NotFound(response, request)
				return
			}
		}
		relative := filepath.FromSlash(relativeURL)
		target := filepath.Join(root, relative)
		if err := webpath.RejectSymlinkPath(root, target); err != nil {
			http.NotFound(response, request)
			return
		}
		info, err := os.Stat(target)
		if err != nil {
			http.NotFound(response, request)
			return
		}
		if info.IsDir() {
			index := filepath.Join(target, "index.html")
			if err := webpath.RejectSymlinkPath(root, index); err != nil {
				http.NotFound(response, request)
				return
			}
			indexInfo, indexErr := os.Stat(index)
			if indexErr != nil || !indexInfo.Mode().IsRegular() {
				http.NotFound(response, request)
				return
			}
			target = index
			info = indexInfo
		} else if !info.Mode().IsRegular() {
			http.NotFound(response, request)
			return
		}
		file, err := os.Open(target)
		if err != nil {
			http.NotFound(response, request)
			return
		}
		defer file.Close()
		http.ServeContent(
			response,
			request,
			filepath.Base(target),
			info.ModTime(),
			file,
		)
	})
}

type rebuildingDevelopmentHandler struct {
	sourceRoot  string
	delegate    http.Handler
	build       func(context.Context) error
	lock        sync.Mutex
	fingerprint uint64
}

func NewRebuildingHandler(
	sourceRoot string,
	webRoot string,
	build func(context.Context) error,
) (*rebuildingDevelopmentHandler, error) {
	fingerprint, err := sourceFingerprint(sourceRoot)
	if err != nil {
		return nil, err
	}
	return &rebuildingDevelopmentHandler{
		sourceRoot:  sourceRoot,
		delegate:    safeDevelopmentFileHandler(webRoot),
		build:       build,
		fingerprint: fingerprint,
	}, nil
}

func (handler *rebuildingDevelopmentHandler) ServeHTTP(
	response http.ResponseWriter,
	request *http.Request,
) {
	handler.lock.Lock()
	fingerprint, err := sourceFingerprint(handler.sourceRoot)
	if err == nil && fingerprint != handler.fingerprint {
		err = handler.build(request.Context())
		if err == nil {
			handler.fingerprint = fingerprint
		}
	}
	handler.lock.Unlock()
	if err != nil {
		http.Error(
			response,
			fmt.Sprintf("TypeScript 开发构建失败: %v", err),
			http.StatusInternalServerError,
		)
		return
	}
	handler.delegate.ServeHTTP(response, request)
}

func sourceFingerprint(root string) (uint64, error) {
	hasher := fnv.New64a()
	err := filepath.WalkDir(
		root,
		func(path string, entry fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if entry.Type()&os.ModeSymlink != 0 {
				return fmt.Errorf("源码目录不允许符号链接: %s", path)
			}
			if entry.IsDir() {
				return nil
			}
			if !entry.Type().IsRegular() {
				return nil
			}
			info, err := entry.Info()
			if err != nil {
				return err
			}
			relative, err := filepath.Rel(root, path)
			if err != nil {
				return err
			}
			_, _ = fmt.Fprintf(
				hasher,
				"%s\x00%d\x00%d\x00",
				filepath.ToSlash(relative),
				info.Size(),
				info.ModTime().UnixNano(),
			)
			return nil
		},
	)
	if errors.Is(err, os.ErrNotExist) {
		return 0, errors.New("当前项目缺少源码目录")
	}
	if err != nil {
		return 0, err
	}
	return hasher.Sum64(), nil
}
