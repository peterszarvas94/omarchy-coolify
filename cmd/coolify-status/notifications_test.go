package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestNotificationTransitions(t *testing.T) {
	now := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)
	d := Deployment{UUID: "deploy", Name: "Home System", Status: "queued", Created: now.Format(time.RFC3339), Link: "https://coolify.example.com"}
	ledger, events := notificationTransitions(notificationLedger{}, []Deployment{d}, now, true, nil)
	if len(events) != 0 {
		t.Fatal("startup notified")
	}
	d.Status = "in_progress"
	ledger, events = notificationTransitions(ledger, []Deployment{d}, now.Add(time.Second), false, nil)
	if len(events) != 1 || events[0].Title != "Deployment started" || events[0].Urgency != "normal" {
		t.Fatalf("start: %+v", events)
	}
	ledger, events = notificationTransitions(ledger, []Deployment{d}, now.Add(2*time.Second), false, nil)
	if len(events) != 0 {
		t.Fatal("duplicate start")
	}
	d.Status = "finished"
	d.Finished = now.Add(3 * time.Second).Format(time.RFC3339)
	ledger, events = notificationTransitions(ledger, []Deployment{d}, now.Add(4*time.Second), false, nil)
	if len(events) != 1 || events[0].Title != "Deployment succeeded" || !strings.Contains(events[0].Body, "Duration: 3s") {
		t.Fatalf("finish: %+v", events)
	}
	d.Status = "in_progress"
	ledger, events = notificationTransitions(ledger, []Deployment{d}, now.Add(5*time.Second), false, nil)
	if len(events) != 0 || ledger.Records[d.UUID].Status != "finished" {
		t.Fatal("terminal status regressed")
	}
}
func TestNotificationOutcomesAndEscaping(t *testing.T) {
	for status, title := range map[string]string{"failed": "Deployment failed", "cancelled-by-user": "Deployment cancelled", "skipped": "Deployment skipped"} {
		t.Run(status, func(t *testing.T) {
			now := time.Now()
			d := Deployment{UUID: "deploy", Name: `<img src="https://evil.invalid/track">`, Status: status}
			ledger := notificationLedger{Checked: now.Add(-time.Second).UnixMilli(), Records: map[string]notificationRecord{"deploy": {Status: "in_progress", Seen: now.UnixMilli()}}}
			_, events := notificationTransitions(ledger, []Deployment{d}, now, false, nil)
			if len(events) != 1 || events[0].Title != title || strings.Contains(events[0].Body, "<img") {
				t.Fatalf("unsafe outcome: %+v", events)
			}
			if (events[0].Urgency == "critical") != (status == "failed") {
				t.Fatal("incorrect urgency")
			}
		})
	}
}
func TestNotificationBaselineAndFastDeployment(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	ledger := notificationLedger{Checked: now.UnixMilli(), Records: map[string]notificationRecord{}}
	old := Deployment{UUID: "old", Status: "finished", Finished: now.Add(-time.Hour).Format(time.RFC3339)}
	fresh := Deployment{UUID: "fresh", Status: "finished", Finished: now.Add(time.Second).Format(time.RFC3339)}
	_, events := notificationTransitions(ledger, []Deployment{old, fresh}, now.Add(2*time.Second), false, nil)
	if len(events) != 1 || events[0].Deployment.UUID != "fresh" {
		t.Fatalf("historical backlog: %+v", events)
	}
	_, events = notificationTransitions(notificationLedger{}, []Deployment{fresh}, now.Add(3*time.Second), true, nil)
	if len(events) != 0 {
		t.Fatal("startup replayed results")
	}
}
func TestNotificationMonitorsAndReconnect(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	now := time.Now().UTC()
	enabled := true
	c := Config{URL: "https://coolify.example.com", Token: "fixture-token"}
	cmd := Command{Action: "poll", Notifications: &enabled}
	a, b := notificationTracker{}, notificationTracker{}
	s := State{Configured: true, Checked: now.Format(time.RFC3339)}
	for _, tracker := range []*notificationTracker{&a, &b} {
		if events, e := tracker.check(c, cmd, s, now); e != nil || len(events) != 0 {
			t.Fatalf("baseline: %v %+v", e, events)
		}
	}
	s.Active = []Deployment{{UUID: "deploy", Status: "in_progress", Name: "Home System"}}
	events, e := a.check(c, cmd, s, now.Add(time.Second))
	if e != nil || len(events) != 1 {
		t.Fatalf("first monitor: %v %+v", e, events)
	}
	events, e = b.check(c, cmd, s, now.Add(time.Second))
	if e != nil || len(events) != 0 {
		t.Fatalf("duplicate monitor: %v %+v", e, events)
	}
	s.Active = append(s.Active, Deployment{UUID: "concurrent", Status: "in_progress"})
	counts := make(chan int, 2)
	start := make(chan struct{})
	for _, tracker := range []*notificationTracker{&a, &b} {
		go func(tracker *notificationTracker) {
			<-start
			ev, err := tracker.check(c, cmd, s, now.Add(1500*time.Millisecond))
			if err != nil {
				counts <- -100
				return
			}
			counts <- len(ev)
		}(tracker)
	}
	close(start)
	if count := (<-counts) + (<-counts); count != 1 {
		t.Fatalf("concurrent monitors produced %d starts", count)
	}
	s.Active = nil
	s.recent = []Deployment{{UUID: "deploy", Status: "failed", Finished: now.Add(2 * time.Second).Format(time.RFC3339)}}
	events, e = a.check(c, cmd, s, now.Add(2*time.Minute))
	if e != nil || len(events) != 0 {
		t.Fatalf("reconnect replayed backlog: %v %+v", e, events)
	}
	path := filepath.Join(notificationStateDir(), "notifications-"+notificationKey(c, "")+".json")
	info, e := os.Stat(path)
	if e != nil || info.Mode().Perm() != 0600 {
		t.Fatal("unsafe notification state permissions")
	}
	data, _ := os.ReadFile(path)
	if strings.Contains(string(data), c.Token) || strings.Contains(string(data), "Home System") {
		t.Fatal("notification history leaked credentials or names")
	}
	var ledger notificationLedger
	if e = json.Unmarshal(data, &ledger); e != nil {
		t.Fatal(e)
	}
}
func TestNotificationsDisabledAndReenabled(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	now := time.Now()
	enabled := true
	c := Config{URL: "https://coolify.example.com", Token: "fixture-token"}
	cmd := Command{Notifications: &enabled}
	tracker := notificationTracker{}
	s := State{}
	_, _ = tracker.check(c, cmd, s, now)
	enabled = false
	s.Active = []Deployment{{UUID: "deploy", Status: "in_progress"}}
	if events, e := tracker.check(c, cmd, s, now.Add(time.Second)); e != nil || len(events) != 0 {
		t.Fatal("disabled notifications fired")
	}
	enabled = true
	if events, e := tracker.check(c, cmd, s, now.Add(2*time.Second)); e != nil || len(events) != 0 {
		t.Fatal("reenabling replayed activity")
	}
	tracker.process(Command{Action: "poll", Notifications: &enabled}, &State{Error: "offline"})
	if tracker.primed {
		t.Fatal("failed request did not reset baseline")
	}
}

func TestNotificationRefreshIncludesEveryRecentResult(t *testing.T) {
	now := time.Now().UTC()
	first := Deployment{UUID: "one", Status: "finished", Finished: now.Add(-time.Second).Format(time.RFC3339)}
	second := Deployment{UUID: "two", Status: "failed", Finished: now.Format(time.RFC3339)}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/deployments", "/api/v1/projects":
			w.Write([]byte(`[]`))
		case "/api/v1/applications":
			w.Write([]byte(`[{"id":1,"uuid":"app","name":"Home System"}]`))
		case "/api/v1/deployments/applications/app":
			json.NewEncoder(w).Encode(map[string]any{"count": 2, "deployments": []Deployment{first, second}})
		default:
			t.Errorf("unexpected URL %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	state := refresh(Config{URL: server.URL, Token: "fixture-token"}, "")
	if state.Error != "" || len(state.recent) != 2 {
		t.Fatalf("recent completions lost: %+v", state)
	}
	_, events := notificationTransitions(notificationLedger{Checked: now.Add(-5 * time.Second).UnixMilli()}, state.recent, now, false, nil)
	if len(events) != 2 {
		t.Fatalf("only the newest result notified: %+v", events)
	}
}
