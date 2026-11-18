package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConnectionSecurity(t *testing.T) {
	for _, raw := range []string{"http://example.com", "https://user:pass@example.com", "https://example.com?token=secret", "file:///etc/passwd"} {
		if _, e := normalize(raw); e == nil {
			t.Errorf("accepted %s", raw)
		}
	}
	u, e := normalize(" https://coolify.example.com/api/v1/ ")
	if e != nil || u != "https://coolify.example.com" {
		t.Fatalf("normalization: %q %v", u, e)
	}
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	if e := save(Config{u, "fixture-token"}); e != nil {
		t.Fatal(e)
	}
	for path, mode := range map[string]os.FileMode{configPath(): 0600, filepath.Dir(configPath()): 0700} {
		info, e := os.Stat(path)
		if e != nil || info.Mode().Perm() != mode {
			t.Fatalf("permissions %s: %v %v", path, info, e)
		}
	}
	c, e := load()
	if e != nil || c.Token != "fixture-token" {
		t.Fatal("credential round trip failed")
	}
}
func TestRefreshHistoryAndScope(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer fixture-token" {
			t.Error("missing bearer")
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/projects":
			w.Write([]byte(`[]`))
		case "/api/v1/applications":
			w.Write([]byte(`[{"uuid":"a","name":"Same name"},{"id":2,"uuid":"b","name":"Same name"}]`))
		case "/api/v1/deployments":
			w.Write([]byte(`{"7":{"application_id":"1","deployment_uuid":"active","application_name":"Same name","status":"in_progress"},"3":{"application_id":"2","deployment_uuid":"other","application_name":"Same name","status":"queued"}}`))
		case "/api/v1/deployments/applications/a":
			// Old start time but later finish: choose by completion, not creation.
			w.Write([]byte(`{"count":2,"deployments":[{"deployment_uuid":"newer-start","status":"finished","created_at":"2026-11-18T10:00:00Z","finished_at":"2026-11-18T10:01:00Z"},{"application_id":"1","deployment_uuid":"latest-finish","status":"failed","created_at":"2026-11-17T10:00:00Z","finished_at":"2026-11-18T10:02:00Z","deployment_url":"https://evil.invalid/"}]}`))
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	s := refresh(Config{server.URL, "fixture-token"}, "a")
	if s.Error != "" || len(s.Active) != 1 || s.Active[0].UUID != "active" || s.Last == nil || s.Last.UUID != "latest-finish" || s.Last.Link != server.URL {
		t.Fatalf("unexpected state: %+v", s)
	}
}
func TestAuthAndRedirects(t *testing.T) {
	for _, status := range []int{401, 403, 302, 429} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Location", "https://example.invalid")
				w.WriteHeader(status)
				w.Write([]byte("secret-response"))
			}))
			defer server.Close()
			var out any
			e := request(context.Background(), Config{server.URL, "fixture-token"}, "/applications", &out)
			if e == nil || strings.Contains(e.Error(), "fixture-token") || strings.Contains(e.Error(), "secret-response") {
				t.Fatalf("unsafe error: %v", e)
			}
		})
	}
}
func TestQueueShapesAndTerminalStates(t *testing.T) {
	for _, raw := range []string{`[]`, `{}`, `[{"deployment_uuid":"x"}]`, `{"4":{"deployment_uuid":"x"}}`} {
		var q queue
		if e := json.Unmarshal([]byte(raw), &q); e != nil {
			t.Fatal(e)
		}
	}
	for _, s := range []string{"finished", "failed", "cancelled-by-user", "skipped"} {
		if !terminal(s) {
			t.Fatal(s)
		}
	}
	for _, s := range []string{"queued", "in_progress", "unknown"} {
		if terminal(s) {
			t.Fatal(s)
		}
	}
}

func TestDeploymentDeepLink(t *testing.T) {
	a := App{UUID: "application", ProjectUUID: "project"}
	a.Environment.UUID = "environment"
	a.Environment.Name = "production"
	d := decorate(Deployment{UUID: "deployment", Status: "finished"}, a, Config{URL: "https://coolify.example.com"})
	if d.Link != "https://coolify.example.com/project/project/environment/environment/application/application/deployment/deployment" || d.Environment != "production" {
		t.Fatalf("unexpected deployment link: %+v", d)
	}
}

func TestProjectEnvironmentMetadata(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/projects":
			w.Write([]byte(`[{"uuid":"project"}]`))
		case "/api/v1/projects/project":
			w.Write([]byte(`{"environments":[{"id":7,"uuid":"environment","name":"production"}]}`))
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	apps := []App{{UUID: "application", EnvironmentID: "7"}}
	enrichApps(context.Background(), Config{URL: server.URL, Token: "fixture-token"}, apps)
	if apps[0].ProjectUUID != "project" || apps[0].Environment.UUID != "environment" || apps[0].Environment.Name != "production" {
		t.Fatalf("metadata not resolved: %+v", apps[0])
	}
}
