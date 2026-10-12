//! Nest device protocol endpoints: service discovery, pairing, transport
//! (long-poll subscribe + put), weather, upload and pro_info.

use serde_json::{json, Value};

use crate::http::{Request, Response};
use crate::state::{objects_body, DeviceObject};
use crate::util::{
    derive_structure_id, now_ms, now_secs, percent_decode, sanitize_serial, serial_from_basic,
    serial_from_client_id, shallow_merge,
};
use crate::App;

pub enum SubscribeOutcome {
    Normal(Response),
    Held {
        serial: String,
        initial: Option<String>,
        headers: Vec<(String, String)>,
    },
}

const KNOWN_BUCKET_TYPES: &[&str] = &[
    "device",
    "shared",
    "structure",
    "schedule",
    "custom_schedule",
    "user",
    "topaz",
    "demand_response",
    "demand_response_event",
    "where",
    "kryptonite",
    "diagnostics",
    "device_alert_dialog",
    "servicegroup",
    "link",
    "message",
    "tuneups",
    "utility",
    "diamond_sensor_config",
    "diamond_sensor_event",
    "rate_plan",
    "tou",
    "demand_charge",
    "demand_charge_event",
    "hvac_partner",
    "rcs_settings",
    "cloud_algo",
    "occupancy",
];

// ---------------------------------------------------------------------------
// Serial extraction
// ---------------------------------------------------------------------------

pub fn extract_serial(req: &Request) -> Option<String> {
    if let Some(auth) = req.header("authorization") {
        if let Some(s) = serial_from_basic(auth) {
            return Some(s);
        }
    }
    if let Some(s) = req.header("x-nl-client-id").and_then(serial_from_client_id) {
        return Some(s);
    }
    if let Some(s) = req.header("x-nl-device-id").and_then(sanitize_serial) {
        return Some(s);
    }
    if let Some(s) = req.header("x-nl-device-serial").and_then(sanitize_serial) {
        return Some(s);
    }
    if let Some(s) = req.query_get("serial").and_then(sanitize_serial) {
        return Some(s);
    }
    serial_from_path(&req.path)
}

fn serial_from_path(path: &str) -> Option<String> {
    if let Some(idx) = path.find("/device/") {
        let rest = &path[idx + "/device/".len()..];
        let rest = rest.strip_prefix("device.").unwrap_or(rest);
        let serial = rest.split('/').next().unwrap_or(rest);
        if let Some(s) = sanitize_serial(serial) {
            return Some(s);
        }
    }
    None
}

pub fn is_subscribe(req: &Request) -> bool {
    req.method == "POST" && (req.path == "/nest/transport" || req.path.ends_with("/subscribe"))
}

fn is_put(req: &Request) -> bool {
    req.method == "POST" && req.path.ends_with("/put")
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

pub fn route(app: &App, req: &Request) -> Option<Response> {
    let path = req.path.as_str();

    if path == "/info" {
        return Some(handle_info(app));
    }
    if path == "/nest/entry" {
        return Some(handle_entry(app, req));
    }
    if path == "/nest/ping" {
        return Some(Response::json(
            json!({"status": "ok", "timestamp": now_ms()}).to_string(),
        ));
    }
    if path == "/nest/passphrase" {
        return Some(handle_passphrase(app, req));
    }
    if path == "/nest/passphrase/status" {
        return Some(handle_passphrase_status(app, req));
    }
    if path == "/nest/upload" {
        return Some(handle_upload(app, req));
    }
    if path.starts_with("/nest/pro_info") {
        return Some(handle_pro_info(req));
    }
    if path.starts_with("/nest/weather") {
        return Some(Response::json("{}".to_string()));
    }
    if is_put(req) {
        return Some(handle_put(app, req));
    }
    if path.starts_with("/nest/transport") {
        return Some(handle_transport_get(app, req));
    }
    None
}

// ---------------------------------------------------------------------------
// Headers
// ---------------------------------------------------------------------------

fn nest_headers(app: &App, disable_defer: bool) -> Vec<(String, String)> {
    let mut h = vec![
        ("Content-Type".to_string(), "application/json".to_string()),
        (
            "X-nl-service-timestamp".to_string(),
            now_ms().to_string(),
        ),
        (
            "X-nl-suspend-time-max".to_string(),
            app.cfg.suspend_time_max.to_string(),
        ),
        (
            "X-nl-defer-device-window".to_string(),
            app.cfg.defer_device_window.to_string(),
        ),
    ];
    if disable_defer {
        h.push((
            "X-nl-disable-defer-window".to_string(),
            app.cfg.disable_defer_window.to_string(),
        ));
    }
    h
}

fn with_headers(body: String, headers: Vec<(String, String)>) -> Response {
    let mut resp = Response::json(body);
    resp.headers = headers;
    resp
}

fn contains_temperature_fields(objs: &[DeviceObject]) -> bool {
    const FIELDS: &[&str] = &[
        "target_temperature",
        "target_temperature_high",
        "target_temperature_low",
        "target_temperature_type",
        "hvac_mode",
    ];
    objs.iter().any(|o| {
        o.value
            .as_object()
            .map(|m| FIELDS.iter().any(|f| m.contains_key(*f)))
            .unwrap_or(false)
    })
}

// ---------------------------------------------------------------------------
// Entry / ping / passphrase
// ---------------------------------------------------------------------------

fn handle_entry(app: &App, _req: &Request) -> Response {
    let origin = &app.cfg.origin_with_port;
    let body = json!({
        "czfe_url": format!("{origin}/nest/transport"),
        "transport_url": format!("{origin}/nest/transport"),
        "direct_transport_url": format!("{origin}/nest/transport"),
        "passphrase_url": format!("{origin}/nest/passphrase"),
        "ping_url": format!("{origin}/nest/transport"),
        "pro_info_url": format!("{origin}/nest/pro_info"),
        "weather_url": format!("{origin}/nest/weather/v1?query="),
        "upload_url": format!("{origin}/nest/upload"),
        "software_update_url": "",
        "server_version": "1.0.0",
        "tier_name": "local",
    });
    Response::json(body.to_string())
}

fn handle_passphrase(app: &App, req: &Request) -> Response {
    let Some(serial) = extract_serial(req) else {
        return Response::json_status(400, json!({"error": "Device serial required"}).to_string());
    };
    let mut store = app.store.lock().unwrap();
    if let Some(key) = store.active_entry_key(&serial) {
        let value = key.code.clone();
        let expires = key.expires_at_ms;
        return Response::json(json!({"value": value, "expires": expires}).to_string());
    }
    let key = store.generate_entry_key(&serial, app.cfg.entry_key_ttl_seconds);
    Response::json(json!({"value": key.code, "expires": key.expires_at_ms}).to_string())
}

fn handle_passphrase_status(app: &App, req: &Request) -> Response {
    let Some(serial) = extract_serial(req) else {
        return Response::json_status(400, json!({"error": "Device serial required"}).to_string());
    };
    let store = app.store.lock().unwrap();
    match store.latest_entry_key(&serial) {
        None => Response::json(
            json!({"status": "no_key", "claimed": false, "message": "No entry key found"}).to_string(),
        ),
        Some(key) => {
            if let Some(claimed_by) = &key.claimed_by {
                Response::json(
                    json!({
                        "status": "claimed",
                        "claimed": true,
                        "claimedBy": claimed_by,
                        "claimedAt": key.claimed_at_ms,
                    })
                    .to_string(),
                )
            } else {
                Response::json(
                    json!({
                        "status": "pending",
                        "claimed": false,
                        "expiresAt": key.expires_at_ms,
                    })
                    .to_string(),
                )
            }
        }
    }
}

fn handle_info(app: &App) -> Response {
    let origin = &app.cfg.api_origin;
    let body = json!({
        "server": "nest-ondevice",
        "version": env!("CARGO_PKG_VERSION"),
        "api_origin": origin,
        "cloudregisterurl": format!("{origin}/entry"),
        "ip": host_of(origin),
        "port": app.cfg.device_port,
        "ssl": origin.starts_with("https"),
        "require_device_pairing": app.cfg.require_device_pairing,
        "entry_key_ttl_seconds": app.cfg.entry_key_ttl_seconds,
    });
    Response::json(body.to_string())
}

fn host_of(origin: &str) -> String {
    let after = origin.split("://").nth(1).unwrap_or(origin);
    after.split('/').next().unwrap_or(after).split(':').next().unwrap_or(after).to_string()
}

fn handle_pro_info(req: &Request) -> Response {
    let code = req
        .path
        .strip_prefix("/nest/pro_info/")
        .map(percent_decode)
        .unwrap_or_default();
    Response::json(
        json!({
            "id": 1,
            "pro_id": code,
            "dba": "nest-ondevice",
            "locality": "A Self-Hosted Thermostat",
            "website": "https://nolongerevil.com",
            "rating": 5.0,
        })
        .to_string(),
    )
}

fn handle_upload(app: &App, req: &Request) -> Response {
    if app.cfg.store_device_logs {
        let serial = extract_serial(req).unwrap_or_else(|| "unknown".to_string());
        let dir = app.cfg.data_dir.join("device-logs").join(&serial);
        if std::fs::create_dir_all(&dir).is_ok() {
            let name = format!("{}.log", now_ms());
            let _ = std::fs::write(dir.join(name), &req.body);
        }
    }
    Response::json(json!({"status": "ok"}).to_string())
}

// ---------------------------------------------------------------------------
// GET /nest/transport/device/{serial}
// ---------------------------------------------------------------------------

fn handle_transport_get(app: &App, req: &Request) -> Response {
    let Some(serial) = extract_serial(req) else {
        return Response::json_status(400, json!({"error": "Serial required"}).to_string());
    };
    let store = app.store.lock().unwrap();
    let objects = store.objects_by_serial(&serial);
    let mut out = String::from("{\"objects\":[");
    for (i, o) in objects.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&o.response_json(false));
    }
    out.push_str("]}");
    with_headers(out, nest_headers(app, false))
}

// ---------------------------------------------------------------------------
// Body parsing
// ---------------------------------------------------------------------------

fn parse_subscribe_body(body: &Value) -> (String, bool, Vec<Value>) {
    let session = body
        .get("session")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let chunked = body.get("chunked").and_then(|v| v.as_bool()).unwrap_or(false);

    if let Some(arr) = body.get("objects").and_then(|v| v.as_array()) {
        return (session, chunked, arr.clone());
    }

    let mut objects = Vec::new();
    if let Some(map) = body.as_object() {
        for (key, value) in map {
            if !value.is_object() || value.get("object_key").is_none() {
                continue;
            }
            // Named bucket fields are keyed by type ("device") or by
            // "device.SERIAL"; accept both, matching the reference server plus
            // the bucket-keyed variant seen in PUT bodies.
            let type_name = key.split('.').next().unwrap_or(key);
            if KNOWN_BUCKET_TYPES.contains(&key.as_str())
                || KNOWN_BUCKET_TYPES.contains(&type_name)
            {
                objects.push(value.clone());
            }
        }
    }
    (session, chunked, objects)
}

struct PutEntry {
    object_key: String,
    if_object_revision: Option<i64>,
    value: Option<Value>,
}

fn parse_put_body(body: &Value) -> Vec<PutEntry> {
    let mut entries = Vec::new();
    if let Some(arr) = body.get("objects").and_then(|v| v.as_array()) {
        for obj in arr {
            entries.push(put_entry_from(obj, false));
        }
        return entries;
    }
    if let Some(map) = body.as_object() {
        for (key, value) in map {
            if key == "session" || !value.is_object() {
                continue;
            }
            if value.get("object_key").is_some() {
                entries.push(put_entry_from(value, true));
            }
        }
    }
    entries
}

fn put_entry_from(obj: &Value, inline_value: bool) -> PutEntry {
    let value = if inline_value {
        let mut inline = serde_json::Map::new();
        if let Some(map) = obj.as_object() {
            for (k, v) in map {
                if k != "object_key" && k != "base_object_revision" && k != "if_object_revision" {
                    inline.insert(k.clone(), v.clone());
                }
            }
        }
        if inline.is_empty() {
            None
        } else {
            Some(Value::Object(inline))
        }
    } else {
        obj.get("value").filter(|v| !v.is_null()).cloned()
    };
    PutEntry {
        object_key: obj
            .get("object_key")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        if_object_revision: obj.get("if_object_revision").and_then(|v| v.as_i64()),
        value,
    }
}

// ---------------------------------------------------------------------------
// Subscribe
// ---------------------------------------------------------------------------

pub fn prepare_subscribe(app: &App, req: &Request) -> SubscribeOutcome {
    let Some(serial) = extract_serial(req) else {
        return SubscribeOutcome::Normal(Response::json_status(
            400,
            json!({"error": "Device serial required"}).to_string(),
        ));
    };
    let Some(body) = req.json() else {
        return SubscribeOutcome::Normal(Response::json_status(
            400,
            json!({"error": "Invalid JSON"}).to_string(),
        ));
    };

    let (session, chunked, client_objects) = parse_subscribe_body(&body);
    let _ = session;
    let weave = req
        .header("x-nl-weave-device-id")
        .map(|s| s.to_string());

    let mut outdated: Vec<DeviceObject> = Vec::new();
    let mut processed: Vec<(Value, DeviceObject)> = Vec::new();

    {
        let mut store = app.store.lock().unwrap();
        for client_obj in &client_objects {
            let Some(object_key) = client_obj
                .get("object_key")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
            else {
                continue;
            };
            let rev = client_obj
                .get("object_revision")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            let ts = client_obj
                .get("object_timestamp")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            let value = client_obj.get("value").filter(|v| !v.is_null()).cloned();

            // Transient ack: device clears target_change_pending without a rev bump.
            if let Some(v) = &value {
                if object_key.starts_with("shared.")
                    && v.get("target_change_pending") == Some(&Value::Bool(false))
                {
                    if let Some(existing) = store.get(&serial, &object_key).cloned() {
                        if existing.value.get("target_change_pending") == Some(&Value::Bool(true)) {
                            let mut merged = shallow_merge(&existing.value, v);
                            if let Value::Object(m) = &mut merged {
                                m.insert("target_change_pending".to_string(), Value::Bool(false));
                            }
                            store.upsert(
                                &serial,
                                DeviceObject::new(
                                    object_key.clone(),
                                    existing.object_revision,
                                    existing.object_timestamp,
                                    merged,
                                ),
                            );
                        }
                    }
                }
            }

            let server_obj = store.get(&serial, &object_key).cloned();
            let is_update = value.is_some() && rev == 0 && ts == 0;

            let response_obj = if is_update {
                let existing_value = server_obj
                    .as_ref()
                    .map(|o| o.value.clone())
                    .unwrap_or_else(|| json!({}));
                let mut merged = shallow_merge(&existing_value, value.as_ref().unwrap());
                if let Some(w) = &weave {
                    if let Value::Object(m) = &mut merged {
                        m.insert("weave_device_id".to_string(), Value::String(w.clone()));
                    }
                }
                if object_key == format!("device.{serial}") {
                    merged = preserve_fan_timer_state(
                        server_obj.as_ref().map(|o| &o.value),
                        merged,
                    );
                }
                let base_rev = server_obj.as_ref().map(|o| o.object_revision).unwrap_or(0);
                let equal = server_obj
                    .as_ref()
                    .map(|o| o.value == merged)
                    .unwrap_or(false);
                let new_rev = if equal { base_rev } else { base_rev + 1 };
                let obj = DeviceObject::new(object_key.clone(), new_rev, now_ms(), merged);
                store.upsert(&serial, obj.clone());
                obj
            } else {
                match server_obj {
                    Some(o) => o,
                    None => DeviceObject::new(object_key.clone(), 0, 0, json!({})),
                }
            };

            processed.push((client_obj.clone(), response_obj.clone()));
        }

        // Outdated (server newer) and client-newer objects.
        let mut to_merge: Vec<(Value, DeviceObject)> = Vec::new();
        for (client_obj, response_obj) in &processed {
            let client_ts = client_obj
                .get("object_timestamp")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            if is_server_newer(response_obj.object_timestamp, client_ts) {
                outdated.push(response_obj.clone());
            } else if client_ts > response_obj.object_timestamp {
                to_merge.push((client_obj.clone(), response_obj.clone()));
            }
        }

        for (client_obj, server_obj) in to_merge {
            let object_key = client_obj
                .get("object_key")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let client_value = client_obj.get("value").filter(|v| !v.is_null()).cloned();
            if let Some(cv) = client_value {
                if !object_key.is_empty() {
                    let merged = shallow_merge(&server_obj.value, &cv);
                    let rev = client_obj
                        .get("object_revision")
                        .and_then(|v| v.as_i64())
                        .unwrap_or(0);
                    let ts = client_obj
                        .get("object_timestamp")
                        .and_then(|v| v.as_i64())
                        .unwrap_or(0);
                    store.upsert(&serial, DeviceObject::new(object_key, rev, ts, merged));
                }
            }
        }
    }

    inject_pairing(app, &serial, &processed, &mut outdated);

    let disable = contains_temperature_fields(&outdated);
    let headers = nest_headers(app, disable);

    if !chunked {
        return SubscribeOutcome::Normal(with_headers(objects_body(&outdated), headers));
    }

    let initial = if outdated.is_empty() {
        None
    } else {
        Some(objects_body(&outdated))
    };
    SubscribeOutcome::Held {
        serial,
        initial,
        headers,
    }
}

fn is_server_newer(server_ts: i64, client_ts: i64) -> bool {
    if client_ts == 0 {
        return true;
    }
    if server_ts == 0 {
        return false;
    }
    server_ts > client_ts
}

/// Inject the `user.*` and `structure.*` buckets that convince the thermostat it
/// is paired. In open mode this also auto-claims the device.
fn inject_pairing(
    app: &App,
    serial: &str,
    processed: &[(Value, DeviceObject)],
    outdated: &mut Vec<DeviceObject>,
) {
    let Some(user_id) = app.resolve_user(serial) else {
        return;
    };
    let now = now_ms();
    let user_key = format!("user.{user_id}");
    let structure_id = derive_structure_id(&user_id);
    let structure_key = format!("structure.{structure_id}");

    {
        let mut store = app.store.lock().unwrap();
        if store.get(serial, &user_key).is_none() {
            store.upsert(
                serial,
                DeviceObject::new(user_key.clone(), 1, now, json!({"name": user_id})),
            );
        }
        if store.get(serial, &structure_key).is_none() {
            store.upsert(
                serial,
                DeviceObject::new(
                    structure_key.clone(),
                    1,
                    now,
                    json!({"name": "Home", "devices": [serial]}),
                ),
            );
        }
    }

    let client_ts = |key: &str| -> i64 {
        processed
            .iter()
            .find(|(c, _)| c.get("object_key").and_then(|v| v.as_str()) == Some(key))
            .and_then(|(c, _)| c.get("object_timestamp").and_then(|v| v.as_i64()))
            .unwrap_or(0)
    };
    let user_already = outdated.iter().any(|o| o.object_key == user_key);
    let structure_already = outdated.iter().any(|o| o.object_key == structure_key);

    {
        let store = app.store.lock().unwrap();
        if !user_already {
            if let Some(user_obj) = store.get(serial, &user_key).cloned() {
                if client_ts(&user_key) < user_obj.object_timestamp {
                    outdated.push(user_obj);
                }
            }
        }
    }

    let first_time = {
        let mut sent = app.structure_sent.lock().unwrap();
        !sent.contains(serial) && sent.insert(serial.to_string())
    };
    if !structure_already {
        let store = app.store.lock().unwrap();
        if let Some(struct_obj) = store.get(serial, &structure_key).cloned() {
            if client_ts(&structure_key) < struct_obj.object_timestamp || first_time {
                outdated.push(struct_obj);
            }
        }
    }
}

fn preserve_fan_timer_state(existing: Option<&Value>, mut new: Value) -> Value {
    let Some(existing) = existing else {
        return new;
    };
    const FAN_KEYS: &[&str] = &[
        "fan_timer_timeout",
        "fan_control_state",
        "fan_timer_duration",
        "fan_current_speed",
        "fan_mode",
    ];
    if let Value::Object(n) = &new {
        if n.get("fan_timer_timeout") == Some(&Value::from(0))
            || n.get("fan_control_state") == Some(&Value::Bool(false))
        {
            return new;
        }
    }
    let active = existing
        .get("fan_timer_timeout")
        .and_then(|v| v.as_i64())
        .map(|t| t > now_secs())
        .unwrap_or(false);
    if !active {
        return new;
    }
    if let (Value::Object(n), Value::Object(e)) = (&mut new, existing) {
        for k in FAN_KEYS {
            if !n.contains_key(*k) {
                if let Some(v) = e.get(*k) {
                    n.insert((*k).to_string(), v.clone());
                }
            }
        }
    }
    new
}

// ---------------------------------------------------------------------------
// PUT
// ---------------------------------------------------------------------------

fn handle_put(app: &App, req: &Request) -> Response {
    let Some(serial) = extract_serial(req) else {
        return Response::json_status(400, json!({"error": "Device serial required"}).to_string());
    };
    let Some(body) = req.json() else {
        return Response::json_status(400, json!({"error": "Invalid JSON"}).to_string());
    };
    let weave = req.header("x-nl-weave-device-id").map(|s| s.to_string());
    let entries = parse_put_body(&body);

    let mut response_objects: Vec<String> = Vec::new();
    {
        let mut store = app.store.lock().unwrap();
        for entry in entries {
            if entry.object_key.is_empty() || entry.value.is_none() {
                continue;
            }
            let value = entry.value.unwrap();
            let server_obj = store.get(&serial, &entry.object_key).cloned();

            // Conditional write (compare-and-swap).
            if let Some(if_rev) = entry.if_object_revision {
                let server_rev = server_obj.as_ref().map(|o| o.object_revision).unwrap_or(0);
                if if_rev != server_rev {
                    let (rev, ts) = server_obj
                        .as_ref()
                        .map(|o| (o.object_revision, o.object_timestamp))
                        .unwrap_or((0, 0));
                    response_objects.push(meta_json(rev, ts, &entry.object_key));
                    continue;
                }
            }

            let existing_value = server_obj
                .as_ref()
                .map(|o| o.value.clone())
                .unwrap_or_else(|| json!({}));
            let mut merged = shallow_merge(&existing_value, &value);
            if let Some(w) = &weave {
                if let Value::Object(m) = &mut merged {
                    m.insert("weave_device_id".to_string(), Value::String(w.clone()));
                }
            }
            if entry.object_key == format!("device.{serial}") {
                merged = preserve_fan_timer_state(server_obj.as_ref().map(|o| &o.value), merged);
            }

            let changed = server_obj
                .as_ref()
                .map(|o| o.value != merged)
                .unwrap_or(true);
            let base_rev = server_obj.as_ref().map(|o| o.object_revision).unwrap_or(0);
            let new_rev = if changed { base_rev + 1 } else { base_rev };
            let new_ts = if changed {
                now_ms()
            } else {
                server_obj
                    .as_ref()
                    .map(|o| o.object_timestamp)
                    .unwrap_or_else(now_ms)
            };
            let obj = DeviceObject::new(entry.object_key.clone(), new_rev, new_ts, merged);
            store.upsert(&serial, obj);
            response_objects.push(meta_json(new_rev, new_ts, &entry.object_key));
        }
    }

    let mut out = String::from("{\"objects\":[");
    for (i, o) in response_objects.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(o);
    }
    out.push_str("]}");
    with_headers(out, nest_headers(app, false))
}

fn meta_json(rev: i64, ts: i64, key: &str) -> String {
    let key = serde_json::to_string(key).unwrap_or_else(|_| "\"\"".into());
    format!("{{\"object_revision\":{rev},\"object_timestamp\":{ts},\"object_key\":{key}}}")
}
