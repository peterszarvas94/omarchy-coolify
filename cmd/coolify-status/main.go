package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

type Config struct {
	URL   string `json:"url"`
	Token string `json:"token"`
}
type Command struct {
	Notifications      *bool             `json:"notifications"`
	NotificationLabels map[string]string `json:"notificationLabels"`
	Action             string            `json:"action"`
	URL                string            `json:"url"`
	Token              string            `json:"token"`
	Filter             string            `json:"filter"`
}
type Deployment struct {
	ApplicationID json.Number `json:"application_id"`
	UUID          string      `json:"deployment_uuid"`
	Name          string      `json:"application_name"`
	Status        string      `json:"status"`
	Created       string      `json:"created_at"`
	Started       string      `json:"started_at"`
	Finished      string      `json:"finished_at"`
	Updated       string      `json:"updated_at"`
	Commit        string      `json:"commit"`
	Link          string      `json:"deployment_url"`
	Environment   string      `json:"environment"`
}
type App struct {
	ID            json.Number `json:"id"`
	EnvironmentID json.Number `json:"environment_id"`
	ProjectUUID   string
	UUID          string `json:"uuid"`
	Name          string `json:"name"`
	Environment   struct {
		Name string `json:"name"`
		UUID string `json:"uuid"`
	} `json:"environment"`
}
type State struct {
	recent     []Deployment
	Configured bool         `json:"configured"`
	URL        string       `json:"url"`
	Active     []Deployment `json:"active"`
	Last       *Deployment  `json:"last"`
	Error      string       `json:"error"`
	Warning    string       `json:"warning"`
	Checked    string       `json:"checked"`
	Saved      bool         `json:"saved"`
}

var identifier = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,128}$`)
var historyCache struct {
	key    string
	queue  string
	at     time.Time
	last   *Deployment
	apps   map[string]App
	recent []Deployment
}

// /applications omits project links on some Coolify releases. Resolve the
// environment metadata separately so deployment rows can deep-link correctly.
func enrichApps(ctx context.Context, c Config, apps []App) {
	var projects []struct {
		UUID string `json:"uuid"`
	}
	if request(ctx, c, "/projects", &projects) != nil || len(projects) > 200 {
		return
	}
	type env struct {
		ID      json.Number `json:"id"`
		UUID    string      `json:"uuid"`
		Name    string      `json:"name"`
		Project string
	}
	environments := map[string]env{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	slots := make(chan struct{}, 4)
	for _, p := range projects {
		if !identifier.MatchString(p.UUID) {
			continue
		}
		wg.Add(1)
		go func(project string) {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			var details struct {
				Environments []env `json:"environments"`
			}
			if request(ctx, c, "/projects/"+project, &details) != nil {
				return
			}
			mu.Lock()
			defer mu.Unlock()
			for _, e := range details.Environments {
				if identifier.MatchString(e.UUID) {
					e.Project = project
					environments[string(e.ID)] = e
				}
			}
		}(p.UUID)
	}
	wg.Wait()
	for i := range apps {
		if e, ok := environments[string(apps[i].EnvironmentID)]; ok {
			apps[i].ProjectUUID = e.Project
			apps[i].Environment.Name = e.Name
			apps[i].Environment.UUID = e.UUID
		}
	}
}
func decorate(d Deployment, a App, c Config) Deployment {
	if d.Name == "" {
		d.Name = a.Name
	}
	d.Environment = a.Environment.Name
	if a.ProjectUUID != "" && identifier.MatchString(a.Environment.UUID) && identifier.MatchString(a.UUID) && identifier.MatchString(d.UUID) {
		d.Link = c.URL + "/project/" + a.ProjectUUID + "/environment/" + a.Environment.UUID + "/application/" + a.UUID + "/deployment/" + d.UUID
	}
	return clean(d, c)
}

// Laravel may preserve collection keys when sorting the global queue.
type queue []Deployment

func (q *queue) UnmarshalJSON(b []byte) error {
	if len(b) > 0 && b[0] == '{' {
		var entries map[string]Deployment
		if e := json.Unmarshal(b, &entries); e != nil {
			return e
		}
		for _, d := range entries {
			*q = append(*q, d)
		}
		return nil
	}
	var entries []Deployment
	if e := json.Unmarshal(b, &entries); e != nil {
		return e
	}
	*q = entries
	return nil
}

func configPath() string {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "omarchy-coolify", "connection.json")
}
func normalize(raw string) (string, error) {
	u, e := url.Parse(strings.TrimRight(strings.TrimSpace(raw), "/"))
	if e != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("Enter a valid Coolify URL without credentials, query or fragment.")
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && (u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1" || u.Hostname() == "::1")) {
		return "", errors.New("Use HTTPS. Plain HTTP is allowed only on localhost.")
	}
	u.Path = strings.TrimSuffix(u.Path, "/api/v1")
	return strings.TrimRight(u.String(), "/"), nil
}
func load() (Config, error) {
	var c Config
	b, e := os.ReadFile(configPath())
	if e != nil {
		return c, e
	}
	e = json.Unmarshal(b, &c)
	if e != nil {
		return c, e
	}
	c.URL, e = normalize(c.URL)
	if c.Token == "" {
		return c, errors.New("missing token")
	}
	return c, e
}
func save(c Config) error {
	p := configPath()
	if e := os.MkdirAll(filepath.Dir(p), 0700); e != nil {
		return e
	}
	if e := os.Chmod(filepath.Dir(p), 0700); e != nil {
		return e
	}
	f, e := os.CreateTemp(filepath.Dir(p), "connection-*")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	b, _ := json.Marshal(c)
	if _, e = f.Write(b); e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e != nil {
		return e
	}
	if ce != nil {
		return ce
	}
	return os.Rename(f.Name(), p)
}
func request(ctx context.Context, c Config, path string, out any) error {
	req, e := http.NewRequestWithContext(ctx, "GET", c.URL+"/api/v1"+path, nil)
	if e != nil {
		return errors.New("Invalid request URL.")
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	req.Header.Set("Accept", "application/json")
	client := http.Client{Timeout: 12 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, e := client.Do(req)
	if e != nil {
		return errors.New("Cannot reach Coolify. Check the URL, network and TLS certificate.")
	}
	defer resp.Body.Close()
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return errors.New("Access denied. Check the token's read permission, team and API access.")
	}
	if resp.StatusCode != 200 {
		return fmt.Errorf("Coolify returned HTTP %d.", resp.StatusCode)
	}
	b, e := io.ReadAll(io.LimitReader(resp.Body, 8*1024*1024+1))
	if e != nil || len(b) > 8*1024*1024 {
		return errors.New("Coolify response exceeded the safe limit.")
	}
	if json.Unmarshal(b, out) != nil {
		return errors.New("Unexpected Coolify response. Check the instance URL and API version.")
	}
	return nil
}
func stamp(s string) time.Time {
	for _, layout := range []string{time.RFC3339Nano, "2006-01-02 15:04:05"} {
		if t, e := time.Parse(layout, s); e == nil {
			return t
		}
	}
	return time.Time{}
}
func end(d Deployment) time.Time {
	if t := stamp(d.Finished); !t.IsZero() {
		return t
	}
	return stamp(d.Updated)
}
func terminal(s string) bool {
	return s == "finished" || s == "failed" || s == "cancelled-by-user" || s == "skipped"
}
func clean(d Deployment, c Config) Deployment {
	limit := func(s string, n int) string {
		r := []rune(s)
		if len(r) > n {
			return string(r[:n])
		}
		return s
	}
	d.Status = limit(d.Status, 64)
	d.Environment = limit(d.Environment, 128)
	d.Created = limit(d.Created, 64)
	d.Started = limit(d.Started, 64)
	d.Finished = limit(d.Finished, 64)
	d.Updated = limit(d.Updated, 64)
	if len(d.Name) > 180 {
		d.Name = string([]rune(d.Name)[:min(180, len([]rune(d.Name)))])
	}
	if len(d.Commit) > 40 {
		d.Commit = d.Commit[:40]
	}
	// Never trust a server-provided external URL with the user's browser.
	u, e := url.Parse(d.Link)
	base, _ := url.Parse(c.URL)
	if e != nil || u.Scheme != base.Scheme || u.Host != base.Host || u.User != nil {
		d.Link = c.URL
	}
	return d
}
func refresh(c Config, filter string) State {
	return refreshPolicy(c, filter, true)
}
func refreshPolicy(c Config, filter string, force bool) State {
	s := State{Configured: true, URL: c.URL, Active: []Deployment{}}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	var active queue
	if e := request(ctx, c, "/deployments", &active); e != nil {
		s.Error = e.Error()
		return s
	}
	queueParts := []string{}
	for _, d := range active {
		queueParts = append(queueParts, d.UUID+":"+d.Status)
	}
	sort.Strings(queueParts)
	queueKey := strings.Join(queueParts, ",")
	cacheKey := c.URL + "\n" + c.Token + "\n" + filter
	useCache := !force && historyCache.key == cacheKey && historyCache.queue == queueKey && time.Since(historyCache.at) < 30*time.Second
	if useCache {
		s.Last = historyCache.last
		s.recent = historyCache.recent
	}
	var apps []App
	if e := request(ctx, c, "/applications", &apps); e != nil {
		s.Error = e.Error()
		return s
	}
	if len(apps) > 200 {
		s.Error = "More than 200 applications; narrow the API token's scope."
		return s
	}
	if !useCache {
		enrichApps(ctx, c, apps)
	}
	applicationIDs := map[string]App{}
	if useCache {
		applicationIDs = historyCache.apps
	}
	selected := map[string]bool{}
	for _, id := range strings.Split(filter, ",") {
		if id = strings.TrimSpace(id); id != "" {
			selected[id] = true
		}
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	slots := make(chan struct{}, 4)
	found := map[string]bool{}
	for _, a := range apps {
		if !identifier.MatchString(a.UUID) || (len(selected) > 0 && !selected[a.UUID]) {
			continue
		}
		found[a.UUID] = true
		if useCache {
			continue
		}
		wg.Add(1)
		go func(a App) {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			var candidate *Deployment
			recent := []Deployment{}
			localIDs := map[string]App{}
			warning := ""
			for page := 0; page < 20; page++ {
				var response struct {
					Count       int          `json:"count"`
					Deployments []Deployment `json:"deployments"`
				}
				if e := request(ctx, c, fmt.Sprintf("/deployments/applications/%s?skip=%d&take=100", a.UUID, page*100), &response); e != nil {
					warning = "Some deployment history is unavailable. " + e.Error()
					break
				}
				for _, d := range response.Deployments {
					if !identifier.MatchString(d.UUID) {
						continue
					}
					if d.ApplicationID != "" {
						localIDs[string(d.ApplicationID)] = a
					}
					d = decorate(d, a, c)
					if terminal(d.Status) {
						if end(d).After(time.Now().Add(-2*time.Minute)) && len(recent) < 100 {
							recent = append(recent, d)
						}
						if candidate == nil || end(d).After(end(*candidate)) {
							copy := d
							candidate = &copy
						}
					}
				}
				if len(response.Deployments) < 100 || (page+1)*100 >= response.Count {
					break
				}
				if page == 19 {
					warning = "History limited to the newest 2,000 deployments per application."
				}
			}
			mu.Lock()
			defer mu.Unlock()
			if len(s.recent) < 2000 {
				s.recent = append(s.recent, recent[:min(len(recent), 2000-len(s.recent))]...)
			}
			for id, app := range localIDs {
				applicationIDs[id] = app
			}
			if warning != "" {
				s.Warning = warning
			}
			if candidate != nil && (s.Last == nil || end(*candidate).After(end(*s.Last))) {
				s.Last = candidate
			}
		}(a)
	}
	wg.Wait()
	names := map[string]App{}
	ids := map[string]App{}
	for _, a := range apps {
		names[a.Name] = a
		ids[string(a.ID)] = a
	}
	for id, app := range applicationIDs {
		ids[id] = app
	}
	for _, d := range active {
		a, ok := ids[string(d.ApplicationID)]
		if !ok {
			a, ok = names[d.Name]
		}
		if len(selected) > 0 && (!ok || !found[a.UUID]) {
			continue
		}
		if !terminal(d.Status) && identifier.MatchString(d.UUID) {
			s.Active = append(s.Active, decorate(d, a, c))
		}
	}
	sort.Slice(s.Active, func(i, j int) bool { return stamp(s.Active[i].Created).Before(stamp(s.Active[j].Created)) })
	if len(s.Active) > 100 {
		s.Active = s.Active[:100]
		s.Warning = "Showing the first 100 ongoing deployments."
	}
	if len(selected) > len(found) {
		s.Warning = "Some watched application UUIDs are not visible to this token."
	}
	s.Checked = time.Now().UTC().Format(time.RFC3339)
	if !useCache && s.Warning == "" {
		historyCache.key = cacheKey
		historyCache.queue = queueKey
		historyCache.at = time.Now()
		historyCache.last = s.Last
		historyCache.apps = ids
		historyCache.recent = s.recent
	}
	return s
}
func handle(cmd Command) State {
	c, e := load()
	if cmd.Action == "forget" {
		if e := os.Remove(configPath()); e != nil && !os.IsNotExist(e) {
			return State{Error: "Could not remove connection credentials."}
		}
		return State{Active: []Deployment{}}
	}
	if cmd.Action == "connect" {
		u, err := normalize(cmd.URL)
		if err != nil {
			return State{Error: err.Error()}
		}
		token := strings.TrimSpace(cmd.Token)
		if token == "" && e == nil && u == c.URL {
			token = c.Token
		}
		if token == "" || len(token) > 4096 || strings.ContainsAny(token, "\r\n") {
			return State{Error: "Enter a valid Coolify API token."}
		}
		c = Config{u, token}
		var apps []App
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if err = request(ctx, c, "/applications", &apps); err != nil {
			return State{Error: err.Error()}
		}
		if save(c) != nil {
			return State{Error: "Could not save private connection credentials."}
		}
		s := refresh(c, cmd.Filter)
		s.Saved = true
		return s
	}
	if e != nil {
		return State{Active: []Deployment{}}
	}
	if cmd.Action == "info" {
		return State{Configured: true, URL: c.URL, Active: []Deployment{}}
	}
	return refreshPolicy(c, cmd.Filter, cmd.Action != "poll")
}
func main() {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 16384)
	encoder := json.NewEncoder(os.Stdout)
	tracker := notificationTracker{}
	for scanner.Scan() {
		var cmd Command
		if json.Unmarshal(scanner.Bytes(), &cmd) != nil {
			_ = encoder.Encode(State{Error: "Invalid command."})
			continue
		}
		state := handle(cmd)
		tracker.process(cmd, &state)
		_ = encoder.Encode(state)
	}
}
