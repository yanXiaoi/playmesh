package main

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
	"strings"
	"time"
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
	target, err := parseWorkspaceURL(raw)
	if err != nil {
		return err
	}
	client := newAPIClient(target)
	var status statusResponse
	if err := client.json(ctx, "GET", "/dev/api/status", nil, &status); err != nil {
		return err
	}
	if !status.Enabled {
		return errors.New("目标 App 未开启开发者模式")
	}
	if err := saveTarget(target); err != nil {
		return err
	}
	fmt.Printf("已连接 %s（Game SDK %s，App SDK %s）\n", target.BaseURL, status.GameSDKVersion, status.AppSDKVersion)
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
	if err := ensureGetDestination(root, projectID); err != nil {
		return err
	}
	target, err := loadTarget()
	if err != nil {
		return err
	}
	client := newAPIClient(target)
	return downloadProject(ctx, client, projectID, root)
}

func downloadProject(ctx context.Context, client *apiClient, projectID, root string) error {
	response, err := client.request(ctx, "GET", escapedProjectPath(projectID, "/package"), nil, "")
	if err != nil {
		return err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		defer response.Body.Close()
		return decodeAPIError(response)
	}
	packageBytes, err := io.ReadAll(io.LimitReader(response.Body, 64<<20+1))
	response.Body.Close()
	if err != nil {
		return err
	}
	if len(packageBytes) > 64<<20 {
		return errors.New("目标项目包超过 64 MiB")
	}
	if err := extractProjectPackage(packageBytes, root); err != nil {
		return err
	}
	bundle, err := fetchSDK(ctx, client)
	if err != nil {
		return err
	}
	versions, err := installSDK(root, bundle)
	if err != nil {
		return err
	}
	actualID, err := updateManifestSDKVersions(root, versions)
	if err != nil {
		return err
	}
	if actualID != projectID {
		return fmt.Errorf("项目包 ID %s 与请求 ID %s 不一致", actualID, projectID)
	}
	fmt.Printf("已拉取 %s（Game SDK %s，App SDK %s）\n", actualID, versions.Game, versions.App)
	return nil
}

func commandSDK(ctx context.Context) error {
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	target, err := loadTarget()
	if err != nil {
		return err
	}
	bundle, err := fetchSDK(ctx, newAPIClient(target))
	if err != nil {
		return err
	}
	versions, err := installSDK(root, bundle)
	if err != nil {
		return err
	}
	projectID, err := updateManifestSDKVersions(root, versions)
	if err != nil {
		return err
	}
	fmt.Printf("已更新 %s：Game SDK %s，App SDK %s\n", projectID, versions.Game, versions.App)
	return nil
}

func pushProject(ctx context.Context) (string, error) {
	root, err := os.Getwd()
	if err != nil {
		return "", err
	}
	versions, err := versionsFromSDK(root)
	if err != nil {
		return "", err
	}
	projectID, err := updateManifestSDKVersions(root, versions)
	if err != nil {
		return "", err
	}
	target, err := loadTarget()
	if err != nil {
		return "", err
	}
	client := newAPIClient(target)
	var status statusResponse
	if err := client.json(ctx, "GET", "/dev/api/status", nil, &status); err != nil {
		return "", err
	}
	if status.GameSDKVersion != versions.Game || status.AppSDKVersion != versions.App {
		return "", fmt.Errorf(
			"本地 SDK（%s/%s）与目标 App（%s/%s）不一致，请先执行 playmesh-cli sdk",
			versions.Game, versions.App, status.GameSDKVersion, status.AppSDKVersion,
		)
	}
	packageBytes, err := buildPackage(root)
	if err != nil {
		return "", err
	}
	response, err := client.request(ctx, "POST", "/dev/api/packages/import", bytes.NewReader(packageBytes), "application/zip")
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", decodeAPIError(response)
	}
	var result struct {
		Project struct {
			ID      string `json:"id"`
			Version string `json:"version"`
		} `json:"project"`
		Committed bool `json:"committed"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		return "", err
	}
	if !result.Committed || result.Project.ID != projectID {
		return "", errors.New("目标 App 未确认项目原子提交")
	}
	fmt.Printf("已上传并校验 %s %s（%d bytes）\n", projectID, result.Project.Version, len(packageBytes))
	return projectID, nil
}

func commandDev(ctx context.Context) error {
	fmt.Printf("playmesh-cli %s\n", cliVersion)
	projectID, err := pushProject(ctx)
	if err != nil {
		return err
	}
	target, err := loadTarget()
	if err != nil {
		return err
	}
	client := newAPIClient(target)
	var current struct {
		Run *runStatus `json:"run"`
	}
	if err := client.json(ctx, "GET", "/dev/api/run", nil, &current); err != nil {
		return err
	}
	var started runStatus
	if current.Run == nil {
		err = client.json(ctx, "POST", escapedProjectPath(projectID, "/run"), nil, &started)
	} else if current.Run.ProjectID == projectID {
		err = client.json(ctx, "POST", escapedProjectPath(projectID, "/run/restart"), nil, &started)
	} else {
		fmt.Printf("正在关闭当前项目 %s...\n", current.Run.ProjectID)
		var stopped runStatus
		if stopErr := client.json(ctx, "POST", escapedProjectPath(current.Run.ProjectID, "/run/stop"), nil, &stopped); stopErr != nil {
			return fmt.Errorf("关闭当前项目失败: %w", stopErr)
		}
		err = client.json(ctx, "POST", escapedProjectPath(projectID, "/run"), nil, &started)
	}
	if err != nil {
		return err
	}
	fmt.Printf("项目已启动，runId=%s；按 Ctrl+C 仅分离日志，不关闭游戏。\n", started.RunID)
	return attachEvents(ctx, client, projectID, started.RunID)
}

type runStatus struct {
	ProjectID string `json:"projectId"`
	RunID     string `json:"runId"`
	Phase     string `json:"phase"`
	Message   string `json:"message"`
}

func attachEvents(parent context.Context, client *apiClient, projectID, runID string) error {
	ctx, stop := signal.NotifyContext(parent, os.Interrupt)
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
		fmt.Println("运行已结束，日志连接已关闭。")
		return nil
	}

	events := make(chan map[string]any)
	go streamRuntimeEvents(ctx, client, events)

	logPoll := time.NewTicker(500 * time.Millisecond)
	defer logPoll.Stop()
	runPoll := time.NewTicker(time.Second)
	defer runPoll.Stop()
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
					fmt.Printf("运行已结束：%s\n", event["phase"])
					return nil
				}
			}
		case <-logPoll.C:
			if err := replayRuntimeLogs(ctx, client, projectID, runID, seenEventIDs); err != nil {
				return err
			}
		case <-runPoll.C:
			latest, err := fetchCurrentRun(ctx, client)
			if err != nil {
				return err
			}
			if latest == nil || latest.ProjectID != projectID || latest.RunID != runID {
				_ = replayRuntimeLogs(ctx, client, projectID, runID, seenEventIDs)
				fmt.Println("运行已结束，日志连接已关闭。")
				return nil
			}
		case <-ctx.Done():
			fmt.Println("已分离日志，App 游戏继续运行。")
			return nil
		}
	}
}

func replayRuntimeLogs(
	ctx context.Context,
	client *apiClient,
	projectID, runID string,
	seenEventIDs map[string]struct{},
) error {
	var recent struct {
		Logs []map[string]any `json:"logs"`
	}
	path := "/dev/api/logs?limit=50&projectId=" + url.QueryEscape(projectID) + "&runId=" + url.QueryEscape(runID)
	if err := client.json(ctx, "GET", path, nil, &recent); err != nil {
		return err
	}
	for _, event := range recent.Logs {
		printRuntimeLog(event, projectID, runID, seenEventIDs)
	}
	return nil
}

func fetchCurrentRun(ctx context.Context, client *apiClient) (*runStatus, error) {
	var current struct {
		Run *runStatus `json:"run"`
	}
	if err := client.json(ctx, "GET", "/dev/api/run", nil, &current); err != nil {
		return nil, err
	}
	return current.Run, nil
}

func streamRuntimeEvents(ctx context.Context, client *apiClient, events chan<- map[string]any) {
	defer close(events)
	request, err := http.NewRequestWithContext(ctx, "GET", client.endpoint("/dev/api/events"), nil)
	if err != nil {
		return
	}
	request.Header.Set("Authorization", "Bearer "+client.target.Token)
	response, err := (&http.Client{}).Do(request)
	if err != nil {
		return
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return
	}
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
	fmt.Printf("[%s:%s] %s\n", source, level, message)
}

func runStatusEnded(event map[string]any, projectID, runID string) bool {
	eventProject, _ := event["projectId"].(string)
	eventRun, _ := event["runId"].(string)
	phase, _ := event["phase"].(string)
	return eventProject == projectID && eventRun == runID && (phase == "stopped" || phase == "error")
}

func ensureGetDestination(root, projectID string) error {
	entries, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	if len(entries) == 0 {
		return nil
	}
	data, err := os.ReadFile(filepath.Join(root, "main.json"))
	if err != nil {
		return nil
	}
	var manifest struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(data, &manifest) != nil || manifest.ID != projectID {
		return errors.New("当前目录非空且不是同一个 Playmesh 项目")
	}
	return nil
}
