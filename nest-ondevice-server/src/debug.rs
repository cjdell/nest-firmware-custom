//! Runtime observability for agents: ring-buffered logs and request traces plus
//! a read-only `/debug/*` HTTP surface.
//!
//! Deliberately std-only (no new crates) and bounded — every buffer has a hard
//! cap so a runaway client cannot grow the 64 MiB device's heap, and the log
//! file is size-rotated to spare the jffs2 flash. The interactive shell is
//! Dropbear (already installed by the GTVHacker `rootme`), not this API.

use std::collections::{HashMap, VecDeque};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

use serde_json::{json, Map, Value};

use crate::config::Config;
use crate::http::{Request, Response};
use crate::util::now_ms;
use crate::App;

pub const LEVEL_NAMES: [&str; 4] = ["error", "warn", "info", "debug"];

const LOG_CAP: usize = 500;
const TRACE_CAP: usize = 400;
const COUNTER_CAP: usize = 256;
const MAX_MSG: usize = 800;
const MAX_SNIPPET: usize = 400;
const FILE_MAX_BYTES: u64 = 512 * 1024;
const CMD_LINES: usize = 200;

pub fn level_name(level: u8) -> &'static str {
    LEVEL_NAMES[(level as usize).min(LEVEL_NAMES.len() - 1)]
}

struct LogFile {
    path: PathBuf,
    file: File,
    written: u64,
}

#[derive(Clone)]
pub struct LogLine {
    pub ts: i64,
    pub level: u8,
    pub msg: String,
}

pub struct Trace {
    pub ts: i64,
    pub method: String,
    pub path: String,
    pub query: String,
    pub status: u16,
    pub dur_ms: i64,
    pub req_len: usize,
    pub resp_len: usize,
    pub serial: Option<String>,
    pub remote: String,
    pub body: Option<String>,
    pub note: Option<String>,
}

pub struct Inner {
    pub logs: VecDeque<LogLine>,
    pub traces: VecDeque<Trace>,
    pub counters: HashMap<String, u64>,
    pub total_requests: u64,
    pub total_errors: u64,
    pub bytes_in: u64,
    pub bytes_out: u64,
    pub level: u8,
    pub last_error: Option<String>,
}

pub struct Debug {
    pub enabled: bool,
    pub token: Option<String>,
    inner: Mutex<Inner>,
    file: Option<Mutex<LogFile>>,
}

impl Debug {
    pub fn new(cfg: &Config) -> Debug {
        let file = cfg.debug_log_file.as_ref().and_then(|p| {
            if let Some(parent) = p.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            OpenOptions::new()
                .create(true)
                .append(true)
                .open(p)
                .ok()
                .map(|file| {
                    let written = file.metadata().map(|m| m.len()).unwrap_or(0);
                    Mutex::new(LogFile {
                        path: p.clone(),
                        file,
                        written,
                    })
                })
        });
        Debug {
            enabled: cfg.debug_enabled,
            token: cfg.debug_token.clone(),
            inner: Mutex::new(Inner {
                logs: VecDeque::new(),
                traces: VecDeque::new(),
                counters: HashMap::new(),
                total_requests: 0,
                total_errors: 0,
                bytes_in: 0,
                bytes_out: 0,
                level: cfg.log_level,
                last_error: None,
            }),
            file,
        }
    }

    /// Append a log line if `level` is at or below the current verbosity.
    pub fn log(&self, level: u8, msg: impl Into<String>) {
        let msg = truncate(&msg.into(), MAX_MSG);
        let record = {
            let mut g = self.inner.lock().unwrap();
            if level > g.level {
                None
            } else {
                g.logs.push_back(LogLine {
                    ts: now_ms(),
                    level,
                    msg: msg.clone(),
                });
                while g.logs.len() > LOG_CAP {
                    g.logs.pop_front();
                }
                if level == 0 {
                    g.last_error = Some(msg.clone());
                }
                Some(level)
            }
        };
        if record.is_some() {
            self.write_file(level, &msg);
        }
    }

    pub fn error(&self, msg: impl Into<String>) {
        self.log(0, msg);
    }

    pub fn set_level(&self, level: u8) {
        self.inner.lock().unwrap().level = level.min(3);
    }

    pub fn level(&self) -> u8 {
        self.inner.lock().unwrap().level
    }

    fn write_file(&self, level: u8, msg: &str) {
        let Some(m) = self.file.as_ref() else { return };
        let mut g = match m.lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        if g.written > FILE_MAX_BYTES {
            let rotated = g.path.with_extension("log.1");
            let _ = std::fs::rename(&g.path, &rotated);
            if let Ok(f) = OpenOptions::new()
                .create(true)
                .append(true)
                .open(&g.path)
            {
                g.file = f;
                g.written = 0;
            }
        }
        let line = json!({
            "ts": now_ms(),
            "level": level_name(level),
            "msg": msg,
        })
        .to_string();
        if writeln!(g.file, "{line}").is_ok() {
            g.written += line.len() as u64 + 1;
        }
    }

    pub fn record(&self, t: Trace) {
        let key = format!("{} {}", t.method, normalize_path(&t.path));
        let mut g = self.inner.lock().unwrap();
        g.total_requests += 1;
        g.bytes_in += t.req_len as u64;
        g.bytes_out += t.resp_len as u64;
        if t.status >= 400 {
            g.total_errors += 1;
            g.last_error = Some(format!("{} {} -> {}", t.method, t.path, t.status));
        }
        if let Some(c) = g.counters.get_mut(&key) {
            *c += 1;
        } else if g.counters.len() < COUNTER_CAP {
            g.counters.insert(key, 1);
        }
        let line = format!(
            "{} {} -> {} ({} ms{} )",
            t.method,
            t.path,
            t.status,
            t.dur_ms,
            t.note.as_deref().map(|n| format!(", {n}")).unwrap_or_default()
        );
        drop(g);
        self.log(3, line);
        let mut g = self.inner.lock().unwrap();
        g.traces.push_back(t);
        while g.traces.len() > TRACE_CAP {
            g.traces.pop_front();
        }
    }
}

impl Trace {
    pub fn capture(
        req: &Request,
        remote: &str,
        serial: Option<&str>,
        status: u16,
        dur_ms: i64,
        resp_len: usize,
        note: Option<String>,
    ) -> Trace {
        let body = if req.body.is_empty() {
            None
        } else {
            let raw = String::from_utf8_lossy(&req.body).into_owned();
            // `String::truncate` panics if the byte index is not a char
            // boundary (and UTF-8 from a hostile/odd client makes that easy).
            // Reuse the char-safe helper so one bad body can't abort the daemon
            // (panic = "abort" made that fatal on-device).
            let raw = if raw.len() > MAX_SNIPPET {
                truncate(&raw, MAX_SNIPPET)
            } else {
                raw
            };
            Some(scrub(&raw))
        };
        Trace {
            ts: now_ms(),
            method: req.method.clone(),
            path: req.path.clone(),
            query: query_string(req),
            status,
            dur_ms,
            req_len: req.body.len(),
            resp_len,
            serial: serial.map(|s| s.to_string()),
            remote: remote.to_string(),
            body,
            note,
        }
    }
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

pub fn route(app: &App, req: &Request) -> Option<Response> {
    if !app.debug.enabled {
        return None;
    }
    let path = req.path.as_str();
    if path != "/debug" && !path.starts_with("/debug/") {
        return None;
    }
    if !authorized(app, req) {
        return Some(Response::json_status(
            401,
            "{\"error\":\"unauthorized: set DEBUG_TOKEN and pass ?token= or Authorization: Bearer\"}"
                .to_string(),
        ));
    }
    Some(match (req.method.as_str(), path) {
        ("GET", "/debug") | ("GET", "/debug/") => help(),
        ("GET", "/debug/status") => status(app),
        ("GET", "/debug/logs") => logs(app, req),
        ("GET", "/debug/trace") => trace(app, req),
        ("GET", "/debug/dmesg") => dmesg(req),
        ("GET", "/debug/state") => state(app),
        ("GET", "/debug/report") => report(app, req),
        ("POST", "/debug/loglevel") | ("PUT", "/debug/loglevel") => loglevel(app, req),
        _ => Response::json_status(404, "{\"error\":\"no such debug endpoint\"}".to_string()),
    })
}

fn authorized(app: &App, req: &Request) -> bool {
    let Some(token) = app.debug.token.as_ref() else {
        return true;
    };
    if token.is_empty() {
        return true;
    }
    if let Some(v) = req.header("authorization") {
        if let Some(rest) = v.strip_prefix("Bearer ") {
            if rest.trim() == token {
                return true;
            }
        }
    }
    req.query_get("token").map(|t| t == token).unwrap_or(false)
}

fn help() -> Response {
    let help = json!({
        "service": "nest-ondevice debug API",
        "endpoints": {
            "GET /debug/status": "pid, uptime, RSS, threads, fds, counters, config, devices",
            "GET /debug/logs?n=200&level=2&format=json|text": "ring-buffered log lines",
            "GET /debug/trace?n=50&format=json|text": "recent HTTP exchanges (secrets scrubbed)",
            "GET /debug/dmesg?n=200": "kernel ring buffer (busybox dmesg)",
            "GET /debug/state": "serial/owner/object-key summary (no values)",
            "GET /debug/report?n=100": "one-shot bundle: status+logs+trace+dmesg+system+config",
            "POST|PUT /debug/loglevel?level=0..3": "change verbosity at runtime",
        },
        "auth": "DEBUG_TOKEN, sent as ?token= or Authorization: Bearer <token>",
    });
    Response::json(help.to_string())
}

fn status(app: &App) -> Response {
    let (level, counters, totals) = {
        let g = app.debug.inner.lock().unwrap();
        (
            g.level,
            g.counters.clone(),
            json!({
                "requests": g.total_requests,
                "errors": g.total_errors,
                "bytes_in": g.bytes_in,
                "bytes_out": g.bytes_out,
                "last_error": g.last_error,
            }),
        )
    };

    let mut devices = Vec::new();
    {
        let avail = app.avail.lock().unwrap();
        let mut serials: Vec<_> = avail.keys().cloned().collect();
        serials.sort();
        for s in serials {
            let a = &avail[&s];
            devices.push(json!({
                "serial": s,
                "available": a.available,
                "last_seen_ms": a.last_seen_ms,
                "subscriptions": app.subs.count(&s),
            }));
        }
    }

    let body = json!({
        "server": "nest-ondevice",
        "version": env!("CARGO_PKG_VERSION"),
        "pid": std::process::id(),
        "started_ms": app.started_ms,
        "uptime_s": (now_ms() - app.started_ms) / 1000,
        "now_ms": now_ms(),
        "level": level,
        "level_name": level_name(level),
        "totals": totals,
        "counters": counters,
        "proc": proc_info(),
        "config": config_json(&app.cfg),
        "devices": devices,
        "subscriptions_total": app.subs.total(),
    });
    Response::json(body.to_string())
}

fn logs(app: &App, req: &Request) -> Response {
    let n = num_param(req, "n", 200).min(LOG_CAP);
    let min_level = num_param(req, "level", 0) as u8;
    let format = req.query_get("format").unwrap_or("json").to_string();
    let lines: Vec<Value> = {
        let g = app.debug.inner.lock().unwrap();
        let filtered: Vec<&LogLine> = g
            .logs
            .iter()
            .filter(|l| l.level >= min_level)
            .collect();
        let start = filtered.len().saturating_sub(n);
        filtered[start..]
            .iter()
            .map(|l| {
                json!({
                    "ts": l.ts,
                    "level": level_name(l.level),
                    "msg": l.msg,
                })
            })
            .collect()
    };
    if format == "text" {
        let text = lines
            .iter()
            .map(|v| {
                format!(
                    "{} [{}] {}",
                    v["ts"], v["level"].as_str().unwrap_or("?"), v["msg"].as_str().unwrap_or("")
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        return text_response(text);
    }
    Response::json(json!({ "count": lines.len(), "lines": lines }).to_string())
}

fn trace(app: &App, req: &Request) -> Response {
    let n = num_param(req, "n", 50).min(TRACE_CAP);
    let format = req.query_get("format").unwrap_or("json").to_string();
    let entries: Vec<Value> = {
        let g = app.debug.inner.lock().unwrap();
        let start = g.traces.len().saturating_sub(n);
        g.traces
            .iter()
            .skip(start)
            .map(trace_json)
            .collect()
    };
    if format == "text" {
        let text = entries
            .iter()
            .map(|v| {
                format!(
                    "{} {} {} -> {} {}ms  {}",
                    v["ts"],
                    v["method"].as_str().unwrap_or("?"),
                    v["path"].as_str().unwrap_or("/"),
                    v["status"],
                    v["dur_ms"],
                    v["note"].as_str().unwrap_or("")
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        return text_response(text);
    }
    Response::json(json!({ "count": entries.len(), "exchanges": entries }).to_string())
}

fn trace_json(t: &Trace) -> Value {
    json!({
        "ts": t.ts,
        "method": t.method,
        "path": t.path,
        "query": t.query,
        "status": t.status,
        "dur_ms": t.dur_ms,
        "req_bytes": t.req_len,
        "resp_bytes": t.resp_len,
        "serial": t.serial,
        "remote": t.remote,
        "note": t.note,
        "body": t.body,
    })
}

fn dmesg(req: &Request) -> Response {
    let n = num_param(req, "n", 200).min(CMD_LINES * 5);
    let out = syscmd("dmesg", &[]).unwrap_or_else(|| "(dmesg unavailable)".to_string());
    Response::json(json!({ "lines": tail(&out, n) }).to_string())
}

fn loglevel(app: &App, req: &Request) -> Response {
    let Some(level) = req.query_get("level").and_then(|s| s.parse::<u8>().ok()) else {
        return Response::json_status(400, "{\"error\":\"need ?level=0..3\"}".to_string());
    };
    app.debug.set_level(level);
    let new = app.debug.level();
    app.debug.log(2, format!("log level set to {new} ({})", level_name(new)));
    Response::json(json!({ "level": new, "name": level_name(new) }).to_string())
}

fn state(app: &App) -> Response {
    let mut out = Vec::new();
    {
        let store = app.store.lock().unwrap();
        for serial in store.all_serials() {
            let keys: Vec<String> = store
                .objects_by_serial(&serial)
                .into_iter()
                .map(|o| o.object_key)
                .collect();
            out.push(json!({
                "serial": serial,
                "owner": store.owner(&serial),
                "has_api_key": store.api_key(&serial).is_some(),
                "objects": keys,
            }));
        }
    }
    Response::json(json!({ "devices": out }).to_string())
}

fn report(app: &App, req: &Request) -> Response {
    let n = num_param(req, "n", 100);
    let status = serde_json::from_str::<Value>(&body_of(&status(app))).unwrap_or(Value::Null);
    let logs = serde_json::from_str::<Value>(&body_of(&logs(app, req))).unwrap_or(Value::Null);
    let trace = serde_json::from_str::<Value>(&body_of(&trace(app, req))).unwrap_or(Value::Null);
    let dmesg = syscmd("dmesg", &[]).unwrap_or_default();

    let mut system = Map::new();
    for (name, sub, args) in [
        ("uname", "uname", vec!["-a"]),
        ("uptime", "uptime", vec![]),
        ("free", "free", vec![]),
        ("date", "date", vec![]),
        ("mount", "mount", vec![]),
        ("df", "df", vec![]),
        ("ps", "ps", vec![]),
        ("ifconfig", "ifconfig", vec!["-a"]),
        ("route", "route", vec!["-n"]),
    ] {
        if let Some(out) = syscmd(sub, &args) {
            system.insert(name.to_string(), json!(tail(&out, n)));
        }
    }

    let bundle = json!({
        "generated_ms": now_ms(),
        "status": status,
        "logs": logs,
        "trace": trace,
        "dmesg": tail(&dmesg, n),
        "system": Value::Object(system),
        "config": config_json(&app.cfg),
    });
    Response::json(bundle.to_string())
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn body_of(r: &Response) -> String {
    String::from_utf8_lossy(&r.body).into_owned()
}

fn text_response(s: String) -> Response {
    let mut r = Response::new(200, s.into_bytes());
    r.headers
        .push(("Content-Type".into(), "text/plain; charset=utf-8".into()));
    r
}

fn num_param(req: &Request, name: &str, default: usize) -> usize {
    req.query_get(name)
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(default)
}

fn query_string(req: &Request) -> String {
    let mut pairs: Vec<String> = req
        .query
        .iter()
        .map(|(k, v)| {
            let kl = k.to_ascii_lowercase();
            if kl.contains("token") || kl.contains("secret") || kl.contains("pass") || kl.contains("key") {
                format!("{k}=***")
            } else {
                format!("{k}={}", scrub(v))
            }
        })
        .collect();
    pairs.sort();
    pairs.join("&")
}

/// Collapse path segments that look like serials so counters do not explode.
fn normalize_path(path: &str) -> String {
    path.split('/')
        .map(|seg| {
            if seg.len() >= 10 && seg.chars().all(|c| c.is_ascii_alphanumeric()) {
                "*"
            } else {
                seg
            }
        })
        .collect::<Vec<_>>()
        .join("/")
}

/// Best-effort secret scrubbing for request bodies and query values. Not a
/// security boundary — just enough that a shared report does not leak keys.
fn scrub(s: &str) -> String {
    let mut out = s.to_string();
    for key in ["api_key", "token", "secret", "password", "passwd"] {
        let needle = format!("\"{key}\"");
        let mut from = 0;
        while let Some(pos) = out[from..].find(&needle) {
            let start = from + pos + needle.len();
            if let Some(colon) = out[start..].find(':') {
                let vstart = start + colon + 1;
                if let Some(q1) = out[vstart..].find('"') {
                    let abs1 = vstart + q1 + 1;
                    if let Some(q2) = out[abs1..].find('"') {
                        let abs2 = abs1 + q2;
                        out.replace_range(abs1..abs2, "***");
                        from = abs1 + 3;
                        continue;
                    }
                }
            }
            from = start;
        }
    }
    out
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut t = s.chars().take(max).collect::<String>();
    t.push('…');
    t
}

fn tail(s: &str, n: usize) -> String {
    let lines: Vec<&str> = s.lines().collect();
    let start = lines.len().saturating_sub(n);
    lines[start..].join("\n")
}

fn proc_info() -> Value {
    let stats = std::fs::read_to_string("/proc/self/statm").unwrap_or_default();
    let pages: Vec<u64> = stats
        .split_whitespace()
        .filter_map(|x| x.parse().ok())
        .collect();
    let page_kb = 4u64;
    let rss_kb = pages.get(1).map(|p| p * page_kb);
    let vm_kb = pages.first().map(|p| p * page_kb);
    json!({
        "rss_kb": rss_kb,
        "vm_kb": vm_kb,
        "threads": count_dir("/proc/self/task"),
        "fds": count_dir("/proc/self/fd"),
    })
}

fn count_dir(path: &str) -> usize {
    std::fs::read_dir(path)
        .map(|d| d.filter(|e| e.is_ok()).count())
        .unwrap_or(0)
}

fn config_json(cfg: &Config) -> Value {
    json!({
        "api_origin": cfg.api_origin,
        "host": cfg.host,
        "device_port": cfg.device_port,
        "control_port": cfg.control_port,
        "data_dir": cfg.data_dir.display().to_string(),
        "suspend_time_max": cfg.suspend_time_max,
        "connection_hold_timeout": cfg.connection_hold_timeout,
        "require_device_pairing": cfg.require_device_pairing,
        "user_id": cfg.user_id,
        "store_device_logs": cfg.store_device_logs,
    })
}

/// Run a command, preferring the busybox applet of the same name. Returns
/// stdout+stderr on success, `None` otherwise. Never blocks on stdin.
fn syscmd(sub: &str, args: &[&str]) -> Option<String> {
    let mut argv: Vec<&str> = vec![sub];
    argv.extend_from_slice(args);
    for bb in ["/bin/busybox", "/usr/bin/busybox", "busybox"] {
        if let Ok(out) = std::process::Command::new(bb).args(&argv).output() {
            if out.status.success() {
                let text = String::from_utf8_lossy(&out.stdout).into_owned();
                if !text.trim().is_empty() {
                    return Some(text);
                }
            }
        }
    }
    match std::process::Command::new(sub).args(args).output() {
        Ok(out) if out.status.success() => {
            let text = String::from_utf8_lossy(&out.stdout).into_owned();
            if text.trim().is_empty() {
                Some(String::new())
            } else {
                Some(text)
            }
        }
        _ => None,
    }
}
