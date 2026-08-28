package cli

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/buildinfo"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/contract"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/development"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/packaging"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/project"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/sdk"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/target"
)

type statusResponse struct {
	Enabled        bool     `json:"enabled"`
	BaseURLs       []string `json:"baseUrls"`
	GameSDKVersion string   `json:"gameSdkVersion"`
	AppSDKVersion  string   `json:"appSdkVersion"`
}

func commandTo(ctx context.Context, args []string) error {
	var raw string
	if len(args) == 1 {
		raw = args[0]
	} else if len(args) == 0 {
		fmt.Print("Developer workspace URL: ")
		line, err := bufio.NewReader(os.Stdin).ReadString('\n')
		if err != nil && !errors.Is(err, io.EOF) {
			return err
		}
		raw = strings.TrimSpace(line)
	} else {
		return errors.New("用法：playmesh-cli to <workspace-url>")
	}
	targetConfig, err := target.ParseWorkspaceURL(raw)
	if err != nil {
		return err
	}
	client := newTargetClient(targetConfig)
	var status statusResponse
	if err := client.JSON(ctx, "GET", "/dev/api/status", nil, &status); err != nil {
		return err
	}
	if !status.Enabled {
		return errors.New("目标 App 未开启开发者模式")
	}
	if err := targetStore.Save(targetConfig); err != nil {
		return err
	}
	fmt.Printf("已连接 %s（Game SDK %s，App SDK %s）\n", targetConfig.BaseURL, status.GameSDKVersion, status.AppSDKVersion)
	return nil
}

func commandGet(ctx context.Context, args []string) error {
	if len(args) != 1 || strings.TrimSpace(args[0]) == "" {
		return errors.New("用法：playmesh-cli get <project-id>")
	}
	projectID := strings.TrimSpace(args[0])
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	if err := project.EnsureNotInitialized(root); err != nil {
		return err
	}
	if err := ensureCreateDestination(root); err != nil {
		return err
	}
	return initializeDownloadedJavaScriptProject(ctx, root, projectID)
}

func initializeDownloadedJavaScriptProject(
	ctx context.Context,
	root, projectID string,
) error {
	if err := project.EnsureNotInitialized(root); err != nil {
		return err
	}
	if err := ensureCreateDestination(root); err != nil {
		return err
	}
	adapter, _ := adapterRegistry.Lookup("javascript")
	config, err := adapter.Configuration(root)
	if err != nil {
		return err
	}
	projectContext, err := project.FromConfig(
		filepath.Clean(root),
		filepath.Join(root, project.ConfigName),
		&config,
	)
	if err != nil {
		return err
	}
	targetConfig, err := targetStore.Load()
	if err != nil {
		return err
	}
	if err := downloadProjectTo(
		ctx,
		newTargetClient(targetConfig),
		projectID,
		projectContext.PackageRoot,
		projectContext.SDKRoot,
	); err != nil {
		return err
	}
	layout, _, err := packaging.LoadManifestLayout(projectContext.PackageRoot, false)
	if err != nil {
		return err
	}
	config.Integration.Entry = layout.GameEntry
	projectContext.Config = &config
	if err := project.WriteConfig(root, config); err != nil {
		return err
	}
	if err := adapter.Finalize(projectContext); err != nil {
		return err
	}
	return nil
}

func downloadProjectTo(
	ctx context.Context,
	client *target.Client,
	projectID, packageRoot, sdkRoot string,
) error {
	response, err := client.Request(ctx, "GET", target.ProjectPath(projectID, "/package"), nil, "")
	if err != nil {
		return err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		defer response.Body.Close()
		return target.DecodeAPIError(response)
	}
	packageBytes, err := io.ReadAll(io.LimitReader(response.Body, 64<<20+1))
	response.Body.Close()
	if err != nil {
		return err
	}
	if len(packageBytes) > 64<<20 {
		return errors.New("目标项目包超过 64 MiB")
	}
	if err := os.MkdirAll(packageRoot, 0o755); err != nil {
		return err
	}
	if err := packaging.Extract(packageBytes, packageRoot); err != nil {
		return err
	}
	bundle, err := sdk.Fetch(ctx, client)
	if err != nil {
		return err
	}
	versions, err := sdk.InstallAt(sdkRoot, bundle)
	if err != nil {
		return err
	}
	actualID, err := sdk.UpdateManifestVersions(packageRoot, versions)
	if err != nil {
		return err
	}
	if actualID != projectID {
		return fmt.Errorf("项目包 ID %s 与请求 ID %s 不一致", actualID, projectID)
	}
	fmt.Printf("已拉取 %s（Game SDK %s，App SDK %s）\n", actualID, versions.Game, versions.App)
	return nil
}

func commandUpdate(ctx context.Context) error {
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	targetConfig, err := targetStore.Load()
	if err != nil {
		return err
	}
	bundle, err := sdk.Fetch(ctx, newTargetClient(targetConfig))
	if err != nil {
		return err
	}
	if _, statErr := os.Stat(
		filepath.Join(root, project.ConfigName),
	); errors.Is(statErr, os.ErrNotExist) {
		versions, installErr := sdk.Install(root, bundle)
		if installErr != nil {
			return installErr
		}
		fmt.Printf(
			"当前目录没有 playmesh-cli.json；仅更新原生 SDK：Game SDK %s，App SDK %s\n",
			versions.Game,
			versions.App,
		)
		return nil
	} else if statErr != nil {
		return statErr
	}
	projectContext, err := project.Resolve(root)
	if err != nil {
		return err
	}
	versions, err := sdk.InstallAt(projectContext.SDKRoot, bundle)
	if err != nil {
		return err
	}
	projectID, err := sdk.UpdateManifestVersions(projectContext.PackageRoot, versions)
	if err != nil {
		return err
	}
	adapter, err := adapterForProject(projectContext)
	if err != nil {
		return err
	}
	if err := adapter.Update(projectContext); err != nil {
		return err
	}
	fmt.Printf("已通过 %s 适配器更新项目集成。\n", adapter.ID())
	fmt.Printf("已更新 %s：Game SDK %s，App SDK %s\n", projectID, versions.Game, versions.App)
	return nil
}

func prepareTargetProject(
	_ context.Context,
	projectContext project.Context,
) (string, *target.Client, error) {
	uploadManifest, _, err := packaging.LoadUploadManifest(
		projectContext.PackageRoot,
	)
	if err != nil {
		return "", nil, err
	}
	targetConfig, err := targetStore.Load()
	if err != nil {
		return "", nil, err
	}
	client := newTargetClient(targetConfig)
	return uploadManifest.ID, client, nil
}

type importedProject struct {
	ID      string
	Version string
}

func importProjectPackage(
	ctx context.Context,
	client *target.Client,
	packageBytes []byte,
	reportSuccess bool,
) (importedProject, error) {
	response, err := client.Request(
		ctx,
		"POST",
		"/dev/api/packages/import",
		bytes.NewReader(packageBytes),
		"application/zip",
	)
	if err != nil {
		return importedProject{}, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return importedProject{}, target.DecodeAPIError(response)
	}
	var result struct {
		Project struct {
			ID      string `json:"id"`
			Version string `json:"version"`
		} `json:"project"`
		Committed bool `json:"committed"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		return importedProject{}, err
	}
	if !result.Committed || result.Project.ID == "" {
		return importedProject{}, errors.New("目标 App 未确认项目原子提交")
	}
	if reportSuccess {
		fmt.Printf(
			"已上传并通过包结构校验 %s %s（%d bytes）\n",
			result.Project.ID,
			result.Project.Version,
			len(packageBytes),
		)
	}
	return importedProject{
		ID:      result.Project.ID,
		Version: result.Project.Version,
	}, nil
}

type stagedDevelopmentPackage struct {
	PackageID string `json:"packageId"`
	GameID    string `json:"gameId"`
	ExpiresAt int64  `json:"expiresAt"`
}

func stageDevelopmentPackage(
	ctx context.Context,
	client *target.Client,
	projectID string,
	packageBytes []byte,
) (stagedDevelopmentPackage, error) {
	response, err := client.Request(
		ctx,
		http.MethodPost,
		target.ProjectPath(projectID, "/development/package"),
		bytes.NewReader(packageBytes),
		"application/zip",
	)
	if err != nil {
		return stagedDevelopmentPackage{}, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return stagedDevelopmentPackage{}, target.DecodeAPIError(response)
	}
	var staged stagedDevelopmentPackage
	if err := json.NewDecoder(response.Body).Decode(&staged); err != nil {
		return stagedDevelopmentPackage{}, err
	}
	if staged.PackageID == "" || staged.GameID != projectID || staged.ExpiresAt <= time.Now().UnixMilli() {
		return stagedDevelopmentPackage{}, errors.New("目标 App 未返回有效的临时开发包凭据")
	}
	return staged, nil
}

func startTemporaryPackagePreview(
	ctx context.Context,
	client *target.Client,
	projectID string,
	packageBytes []byte,
) (runStatus, error) {
	response, err := client.Request(
		ctx,
		http.MethodPost,
		target.ProjectPath(projectID, "/preview"),
		bytes.NewReader(packageBytes),
		"application/zip",
	)
	if err != nil {
		return runStatus{}, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return runStatus{}, target.DecodeAPIError(response)
	}
	var result struct {
		GameID string    `json:"gameId"`
		Run    runStatus `json:"run"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		return runStatus{}, err
	}
	if result.GameID != projectID || result.Run.RunID == "" {
		return runStatus{}, errors.New("目标 App 未确认临时包开发运行")
	}
	if result.Run.ProjectID == "" {
		result.Run.ProjectID = projectID
	}
	return result.Run, nil
}

func commandDev(ctx context.Context, args []string) error {
	fmt.Printf("playmesh-cli %s\n", buildinfo.Version)
	projectContext, err := project.Current()
	if err != nil {
		return err
	}
	adapter, err := adapterForProject(projectContext)
	if err != nil {
		return err
	}
	fmt.Printf(
		"[dev] 项目：%s（%s）\n",
		filepath.Base(projectContext.WorkspaceRoot),
		adapter.ID(),
	)
	source, err := adapter.PrepareDevelopment(ctx, projectContext, args)
	if err != nil {
		return err
	}
	mapping, err := source.Start(ctx)
	if err != nil {
		return err
	}
	defer func() { stopDevelopmentSource(source) }()
	projectID, client, err := prepareTargetProject(ctx, projectContext)
	if err != nil {
		return err
	}
	uploadManifest, _, err := packaging.LoadUploadManifest(
		projectContext.PackageRoot,
	)
	if err != nil {
		return err
	}
	developmentEntry := uploadManifest.GameEntry
	developmentEntryOverride := ""
	if entryMapping, ok := mapping.(development.GameEntryMapping); ok {
		developmentEntryOverride = strings.TrimSpace(
			entryMapping.DevelopmentGameEntry(),
		)
		if developmentEntryOverride == "" {
			return errors.New("项目适配器提供了空的临时游戏入口")
		}
		developmentEntry = developmentEntryOverride
	}
	basePackage, baseProjectID, err := packaging.BuildDevelopmentUpload(
		projectContext.PackageRoot,
		developmentEntryOverride,
	)
	if err != nil {
		return err
	}
	if baseProjectID != projectID {
		return errors.New("开发基础包项目 ID 与当前项目不一致")
	}
	stagedPackage, err := stageDevelopmentPackage(
		ctx,
		client,
		projectID,
		basePackage,
	)
	if err != nil {
		return err
	}
	proxy, err := development.StartProxy(
		mapping,
		client.BaseURL(),
		development.ProxyControls{
			Restart: func(restartContext context.Context) error {
				var restarted runStatus
				return client.JSON(
					restartContext,
					http.MethodPost,
					target.ProjectPath(projectID, "/run/restart"),
					nil,
					&restarted,
				)
			},
		},
	)
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := proxy.Close(); closeErr != nil {
			fmt.Fprintf(
				os.Stderr,
				"playmesh-cli: 关闭开发资源代理失败: %v\n",
				closeErr,
			)
		}
	}()
	request := proxy.Request()
	request.PackageID = stagedPackage.PackageID
	fmt.Printf(
		"[dev] 资源代理：%s\n",
		request.ResourceBaseURL,
	)
	if err := verifyDevelopmentEntry(
		ctx,
		request,
		developmentEntry,
		adapter.ID(),
	); err != nil {
		return err
	}
	var run runStatus
	developmentPath := target.ProjectPath(projectID, "/development")
	if err := client.JSON(
		ctx,
		"POST",
		developmentPath,
		request,
		&run,
	); err != nil {
		return err
	}
	if run.ProjectID == "" {
		run.ProjectID = projectID
	}
	if run.RunID == "" {
		return errors.New("目标 App 建立开发会话后未返回 runId")
	}
	defer stopTargetDevelopment(client, developmentPath)
	fmt.Printf(
		"[dev] App 会话已启动：projectId=%s，runId=%s；按 Ctrl+C 停止开发代理。\n",
		projectID,
		run.RunID,
	)
	return attachEvents(
		ctx,
		client,
		projectID,
		run.RunID,
		logAttachmentStopsDevelopment,
	)
}

func verifyDevelopmentEntry(
	ctx context.Context,
	session development.SessionRequest,
	entry string,
	adapterID string,
) error {
	entryURL := strings.TrimRight(session.ResourceBaseURL, "/") +
		"/" + strings.TrimLeft(entry, "/")
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodGet,
		entryURL,
		nil,
	)
	if err != nil {
		return err
	}
	request.Header.Set(development.CredentialHeader, session.Credential)
	client := &http.Client{
		Timeout: 15 * time.Second,
		CheckRedirect: func(
			redirect *http.Request,
			via []*http.Request,
		) error {
			if len(via) > 0 &&
				!sameHTTPOrigin(redirect.URL, via[0].URL) {
				return http.ErrUseLastResponse
			}
			return nil
		},
	}
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("开发入口预检失败: %w", err)
	}
	defer response.Body.Close()
	const inspectionLimit = 256 << 10
	body, readErr := io.ReadAll(
		io.LimitReader(response.Body, inspectionLimit+1),
	)
	if readErr != nil {
		return fmt.Errorf("读取开发入口失败: %w", readErr)
	}
	truncated := len(body) > inspectionLimit
	if truncated {
		body = body[:inspectionLimit]
	}
	diagnostic := developmentEntryDiagnostic(
		response,
		body,
		session.Credential,
		truncated,
	)
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf(
			"开发入口 %s 返回 HTTP %d；%s",
			entry,
			response.StatusCode,
			diagnostic,
		)
	}
	contentType := strings.ToLower(response.Header.Get("Content-Type"))
	bodyText := strings.ToLower(string(body))
	if !strings.Contains(contentType, "text/html") &&
		!strings.Contains(bodyText, "<html") &&
		!strings.Contains(bodyText, "<!doctype html") {
		return fmt.Errorf(
			"开发入口 %s 不是 HTML；%s",
			entry,
			diagnostic,
		)
	}
	if adapterID == "cocos" &&
		!cocosGameCanvasPattern.Match(body) {
		return fmt.Errorf(
			"Cocos 开发入口 %s 缺少 #GameCanvas；%s",
			entry,
			diagnostic,
		)
	}
	return nil
}

var cocosGameCanvasPattern = regexp.MustCompile(
	`(?s)<(?i:[a-z][a-z0-9:-]*)\b[^>]*\b(?i:id)\s*=\s*(?:"GameCanvas"|'GameCanvas'|GameCanvas(?:\s|/?>))`,
)

var sensitiveDiagnosticPattern = regexp.MustCompile(
	`(?i)(?:token|credential|authorization)["']?\s*[:=]\s*["']?[^"'&<>\s]+`,
)

var bearerDiagnosticPattern = regexp.MustCompile(
	`(?i)\bbearer\s+[a-z0-9._~+/-]+=*`,
)

func sameHTTPOrigin(left *url.URL, right *url.URL) bool {
	if left == nil || right == nil {
		return false
	}
	return strings.EqualFold(left.Scheme, right.Scheme) &&
		strings.EqualFold(left.Host, right.Host)
}

func developmentEntryDiagnostic(
	response *http.Response,
	body []byte,
	credential string,
	truncated bool,
) string {
	finalURL := "(unknown)"
	if response != nil && response.Request != nil &&
		response.Request.URL != nil {
		sanitized := *response.Request.URL
		sanitized.User = nil
		sanitized.RawQuery = ""
		sanitized.ForceQuery = false
		sanitized.Fragment = ""
		finalURL = sanitized.String()
	}
	contentType := "(missing)"
	if response != nil {
		if value := strings.TrimSpace(
			response.Header.Get("Content-Type"),
		); value != "" {
			contentType = value
		}
	}
	summary := strings.Join(strings.Fields(string(body)), " ")
	if credential != "" {
		summary = strings.ReplaceAll(
			summary,
			credential,
			"[REDACTED]",
		)
		finalURL = strings.ReplaceAll(
			finalURL,
			credential,
			"[REDACTED]",
		)
	}
	summary = sensitiveDiagnosticPattern.ReplaceAllString(
		summary,
		"[REDACTED]",
	)
	summary = bearerDiagnosticPattern.ReplaceAllString(
		summary,
		"Bearer [REDACTED]",
	)
	const summaryRunesLimit = 320
	summaryRunes := []rune(summary)
	if len(summaryRunes) > summaryRunesLimit {
		summary = string(summaryRunes[:summaryRunesLimit]) + "…"
	}
	if summary == "" {
		summary = "(empty)"
	}
	if truncated {
		summary += "（响应超过 256 KiB，摘要已截断）"
	}
	return fmt.Sprintf(
		"最终 URL: %s；Content-Type: %s；响应摘要: %q",
		finalURL,
		contentType,
		summary,
	)
}

func stopDevelopmentSource(source development.Source) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := source.Stop(ctx); err != nil {
		fmt.Fprintf(
			os.Stderr,
			"playmesh-cli: 停止项目开发资源源失败: %v\n",
			err,
		)
	}
}

func commandRun(ctx context.Context) error {
	fmt.Printf("playmesh-cli %s\n", buildinfo.Version)
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	packageRoot := filepath.Join(
		root,
		filepath.FromSlash(contract.PackageRoot),
	)
	uploadManifest, _, err := packaging.LoadUploadManifest(packageRoot)
	if err != nil {
		return err
	}
	packageBytes, err := packaging.BuildUpload(packageRoot)
	if err != nil {
		return err
	}
	targetConfig, err := targetStore.Load()
	if err != nil {
		return err
	}
	client := newTargetClient(targetConfig)
	run, err := startTemporaryPackagePreview(
		ctx,
		client,
		uploadManifest.ID,
		packageBytes,
	)
	if err != nil {
		return err
	}
	fmt.Printf("项目已启动，runId=%s\n", run.RunID)
	return nil
}

func stopTargetDevelopment(
	client *target.Client,
	developmentPath string,
) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := client.JSON(
		ctx,
		"DELETE",
		developmentPath,
		nil,
		nil,
	); err != nil {
		if target.IsAPIErrorCode(err, "not_found") {
			return
		}
		fmt.Fprintf(
			os.Stderr,
			"playmesh-cli: 撤销开发会话失败: %v\n",
			err,
		)
		return
	}
}

func commandLogs(ctx context.Context) error {
	projectContext, err := project.Current()
	if err != nil {
		return err
	}
	projectID, err := manifestProjectID(projectContext.PackageRoot)
	if err != nil {
		return err
	}
	targetConfig, err := targetStore.Load()
	if err != nil {
		return err
	}
	client := newTargetClient(targetConfig)
	var current struct {
		Run *runStatus `json:"run"`
	}
	if err := client.JSON(ctx, "GET", "/dev/api/run", nil, &current); err != nil {
		return err
	}
	if current.Run == nil {
		return errors.New("目标 App 当前没有正在运行的项目")
	}
	if current.Run.ProjectID != projectID {
		return fmt.Errorf(
			"目标 App 当前运行的是 %s，不是当前项目 %s",
			current.Run.ProjectID,
			projectID,
		)
	}
	fmt.Printf(
		"正在附加 %s 的日志，runId=%s；按 Ctrl+C 仅分离日志。\n",
		projectID,
		current.Run.RunID,
	)
	return attachEvents(
		ctx,
		client,
		projectID,
		current.Run.RunID,
		logAttachmentKeepsRun,
	)
}

type runStatus struct {
	ProjectID string `json:"projectId"`
	RunID     string `json:"runId"`
	Phase     string `json:"phase"`
	Message   string `json:"message"`
}

type logAttachmentBehavior int

const (
	logAttachmentKeepsRun logAttachmentBehavior = iota
	logAttachmentStopsDevelopment
)

func attachEvents(
	parent context.Context,
	client *target.Client,
	projectID, runID string,
	behavior logAttachmentBehavior,
) error {
	ctx, stop := signal.NotifyContext(
		parent,
		os.Interrupt,
		syscall.SIGTERM,
	)
	defer stop()
	seenEventIDs := map[string]struct{}{}
	if err := replayRuntimeLogs(ctx, client, projectID, runID, seenEventIDs); err != nil {
		return err
	}

	current, err := fetchCurrentRun(ctx, client)
	if err != nil {
		return err
	}
	if current == nil || current.ProjectID != projectID || current.RunID != runID {
		if behavior != logAttachmentStopsDevelopment {
			fmt.Println("运行已结束，日志连接已关闭。")
			return nil
		}
		if current != nil &&
			current.ProjectID == projectID &&
			current.RunID != "" {
			runID = current.RunID
			fmt.Printf(
				"[dev 日志] 检测到项目重新启动，继续附加日志，runId=%s。\n",
				runID,
			)
			if err := replayRuntimeLogs(
				ctx,
				client,
				projectID,
				runID,
				seenEventIDs,
			); err != nil {
				return err
			}
		} else {
			fmt.Println(
				"[dev 日志] 当前运行已结束，正在停止开发资源代理。",
			)
			return nil
		}
	}

	events := make(chan map[string]any)
	go streamRuntimeEvents(ctx, client, events)

	logPoll := time.NewTicker(500 * time.Millisecond)
	defer logPoll.Stop()
	runPoll := time.NewTicker(time.Second)
	defer runPoll.Stop()
	attachDevelopmentRun := func(nextRunID string) error {
		if nextRunID == "" || nextRunID == runID {
			return nil
		}
		runID = nextRunID
		fmt.Printf(
			"[dev 日志] 检测到项目重新启动，继续附加日志，runId=%s。\n",
			runID,
		)
		return replayRuntimeLogs(
			ctx,
			client,
			projectID,
			runID,
			seenEventIDs,
		)
	}
	for {
		select {
		case event, ok := <-events:
			if !ok {
				events = nil
				continue
			}
			typeName, _ := event["type"].(string)
			switch typeName {
			case "runtime.log":
				printRuntimeLog(event, projectID, runID, seenEventIDs)
			case "run.status":
				if runStatusEnded(event, projectID, runID) {
					if behavior == logAttachmentStopsDevelopment {
						_ = replayRuntimeLogs(
							ctx,
							client,
							projectID,
							runID,
							seenEventIDs,
						)
						fmt.Println(
							"[dev 日志] 当前运行已结束，正在停止开发资源代理。",
						)
						return nil
					}
					message, _ := event["message"].(string)
					if strings.TrimSpace(message) == "" {
						fmt.Printf("运行已结束：%s\n", event["phase"])
					} else {
						fmt.Fprintf(
							os.Stderr,
							"运行已结束：%s；%s\n",
							event["phase"],
							message,
						)
					}
					return nil
				}
				if behavior == logAttachmentStopsDevelopment {
					eventProject, _ := event["projectId"].(string)
					eventRunID, _ := event["runId"].(string)
					if eventProject == projectID {
						if err := attachDevelopmentRun(eventRunID); err != nil {
							return err
						}
					}
				}
			}
		case <-logPoll.C:
			if err := replayRuntimeLogs(
				ctx,
				client,
				projectID,
				runID,
				seenEventIDs,
			); err != nil {
				return err
			}
		case <-runPoll.C:
			latest, err := fetchCurrentRun(ctx, client)
			if err != nil {
				return err
			}
			if latest == nil || latest.ProjectID != projectID || latest.RunID != runID {
				if behavior == logAttachmentStopsDevelopment {
					if latest != nil &&
						latest.ProjectID == projectID &&
						latest.RunID != "" {
						if err := attachDevelopmentRun(latest.RunID); err != nil {
							return err
						}
					} else {
						_ = replayRuntimeLogs(
							ctx,
							client,
							projectID,
							runID,
							seenEventIDs,
						)
						fmt.Println(
							"[dev 日志] 当前运行已结束，正在停止开发资源代理。",
						)
						return nil
					}
					continue
				}
				_ = replayRuntimeLogs(ctx, client, projectID, runID, seenEventIDs)
				fmt.Println("运行已结束，日志连接已关闭。")
				return nil
			}
		case <-ctx.Done():
			fmt.Println(logAttachmentInterruptMessage(behavior))
			return nil
		}
	}
}

func logAttachmentInterruptMessage(behavior logAttachmentBehavior) string {
	if behavior == logAttachmentStopsDevelopment {
		return "已分离日志，正在停止开发会话和资源代理。"
	}
	return "已分离日志，App 游戏继续运行。"
}

func replayRuntimeLogs(
	ctx context.Context,
	client *target.Client,
	projectID, runID string,
	seenEventIDs map[string]struct{},
) error {
	var recent struct {
		Logs []map[string]any `json:"logs"`
	}
	path := "/dev/api/logs?limit=50&projectId=" + url.QueryEscape(projectID) + "&runId=" + url.QueryEscape(runID)
	if err := client.JSON(ctx, "GET", path, nil, &recent); err != nil {
		return err
	}
	for _, event := range recent.Logs {
		printRuntimeLog(event, projectID, runID, seenEventIDs)
	}
	return nil
}

func fetchCurrentRun(ctx context.Context, client *target.Client) (*runStatus, error) {
	var current struct {
		Run *runStatus `json:"run"`
	}
	if err := client.JSON(ctx, "GET", "/dev/api/run", nil, &current); err != nil {
		return nil, err
	}
	return current.Run, nil
}

func streamRuntimeEvents(ctx context.Context, client *target.Client, events chan<- map[string]any) {
	defer close(events)
	response, err := client.StreamRequest(
		ctx,
		"GET",
		"/dev/api/events",
		nil,
		"",
	)
	if err != nil {
		if ctx.Err() == nil {
			fmt.Fprintf(
				os.Stderr,
				"[dev 日志] 无法连接事件流，将继续轮询日志：%v\n",
				err,
			)
		}
		return
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		fmt.Fprintf(
			os.Stderr,
			"[dev 日志] 事件流返回 HTTP %d，将继续轮询日志。\n",
			response.StatusCode,
		)
		return
	}
	fmt.Println("[dev 日志] SSE 已连接。")
	scanner := bufio.NewScanner(response.Body)
	scanner.Buffer(make([]byte, 64<<10), 1<<20)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		var event map[string]any
		if json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &event) != nil {
			continue
		}
		select {
		case events <- event:
		case <-ctx.Done():
			return
		}
	}
	if scanErr := scanner.Err(); scanErr != nil && ctx.Err() == nil {
		fmt.Fprintf(
			os.Stderr,
			"[dev 日志] 事件流已断开，将继续轮询日志：%v\n",
			scanErr,
		)
	}
}

func printRuntimeLog(event map[string]any, projectID, runID string, seen map[string]struct{}) {
	eventProject, _ := event["projectId"].(string)
	eventRun, _ := event["runId"].(string)
	if (eventProject != "" && eventProject != projectID) || (eventRun != "" && eventRun != runID) {
		return
	}
	eventID, _ := event["eventId"].(string)
	if eventID != "" {
		if _, exists := seen[eventID]; exists {
			return
		}
		seen[eventID] = struct{}{}
	}
	source, _ := event["source"].(string)
	level, _ := event["level"].(string)
	message, _ := event["message"].(string)
	writer := io.Writer(os.Stdout)
	if level == "error" || level == "warn" || level == "warning" {
		writer = os.Stderr
	}
	fmt.Fprintf(writer, "[%s:%s] %s\n", source, level, message)
}

func runStatusEnded(event map[string]any, projectID, runID string) bool {
	eventProject, _ := event["projectId"].(string)
	eventRun, _ := event["runId"].(string)
	phase, _ := event["phase"].(string)
	return eventProject == projectID && eventRun == runID && (phase == "stopped" || phase == "error")
}

func manifestProjectID(root string) (string, error) {
	path := filepath.Join(root, "main.json")
	info, statErr := os.Lstat(path)
	if statErr != nil {
		return "", errors.New("当前项目缺少 main.json")
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return "", errors.New("main.json 必须是非符号链接的普通文件")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", errors.New("当前项目缺少 main.json")
	}
	var manifest struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		return "", fmt.Errorf("main.json 无效: %w", err)
	}
	if strings.TrimSpace(manifest.ID) == "" {
		return "", errors.New("main.json.id 不能为空")
	}
	return manifest.ID, nil
}
