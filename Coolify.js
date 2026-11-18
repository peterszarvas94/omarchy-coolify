.pragma library

// Coolify API client. A library script is shared by every bar instance in the
// shell process, so the notification ledger below deduplicates across monitors.

var ID = /^[A-Za-z0-9_-]{1,128}$/;
var HISTORY_TAKE = 20;

function terminal(status) {
    return status === "finished" || status === "failed" || status === "cancelled-by-user" || status === "skipped";
}

// Returns { url } or { error: translation key }.
function normalizeUrl(raw) {
    var text = String(raw || "").trim().replace(/\/+$/, "").replace(/\/api\/v1$/, "");
    var m = /^(https?):\/\/(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]+)(:\d{1,5})?(\/[^\s?#@]*)?$/.exec(text);
    if (!m)
        return { error: "errorUrl" };
    var local = m[2] === "localhost" || m[2] === "127.0.0.1" || m[2] === "[::1]";
    if (m[1] !== "https" && !local)
        return { error: "errorHttps" };
    return { url: text };
}

function validToken(token) {
    return !!token && token.length <= 4096 && !/[\r\n]/.test(token);
}

function stamp(value) {
    var text = String(value || "");
    if (/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/.test(text))
        text = text.replace(" ", "T") + "Z";
    var time = Date.parse(text);
    return isFinite(time) ? time : 0;
}

function ended(d) {
    return stamp(d.finished_at) || stamp(d.updated_at);
}

function origin(url) {
    var m = /^https?:\/\/[^\/]+/.exec(url || "");
    return m ? m[0] : "";
}

function cut(value, length) {
    return String(value === undefined || value === null ? "" : value).substring(0, length);
}

function decorate(d, app, conn) {
    app = app || {};
    var env = app.environment || {};
    var link = d.deployment_url;
    if (app.project_uuid && ID.test(env.uuid || "") && ID.test(app.uuid || "") && ID.test(d.deployment_uuid))
        link = conn.url + "/project/" + app.project_uuid + "/environment/" + env.uuid + "/application/" + app.uuid + "/deployment/" + d.deployment_uuid;
    // Never hand a server-provided external URL to the browser.
    if (!link || origin(link) !== origin(conn.url))
        link = conn.url;
    return {
        application_id: String(d.application_id === undefined ? "" : d.application_id),
        deployment_uuid: d.deployment_uuid,
        application_name: cut(d.application_name || app.name, 180),
        status: cut(d.status, 64),
        created_at: cut(d.created_at, 64),
        started_at: cut(d.started_at, 64),
        finished_at: cut(d.finished_at, 64),
        updated_at: cut(d.updated_at, 64),
        commit: cut(d.commit, 40),
        environment: cut(env.name, 128),
        deployment_url: link
    };
}

// One refresh run. abort() stops every request still in flight.
// fetch(url, token, done(exitCode, httpStatus, body)) returns { abort() }; the
// panel runs it with curl so redirects are refused and response size is capped.
function Run(conn, fetch, done) {
    this.conn = conn;
    this.fetch = fetch;
    this.done = done;
    this.requests = [];
    this.finished = false;
}
Run.prototype.finish = function (error, state) {
    if (this.finished)
        return;
    this.finished = true;
    this.abortRequests();
    this.done(error, state);
};
Run.prototype.abortRequests = function () {
    var requests = this.requests;
    this.requests = [];
    for (var i = 0; i < requests.length; i++)
        requests[i].abort();
};
Run.prototype.abort = function () {
    this.finish({ key: "errorUnreachable" });
};
// Stops without calling back, for a run whose result is no longer wanted.
Run.prototype.cancel = function () {
    this.finished = true;
    this.abortRequests();
};
Run.prototype.get = function (path, callback) {
    var run = this;
    var request = run.fetch(run.conn.url + "/api/v1" + path, run.conn.token, function (exit, status, body) {
        if (run.finished)
            return;
        var index = run.requests.indexOf(request);
        if (index >= 0)
            run.requests.splice(index, 1);
        if (exit === 63)
            return callback({ key: "errorTooLarge" });
        if (exit !== 0 || !status)
            return callback({ key: "errorUnreachable" });
        if (status === 401 || status === 403)
            return callback({ key: "errorAccess" });
        if (status >= 300 && status < 400)
            return callback({ key: "errorRedirect" });
        if (status !== 200)
            return callback({ key: "errorHttp", arg: status });
        var data;
        try {
            data = JSON.parse(body);
        } catch (e) {
            return callback({ key: "errorResponse" });
        }
        callback(null, data);
    });
    if (request)
        run.requests.push(request);
};

// Splits curl output written with -w '\n%{http_code} ' followed by its exit code.
function parseFetch(output) {
    var text = String(output || "").replace(/\n$/, "");
    var split = text.lastIndexOf("\n");
    var m = /^(\d{3}) (\d+)$/.exec(text.substring(split + 1));
    if (split < 0 || !m)
        return { exit: 1, status: 0, body: "" };
    return { exit: Number(m[2]), status: Number(m[1]), body: text.substring(0, split) };
}

// curl --proto value: plain HTTP only for the localhost exception.
function protocols(url) {
    return /^https:/.test(url) ? "=https" : "=http";
}

// Runs task(item, next) over items with at most four requests at a time.
function each(items, task, done) {
    var index = 0, running = 0, left = items.length;
    if (!left)
        return done();
    function pump() {
        while (running < 4 && index < items.length) {
            running++;
            task(items[index++], function () {
                running--;
                if (--left === 0)
                    done();
                else
                    pump();
            });
        }
    }
    pump();
}

function list(value) {
    if (Array.isArray(value))
        return value;
    // Laravel may preserve collection keys when sorting the global queue.
    if (value && typeof value === "object")
        return Object.keys(value).map(function (key) { return value[key]; });
    return [];
}

// Project details are needed for deployment links, and project/environment
// metadata rarely changes; it is cached together with the history below.
var cache = { key: "", queue: "", at: 0, apps: {}, last: null, recent: [] };

// Checks only whether the token can read applications.
function verify(conn, fetch, done) {
    var run = new Run(conn, fetch, done);
    run.get("/applications", function (error) {
        run.finish(error ? error : null);
    });
    return run;
}

// done(error, state). A poll reuses history while the deployment queue is unchanged.
function refresh(conn, fetch, filter, force, done) {
    var run = new Run(conn, fetch, done);
    var selected = {};
    var selectedCount = 0;
    String(filter || "").split(",").forEach(function (id) {
        id = id.trim();
        if (id && !selected[id]) {
            selected[id] = true;
            selectedCount++;
        }
    });
    var state = { configured: true, url: conn.url, active: [], last: null, recent: [], warning: "", checked: "" };

    run.get("/deployments", function (error, queueData) {
        if (error)
            return run.finish(error);
        var queue = list(queueData).filter(function (d) { return d && ID.test(d.deployment_uuid || ""); }).slice(0, 500);
        var queueKey = queue.map(function (d) { return d.deployment_uuid + ":" + d.status; }).sort().join(",");
        var cacheKey = conn.url + "\n" + conn.token + "\n" + filter;
        var cached = !force && cache.key === cacheKey && cache.queue === queueKey && Date.now() - cache.at < 30000;

        run.get("/applications", function (error, appData) {
            if (error)
                return run.finish(error);
            var apps = list(appData).filter(function (a) { return a && ID.test(a.uuid || ""); });
            if (apps.length > 200)
                return run.finish({ key: "errorTooMany" });
            var watched = apps.filter(function (a) { return !selectedCount || selected[a.uuid]; });
            if (selectedCount > watched.length)
                state.warning = "warnFilter";

            function complete(byId) {
                var byName = {};
                apps.forEach(function (a) {
                    byName[a.name] = a;
                    if (!byId[String(a.id)])
                        byId[String(a.id)] = a;
                });
                queue.forEach(function (d) {
                    var app = byId[String(d.application_id)] || byName[d.application_name];
                    if (selectedCount && (!app || !selected[app.uuid]))
                        return;
                    if (!terminal(d.status))
                        state.active.push(decorate(d, app, conn));
                });
                state.active.sort(function (a, b) { return stamp(a.created_at) - stamp(b.created_at); });
                state.active = state.active.slice(0, 100);
                state.checked = new Date().toISOString();
                if (!cached && !state.warning)
                    cache = { key: cacheKey, queue: queueKey, at: Date.now(), apps: byId, last: state.last, recent: state.recent };
                run.finish(null, state);
            }

            if (cached) {
                state.last = cache.last;
                state.recent = cache.recent;
                var copy = {};
                for (var id in cache.apps)
                    copy[id] = cache.apps[id];
                return complete(copy);
            }

            enrich(run, apps, function () {
                var byId = {};
                each(watched, function (app, next) {
                    run.get("/deployments/applications/" + app.uuid + "?skip=0&take=" + HISTORY_TAKE, function (error, data) {
                        if (error) {
                            state.warning = "warnHistory";
                            return next();
                        }
                        // Coolify returns the newest deployments first.
                        list(data && data.deployments).forEach(function (raw) {
                            if (!raw || !ID.test(raw.deployment_uuid || ""))
                                return;
                            if (raw.application_id !== undefined && raw.application_id !== null)
                                byId[String(raw.application_id)] = app;
                            if (!terminal(raw.status))
                                return;
                            var d = decorate(raw, app, conn);
                            if (ended(d) > Date.now() - 120000)
                                state.recent.push(d);
                            if (!state.last || ended(d) > ended(state.last))
                                state.last = d;
                        });
                        next();
                    });
                }, function () {
                    complete(byId);
                });
            });
        });
    });
    return run;
}

// /applications omits project links on some Coolify releases.
function enrich(run, apps, done) {
    run.get("/projects", function (error, projectData) {
        var projects = error ? [] : list(projectData).filter(function (p) { return p && ID.test(p.uuid || ""); });
        if (projects.length > 200)
            projects = [];
        var environments = {};
        each(projects, function (project, next) {
            run.get("/projects/" + project.uuid, function (error, details) {
                list(details && details.environments).forEach(function (env) {
                    if (env && ID.test(env.uuid || ""))
                        environments[String(env.id)] = { project: project.uuid, uuid: env.uuid, name: env.name };
                });
                next();
            });
        }, function () {
            apps.forEach(function (app) {
                var env = environments[String(app.environment_id)];
                if (env) {
                    app.project_uuid = env.project;
                    app.environment = { uuid: env.uuid, name: env.name };
                }
            });
            done();
        });
    });
}

// Shared notification ledger: deployment UUID -> { status, seen }.
var ledger = { key: "", checked: 0, records: {} };

// Returns deployments that started or reached a result since the last check.
// Silent checks only record the current state.
function transitions(key, state, silent) {
    var now = Date.now();
    if (ledger.key !== key)
        ledger = { key: key, checked: 0, records: {} };
    if (!ledger.checked || now - ledger.checked > 90000)
        silent = true;
    var observed = {};
    state.active.concat(state.recent, state.last ? [state.last] : []).forEach(function (d) {
        var seen = observed[d.deployment_uuid];
        if (!seen || !terminal(seen.status))
            observed[d.deployment_uuid] = d;
    });
    var events = [];
    Object.keys(observed).sort().forEach(function (id) {
        var d = observed[id];
        var old = ledger.records[id];
        if (old && terminal(old.status))
            return;
        var changed = !old || old.status !== d.status;
        var started = d.status === "in_progress";
        var completed = terminal(d.status) && ((old && !terminal(old.status)) || ended(d) > ledger.checked);
        if (!silent && changed && (started || completed) && events.length < 20)
            events.push(d);
        ledger.records[id] = { status: d.status, seen: now };
    });
    ledger.checked = now;
    for (var id in ledger.records) {
        if (now - ledger.records[id].seen > 7 * 24 * 3600 * 1000)
            delete ledger.records[id];
    }
    return events;
}

function duration(d) {
    var start = stamp(d.started_at) || stamp(d.created_at);
    var finish = ended(d);
    if (!start || !finish || finish < start)
        return "";
    var seconds = Math.round((finish - start) / 1000);
    return seconds < 60 ? seconds + "s" : Math.floor(seconds / 60) + "m " + seconds % 60 + "s";
}

function escapeMarkup(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
