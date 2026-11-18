package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

type notificationRecord struct {
	Status string `json:"status"`
	Seen   int64  `json:"seen"`
}
type notificationLedger struct {
	Checked int64                         `json:"checked"`
	Records map[string]notificationRecord `json:"records"`
}
type notificationEvent struct {
	Deployment                      Deployment
	Title, Body, Urgency, OpenLabel string
}
type notificationTracker struct {
	primed, enabled bool
	key             string
}

func notificationKey(c Config, filter string) string {
	sum := sha256.Sum256([]byte(c.URL + "\n" + c.Token + "\n" + filter))
	return hex.EncodeToString(sum[:])
}
func notificationStateDir() string {
	base := os.Getenv("XDG_STATE_HOME")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(base, "omarchy-coolify")
}
func notificationLabel(labels map[string]string, key, fallback string) string {
	if text := labels[key]; text != "" {
		return text
	}
	return fallback
}
func deploymentNotification(d Deployment, labels map[string]string) notificationEvent {
	key, title := "notificationStarted", "Deployment started"
	switch d.Status {
	case "finished":
		key, title = "notificationSucceeded", "Deployment succeeded"
	case "failed":
		key, title = "notificationFailed", "Deployment failed"
	case "cancelled-by-user":
		key, title = "notificationCancelled", "Deployment cancelled"
	case "skipped":
		key, title = "notificationSkipped", "Deployment skipped"
	}
	body := d.Name
	if d.Environment != "" {
		body += " · " + d.Environment
	}
	if terminal(d.Status) {
		start := stamp(d.Started)
		if start.IsZero() {
			start = stamp(d.Created)
		}
		finish := end(d)
		if !start.IsZero() && !finish.IsZero() && !finish.Before(start) {
			duration := finish.Sub(start).Round(time.Second).String()
			body += "\n" + strings.ReplaceAll(notificationLabel(labels, "notificationDuration", "Duration: %1"), "%1", duration)
		}
	}
	urgency := "normal"
	if d.Status == "failed" {
		urgency = "critical"
	}
	return notificationEvent{Deployment: d, Title: html.EscapeString(notificationLabel(labels, key, title)), Body: html.EscapeString(body), Urgency: urgency, OpenLabel: notificationLabel(labels, "notificationOpen", "Open deployment")}
}

// Advance the whole snapshot before delivering. Concurrent monitor helpers share
// this ledger, and terminal records never regress when their API reads overlap.
func notificationTransitions(previous notificationLedger, observed []Deployment, now time.Time, silent bool, labels map[string]string) (notificationLedger, []notificationEvent) {
	if previous.Records == nil {
		previous.Records = map[string]notificationRecord{}
	}
	events := []notificationEvent{}
	byID := map[string]Deployment{}
	for _, d := range observed {
		if identifier.MatchString(d.UUID) {
			old, ok := byID[d.UUID]
			if !ok || !terminal(old.Status) {
				byID[d.UUID] = d
			}
		}
	}
	ids := []string{}
	for id := range byID {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		d := byID[id]
		old, known := previous.Records[id]
		if known && terminal(old.Status) {
			continue
		}
		changed := !known || old.Status != d.Status
		started := d.Status == "in_progress"
		completed := terminal(d.Status) && ((known && !terminal(old.Status)) || end(d).UnixMilli() > previous.Checked)
		if !silent && changed && (started || completed) && len(events) < 100 {
			events = append(events, deploymentNotification(d, labels))
		}
		previous.Records[id] = notificationRecord{Status: d.Status, Seen: now.UnixMilli()}
	}
	previous.Checked = now.UnixMilli()
	for id, r := range previous.Records {
		if now.UnixMilli()-r.Seen > int64((7*24*time.Hour)/time.Millisecond) {
			delete(previous.Records, id)
		}
	}
	if len(previous.Records) > 2000 {
		keys := []string{}
		for id := range previous.Records {
			keys = append(keys, id)
		}
		sort.Slice(keys, func(i, j int) bool { return previous.Records[keys[i]].Seen > previous.Records[keys[j]].Seen })
		for _, id := range keys[2000:] {
			delete(previous.Records, id)
		}
	}
	return previous, events
}
func (tracker *notificationTracker) check(c Config, cmd Command, s State, now time.Time) ([]notificationEvent, error) {
	enabled := cmd.Notifications != nil && *cmd.Notifications
	key := notificationKey(c, cmd.Filter)
	silent := !tracker.primed || tracker.key != key || !tracker.enabled || !enabled || s.Warning != ""
	tracker.primed = s.Warning == ""
	tracker.key = key
	tracker.enabled = enabled
	dir := notificationStateDir()
	if e := os.MkdirAll(dir, 0700); e != nil {
		return nil, e
	}
	if e := os.Chmod(dir, 0700); e != nil {
		return nil, e
	}
	lock, e := os.OpenFile(filepath.Join(dir, "notifications.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		return nil, e
	}
	defer lock.Close()
	if e = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); e != nil {
		return nil, e
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	path := filepath.Join(dir, "notifications-"+key+".json")
	ledger := notificationLedger{}
	if f, e := os.Open(path); e == nil {
		b, readErr := io.ReadAll(io.LimitReader(f, 1024*1024+1))
		f.Close()
		if readErr == nil && len(b) <= 1024*1024 {
			if json.Unmarshal(b, &ledger) != nil {
				ledger = notificationLedger{}
			}
		}
	}
	if ledger.Checked == 0 || now.UnixMilli()-ledger.Checked > 90000 {
		silent = true
	}
	observed := append([]Deployment{}, s.Active...)
	observed = append(observed, s.recent...)
	if s.Last != nil {
		observed = append(observed, *s.Last)
	}
	ledger, events := notificationTransitions(ledger, observed, now, silent, cmd.NotificationLabels)
	f, e := os.CreateTemp(dir, "notifications-*")
	if e != nil {
		return nil, e
	}
	defer os.Remove(f.Name())
	b, _ := json.Marshal(ledger)
	_, e = f.Write(b)
	if e == nil {
		e = f.Sync()
	}
	closeErr := f.Close()
	if e != nil {
		return nil, e
	}
	if closeErr != nil {
		return nil, closeErr
	}
	if e = os.Rename(f.Name(), path); e != nil {
		return nil, e
	}
	return events, nil
}
func notifyDeployment(event notificationEvent) error {
	command, e := exec.LookPath("notify-send")
	if e != nil {
		return errors.New("Desktop notifications require libnotify (notify-send).")
	}
	args := []string{"--app-name=Coolify Deployments", "--urgency=" + event.Urgency, "--action=default=" + event.OpenLabel}
	if icon := os.Getenv("OMARCHY_COOLIFY_ICON"); icon != "" {
		args = append(args, "--icon="+icon)
	}
	args = append(args, "--", event.Title, event.Body)
	cmd := exec.Command(command, args...)
	stdout, e := cmd.StdoutPipe()
	if e != nil {
		return e
	}
	if e = cmd.Start(); e != nil {
		return e
	}
	go func() {
		output, _ := io.ReadAll(io.LimitReader(stdout, 128))
		_ = cmd.Wait()
		if strings.TrimSpace(string(output)) == "default" && event.Deployment.Link != "" {
			_ = exec.Command("xdg-open", event.Deployment.Link).Run()
		}
	}()
	return nil
}
func (tracker *notificationTracker) process(cmd Command, s *State) {
	if cmd.Notifications == nil || cmd.Action == "info" {
		return
	}
	if s.Error != "" || !s.Configured || s.Checked == "" {
		tracker.primed = false
		return
	}
	c, e := load()
	if e == nil && c.URL != s.URL {
		tracker.primed = false
		return
	}
	if e != nil {
		return
	}
	events, e := tracker.check(c, cmd, *s, time.Now())
	if e != nil {
		s.Warning = joinWarning(s.Warning, "Could not save deployment notification history.")
		return
	}
	for _, event := range events {
		if e = notifyDeployment(event); e != nil {
			s.Warning = joinWarning(s.Warning, fmt.Sprint(e))
			break
		}
	}
}
func joinWarning(old, next string) string {
	if old == "" {
		return next
	}
	return old + " " + next
}
