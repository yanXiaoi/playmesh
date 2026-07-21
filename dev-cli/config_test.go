package main

import "testing"

func TestParseWorkspaceURL(t *testing.T) {
	target, err := parseWorkspaceURL(
		"http://10.31.2.222:16666/dev/workspace-id/workspace?token=secret-token",
	)
	if err != nil {
		t.Fatal(err)
	}
	if target.BaseURL != "http://10.31.2.222:16666" {
		t.Fatalf("unexpected base URL: %s", target.BaseURL)
	}
	if target.WorkspaceID != "workspace-id" || target.Token != "secret-token" {
		t.Fatalf("unexpected parsed target: %#v", target)
	}
	if target.WorkspaceURL != "http://10.31.2.222:16666/dev/workspace-id/workspace" {
		t.Fatalf("workspace URL must not retain token: %s", target.WorkspaceURL)
	}
}

func TestParseWorkspaceURLRejectsMissingToken(t *testing.T) {
	if _, err := parseWorkspaceURL("http://127.0.0.1:16666/dev/id/workspace"); err == nil {
		t.Fatal("expected missing token to fail")
	}
}
