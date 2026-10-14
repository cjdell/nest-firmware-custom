//! Control API: status, device list, commands, stats and registration.

use serde_json::{json, Map, Value};

use crate::http::{Request, Response};
use crate::state::DeviceObject;
use crate::util::{derive_structure_id, now_ms, now_secs, sanitize_serial, shallow_merge};
use crate::App;

const DEVICE_SETTING_WHITELIST: &[&str] = &[
    "lower_safety_temp_enabled",
    "upper_safety_temp_enabled",
    "lower_safety_temp",
    "upper_safety_temp",
    "temp_lock_on",
    "temp_lock_pin_hash",
    "temp_lock_high_temp",
    "temp_lock_low_temp",
    "learning_mode",
    "preconditioning_enabled",
    "preconditioning_active",
    "target_humidity_enabled",
    "target_humidity",
    "temperature_scale",
    "time_to_target",
    "time_to_target_training_status",
    "sunlight_correction_enabled",
    "fan_timer_duration_minutes",
    "fan_duty_cycle",
    "fan_duty_start_time",
    "fan_duty_end_time",
    "fan_schedule_speed",
    "heat_pump_aux_threshold_enabled",
    "heat_pump_aux_threshold",
    "heat_pump_comp_threshold_enabled",
    "heat_pump_comp_threshold",
    "equipment_type",
    "heat_source",
    "hot_water_boost_time_to_end",
    "hot_water_active",
    "filter_reminder_enabled",
    "filter_reminder_level",
    "postal_code",
    "country_code",
];

/// Schedule setpoint bounds, in Celsius (the wire is always Celsius). Matches
/// upstream `command.py:256-257` and the Nest app's own 41-90 °F limits.
const TEMP_MIN_C: f64 = 4.5;
const TEMP_MAX_C: f64 = 32.0;

pub fn route(app: &App, req: &Request) -> Option<Response> {
    let path = req.path.as_str();
    match (req.method.as_str(), path) {
        ("POST", "/command") => Some(handle_command(app, req)),
        ("GET", "/status") => Some(handle_status(app, req)),
        ("GET", "/api/devices") => Some(handle_devices(app)),
        ("GET", "/api/schedule") => Some(handle_schedule(app, req)),
        ("POST", "/notify-device") => Some(handle_notify_device(app, req)),
        ("GET", "/api/config") => Some(handle_config(app)),
        ("GET", "/api/stats") => Some(handle_stats(app)),
        ("POST", "/api/register") => Some(handle_register(app, req)),
        ("GET", "/api/registered-devices") => Some(handle_registered_devices(app, req)),
        ("POST", "/api/ensure-user") => Some(handle_ensure_user(app, req)),
        _ => {
            if req.method == "POST" && path.starts_with("/api/dismiss-pairing/") {
                return Some(handle_dismiss_pairing(app, req));
            }
            if req.method == "DELETE" && path.starts_with("/api/devices/") {
                return Some(handle_delete_device(app, req));
            }
            if req.method == "DELETE" && path.starts_with("/api/registered-devices/") {
                return Some(handle_delete_registered(app, req));
            }
            None
        }
    }
}

fn json_response(status: u16, body: Value) -> Response {
    Response::json_status(status, body.to_string())
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

pub fn format_device_status(app: &App, serial: &str) -> Value {
    let (device_values, shared_values, api_key) = {
        let store = app.store.lock().unwrap();
        let dv = store
            .get(serial, &format!("device.{serial}"))
            .map(|o| o.value.clone())
            .unwrap_or_else(|| json!({}));
        let sv = store
            .get(serial, &format!("shared.{serial}"))
            .map(|o| o.value.clone())
            .unwrap_or_else(|| json!({}));
        (dv, sv, store.api_key(serial).map(|s| s.to_string()))
    };

    let get = |v: &Value, key: &str| v.get(key).cloned().unwrap_or(Value::Null);
    let bool_at = |v: &Value, key: &str| v.get(key).and_then(|x| x.as_bool()).unwrap_or(false);
    let prefer = |key: &str, default: Value| {
        let s = shared_values.get(key).cloned().unwrap_or(Value::Null);
        if !s.is_null() {
            s
        } else {
            let d = device_values.get(key).cloned().unwrap_or(Value::Null);
            if !d.is_null() {
                d
            } else {
                default
            }
        }
    };

    let last_seen = app.last_seen(serial);
    let name = shared_values
        .get("label")
        .or_else(|| shared_values.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or(serial)
        .to_string();

    let fan_timeout = device_values
        .get("fan_timer_timeout")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);

    json!({
        "serial": serial,
        "api_key": api_key,
        "is_available": app.is_available(serial),
        "last_seen": last_seen,
        "name": name,
        "current_temperature": prefer("current_temperature", Value::Null),
        "target_temperature": prefer("target_temperature", Value::Null),
        "target_temperature_high": prefer("target_temperature_high", Value::Null),
        "target_temperature_low": prefer("target_temperature_low", Value::Null),
        "humidity": get(&device_values, "current_humidity"),
        "target_humidity": get(&device_values, "target_humidity"),
        "target_humidity_enabled": bool_at(&device_values, "target_humidity_enabled"),
        "mode": prefer("target_temperature_type", Value::Null),
        "hvac": {
            "heater": bool_at(&shared_values, "hvac_heater_state"),
            "heat_x2": bool_at(&shared_values, "hvac_heat_x2_state"),
            "heat_x3": bool_at(&shared_values, "hvac_heat_x3_state"),
            "ac": bool_at(&shared_values, "hvac_ac_state"),
            "cool_x2": bool_at(&shared_values, "hvac_cool_x2_state"),
            "cool_x3": bool_at(&shared_values, "hvac_cool_x3_state"),
            "fan": bool_at(&shared_values, "hvac_fan_state"),
            "aux_heat": bool_at(&shared_values, "hvac_aux_heater_state"),
            "emer_heat": bool_at(&shared_values, "hvac_emer_heat_state"),
            "alt_heat": bool_at(&shared_values, "hvac_alt_heat_state"),
            "humidifier": bool_at(&device_values, "humidifier_state"),
            "dehumidifier": bool_at(&device_values, "dehumidifier_state"),
            "auto_dehum": bool_at(&device_values, "auto_dehum_state"),
            "fan_cooling": bool_at(&device_values, "fan_cooling_state"),
        },
        "fan_timer_active": fan_timeout > now_secs(),
        "fan_timer_timeout": fan_timeout,
        "eco_temperatures": {
            "high": device_values.get("away_temperature_high").cloned().unwrap_or(Value::Null),
            "low": device_values.get("away_temperature_low").cloned().unwrap_or(Value::Null),
        },
        "is_online": bool_at(&device_values, "is_online"),
        "has_leaf": bool_at(&device_values, "leaf"),
        "software_version": get(&device_values, "current_version"),
        "temperature_scale": device_values.get("temperature_scale").cloned().unwrap_or_else(|| json!("C")),
        "capabilities": {
            "can_heat": prefer("can_heat", json!(true)),
            "can_cool": prefer("can_cool", json!(true)),
            "has_fan": prefer("has_fan", json!(false)),
            "has_emer_heat": prefer("has_emer_heat", json!(false)),
            "has_humidifier": prefer("has_humidifier", json!(false)),
            "has_dehumidifier": prefer("has_dehumidifier", json!(false)),
        },
        "eco_mode": device_values.get("eco").and_then(|e| e.get("mode")).cloned().unwrap_or(Value::Null),
        "time_to_target": get(&device_values, "time_to_target"),
        "time_to_target_training_status": get(&device_values, "time_to_target_training_status"),
        "safety_state": get(&device_values, "safety_state"),
        "safety_temp_activating_hvac": get(&device_values, "safety_temp_activating_hvac"),
        "learning_mode": get(&device_values, "learning_mode"),
        "preconditioning_enabled": get(&device_values, "preconditioning_enabled"),
        "backplate_temperature": get(&device_values, "backplate_temperature"),
        "local_ip": get(&device_values, "local_ip"),
        "mac_address": get(&device_values, "mac_address"),
        "structure_id": shared_values.get("structure_id").cloned().unwrap_or(Value::Null),
        "away": shared_values.get("away").cloned().unwrap_or(json!(false)),
        "schedule_mode": shared_values.get("schedule_mode").cloned().unwrap_or(Value::Null),
    })
}

fn handle_status(app: &App, req: &Request) -> Response {
    let Some(serial) = req.query_get("serial") else {
        return json_response(400, json!({"error": "Serial parameter required"}));
    };
    let exists = {
        let store = app.store.lock().unwrap();
        !store.objects_by_serial(serial).is_empty()
    };
    if !exists {
        return json_response(404, json!({"error": "Device not found"}));
    }
    json_response(200, format_device_status(app, serial))
}

fn handle_devices(app: &App) -> Response {
    let serials: Vec<String> = {
        let store = app.store.lock().unwrap();
        if app.cfg.require_device_pairing {
            store.data.owners.keys().cloned().collect()
        } else {
            let mut s: Vec<String> = store.data.objects.keys().cloned().collect();
            for k in store.data.owners.keys() {
                if !s.contains(k) {
                    s.push(k.clone());
                }
            }
            s
        }
    };
    let mut devices = Vec::new();
    for serial in &serials {
        let mut status = format_device_status(app, serial);
        if let Value::Object(m) = &mut status {
            m.insert(
                "subscription_count".to_string(),
                json!(app.subs.count(serial)),
            );
        }
        devices.push(status);
    }
    json_response(
        200,
        json!({"devices": devices, "total": devices.len()}),
    )
}

fn handle_schedule(app: &App, req: &Request) -> Response {
    let Some(serial) = req.query_get("serial") else {
        return json_response(400, json!({"error": "Serial parameter required"}));
    };
    let store = app.store.lock().unwrap();
    match store.get(serial, &format!("schedule.{serial}")) {
        None => json_response(200, json!({"serial": serial, "schedule": null})),
        Some(obj) => json_response(
            200,
            json!({
                "serial": serial,
                "schedule": obj.value,
                "object_revision": obj.object_revision,
                "object_timestamp": obj.object_timestamp,
            }),
        ),
    }
}

fn handle_notify_device(app: &App, req: &Request) -> Response {
    let Some(body) = req.json() else {
        return json_response(400, json!({"error": "Invalid JSON"}));
    };
    let Some(serial) = body.get("serial").and_then(|v| v.as_str()) else {
        return json_response(400, json!({"error": "Serial required"}));
    };
    let objects = {
        let store = app.store.lock().unwrap();
        store.objects_by_serial(serial)
    };
    if objects.is_empty() {
        return json_response(404, json!({"error": "Device not found"}));
    }
    let notified = app.subs.notify(serial, objects);
    json_response(
        200,
        json!({"success": true, "subscribers_notified": notified}),
    )
}

fn handle_config(app: &App) -> Response {
    json_response(
        200,
        json!({
            "api_origin": app.cfg.api_origin,
            "cloudregisterurl": format!("{}/entry", app.cfg.api_origin),
            "require_device_pairing": app.cfg.require_device_pairing,
            "entry_key_ttl_seconds": app.cfg.entry_key_ttl_seconds,
        }),
    )
}

fn handle_stats(app: &App) -> Response {
    let (serials, owners) = {
        let store = app.store.lock().unwrap();
        (
            store.data.objects.keys().cloned().collect::<Vec<_>>(),
            store.data.owners.keys().cloned().collect::<Vec<_>>(),
        )
    };
    let available = serials.iter().filter(|s| app.is_available(s)).count();
    json_response(
        200,
        json!({
            "devices": {
                "total": serials.len(),
                "available": available,
                "serials": serials,
                "registered": owners,
            },
            "subscriptions": {
                "total_subscriptions": app.subs.total(),
            },
        }),
    )
}

fn handle_dismiss_pairing(app: &App, req: &Request) -> Response {
    let serial = req
        .path
        .trim_start_matches("/api/dismiss-pairing/")
        .to_string();
    let key = format!("device_alert_dialog.{serial}");
    let mut store = app.store.lock().unwrap();
    if let Some(existing) = store.get(&serial, &key).cloned() {
        let obj = DeviceObject::new(key, existing.object_revision + 1, now_ms(), json!({}));
        store.upsert(&serial, obj.clone());
        drop(store);
        app.subs.notify(&serial, vec![obj]);
    }
    json_response(200, json!({"success": true}))
}

fn handle_delete_device(app: &App, req: &Request) -> Response {
    let serial = req.path.trim_start_matches("/api/devices/").to_string();
    let mut store = app.store.lock().unwrap();
    let n = store.delete_device(&serial);
    json_response(
        200,
        json!({"success": n > 0, "deleted_objects": n}),
    )
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

fn is_valid_code(code: &str) -> bool {
    code.len() == 7 && code.chars().all(|c| c.is_ascii_alphanumeric())
}

fn handle_register(app: &App, req: &Request) -> Response {
    let Some(body) = req.json() else {
        return json_response(400, json!({"success": false, "message": "Invalid JSON"}));
    };
    let code = body
        .get("code")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_uppercase();
    let user_id = body
        .get("userId")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if code.is_empty() || user_id.is_empty() {
        return json_response(
            400,
            json!({"success": false, "message": "Missing required fields: code, userId"}),
        );
    }
    if !is_valid_code(&code) {
        return json_response(
            400,
            json!({"success": false, "message": "Invalid entry code format"}),
        );
    }

    let serial = {
        let mut store = app.store.lock().unwrap();
        let serial = store.entry_key(&code).map(|k| k.serial.clone());
        match serial {
            None => None,
            Some(serial) => {
                if store.claim_entry_key(&code, &user_id) {
                    store.set_owner(&serial, &user_id);
                    store
                        .data
                        .users
                        .entry(user_id.clone())
                        .or_insert_with(|| format!("{user_id}@local"));
                    Some(serial)
                } else {
                    None
                }
            }
        }
    };

    let Some(serial) = serial else {
        return json_response(
            200,
            json!({"success": false, "message": "Invalid, expired, or already claimed entry key"}),
        );
    };

    let objects = build_pairing_objects(app, &serial, &user_id);
    app.subs.notify(&serial, objects);

    json_response(
        200,
        json!({"success": true, "serial": serial, "message": format!("Device {serial} registered to {user_id}")}),
    )
}

fn handle_registered_devices(app: &App, req: &Request) -> Response {
    let user_id = req
        .query_get("userId")
        .unwrap_or(&app.cfg.user_id)
        .to_string();
    let store = app.store.lock().unwrap();
    let devices: Vec<Value> = store
        .user_devices(&user_id)
        .into_iter()
        .map(|serial| json!({"serial": serial, "createdAt": now_ms()}))
        .collect();
    json_response(200, Value::Array(devices))
}

fn handle_delete_registered(app: &App, req: &Request) -> Response {
    let serial = req
        .path
        .trim_start_matches("/api/registered-devices/")
        .to_string();
    let mut store = app.store.lock().unwrap();
    store.data.owners.remove(&serial);
    store.dirty = true;
    json_response(200, json!({"success": true, "message": format!("Device {serial} deleted")}))
}

fn handle_ensure_user(app: &App, req: &Request) -> Response {
    let Some(body) = req.json() else {
        return json_response(400, json!({"success": false, "message": "Invalid JSON"}));
    };
    let Some(user_id) = body.get("userId").and_then(|v| v.as_str()) else {
        return json_response(400, json!({"success": false, "message": "Missing userId"}));
    };
    let mut store = app.store.lock().unwrap();
    let created = !store.data.users.contains_key(user_id);
    store
        .data
        .users
        .entry(user_id.to_string())
        .or_insert_with(|| format!("{user_id}@local"));
    store.dirty = true;
    json_response(200, json!({"success": true, "created": created}))
}

fn build_pairing_objects(app: &App, serial: &str, user_id: &str) -> Vec<DeviceObject> {
    let now = now_ms();
    let user_key = format!("user.{user_id}");
    let structure_id = derive_structure_id(user_id);
    let structure_key = format!("structure.{structure_id}");
    let mut store = app.store.lock().unwrap();

    let user_value = match store.get(serial, &user_key) {
        Some(existing) => {
            let mut v = shallow_merge(&existing.value, &json!({"name": user_id}));
            if let Value::Object(m) = &mut v {
                m.insert("name".to_string(), json!(user_id));
            }
            v
        }
        None => json!({"name": user_id}),
    };
    let user_rev = store.get(serial, &user_key).map(|o| o.object_revision + 1).unwrap_or(1);
    let user_obj = DeviceObject::new(user_key, user_rev, now, user_value);
    store.upsert(serial, user_obj.clone());

    let structure_value = match store.get(serial, &structure_key) {
        Some(existing) => {
            let mut devices: Vec<Value> = existing
                .value
                .get("devices")
                .and_then(|d| d.as_array())
                .cloned()
                .unwrap_or_default();
            if !devices.iter().any(|d| d.as_str() == Some(serial)) {
                devices.push(json!(serial));
            }
            let mut v = shallow_merge(&existing.value, &json!({}));
            if let Value::Object(m) = &mut v {
                m.insert("devices".to_string(), Value::Array(devices));
            }
            v
        }
        None => json!({"name": "Home", "devices": [serial]}),
    };
    let struct_rev = store
        .get(serial, &structure_key)
        .map(|o| o.object_revision + 1)
        .unwrap_or(1);
    let struct_obj = DeviceObject::new(structure_key, struct_rev, now, structure_value);
    store.upsert(serial, struct_obj.clone());

    vec![user_obj, struct_obj]
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn handle_command(app: &App, req: &Request) -> Response {
    let Some(body) = req.json() else {
        return json_response(400, json!({"success": false, "message": "Invalid JSON"}));
    };
    let Some(serial) = body.get("serial").and_then(|v| v.as_str()) else {
        return json_response(400, json!({"success": false, "message": "Serial required"}));
    };
    let Some(command) = body.get("command").and_then(|v| v.as_str()) else {
        return json_response(400, json!({"success": false, "message": "Command required"}));
    };
    let value = body.get("value").cloned().unwrap_or(Value::Null);

    match execute_command(app, serial, command, value) {
        Ok(result) => json_response(200, json!({"success": true, "data": result})),
        Err(e) => json_response(400, json!({"success": false, "message": e})),
    }
}

fn execute_command(
    app: &App,
    serial: &str,
    command: &str,
    value: Value,
) -> Result<Value, String> {
    let values = match command {
        "set_temperature" => cmd_set_temperature(app, serial, &value)?,
        "set_mode" => cmd_set_mode(app, serial, &value)?,
        "set_away" => cmd_set_away(&value),
        "set_fan" => cmd_set_fan(app, serial, &value)?,
        "set_eco_temperatures" => cmd_set_eco_temperatures(app, serial, &value)?,
        "set_schedule" => cmd_set_schedule(&value)?,
        "set_schedule_mode" => cmd_set_schedule_mode(&value)?,
        "set_device_setting" => cmd_set_device_setting(&value)?,
        other => return Err(format!("Unknown command: {other}")),
    };

    let key_type = match command {
        "set_temperature" => "shared",
        "set_mode" => "shared",
        "set_schedule_mode" => "shared",
        "set_away" => "structure",
        "set_schedule" => "schedule",
        _ => "device",
    };

    let object_key = match key_type {
        "structure" => {
            let structure_id = app
                .resolve_user(serial)
                .map(|u| derive_structure_id(&u))
                .unwrap_or_else(|| "default".to_string());
            format!("structure.{structure_id}")
        }
        "schedule" => format!("schedule.{serial}"),
        "shared" => format!("shared.{serial}"),
        _ => format!("device.{serial}"),
    };

    let updated = {
        let mut store = app.store.lock().unwrap();
        let base_rev = store
            .get(serial, &object_key)
            .map(|o| o.object_revision)
            .unwrap_or(0);
        let new_rev = base_rev + 1;
        if key_type == "schedule" {
            let obj = DeviceObject::new(object_key.clone(), new_rev, now_ms(), values.clone());
            store.upsert(serial, obj.clone());
            obj
        } else {
            store.merge_values(serial, &object_key, values.clone(), new_rev, now_ms())
        }
    };

    app.subs.notify(serial, vec![updated]);

    Ok(json!({"object_key": object_key, "values": values}))
}

fn get_number(v: &Value) -> Option<f64> {
    v.as_f64().or_else(|| v.as_i64().map(|i| i as f64))
}

fn cmd_set_temperature(app: &App, serial: &str, value: &Value) -> Result<Value, String> {
    let (dv, sv) = {
        let store = app.store.lock().unwrap();
        (
            store
                .get(serial, &format!("device.{serial}"))
                .map(|o| o.value.clone())
                .unwrap_or_else(|| json!({})),
            store
                .get(serial, &format!("shared.{serial}"))
                .map(|o| o.value.clone())
                .unwrap_or_else(|| json!({})),
        )
    };
    let (min, max) = safety_bounds(&dv, &sv);

    let mut values = Map::new();
    if let Some(obj) = value.as_object() {
        if let Some(high) = obj.get("high").and_then(get_number) {
            values.insert("target_temperature_high".into(), json!(high.clamp(min, max)));
        }
        if let Some(low) = obj.get("low").and_then(get_number) {
            values.insert("target_temperature_low".into(), json!(low.clamp(min, max)));
        }
    } else if let Some(t) = get_number(value) {
        values.insert("target_temperature".into(), json!(t.clamp(min, max)));
    } else {
        return Err("set_temperature value must be a number or {high, low}".into());
    }
    values.insert("target_change_pending".into(), json!(true));
    Ok(Value::Object(values))
}

fn safety_bounds(dv: &Value, sv: &Value) -> (f64, f64) {
    let mut min = 7.222;
    let mut max = 35.0;
    if let Some(v) = dv.get("safety_temp_min").and_then(get_number) {
        min = v;
    }
    if let Some(v) = dv.get("safety_temp_max").and_then(get_number) {
        max = v;
    }
    if let Some(v) = sv.get("safety_temp_min").and_then(get_number) {
        min = v;
    }
    if let Some(v) = sv.get("safety_temp_max").and_then(get_number) {
        max = v;
    }
    (min, max)
}

fn cmd_set_mode(app: &App, serial: &str, value: &Value) -> Result<Value, String> {
    let mode = value.as_str().unwrap_or("").to_lowercase();
    if mode == "eco" {
        return Err("Use set_away to control eco mode".into());
    }
    let target = match mode.as_str() {
        "off" => "off",
        "heat" => "heat",
        "cool" => "cool",
        "heat-cool" | "range" | "auto" => "range",
        "emergency" => "emergency",
        other => return Err(format!("Unknown mode '{other}'")),
    };
    let (dv, sv) = {
        let store = app.store.lock().unwrap();
        (
            store
                .get(serial, &format!("device.{serial}"))
                .map(|o| o.value.clone())
                .unwrap_or_else(|| json!({})),
            store
                .get(serial, &format!("shared.{serial}"))
                .map(|o| o.value.clone())
                .unwrap_or_else(|| json!({})),
        )
    };
    let can_heat = sv
        .get("can_heat")
        .or_else(|| dv.get("can_heat"))
        .and_then(|v| v.as_bool())
        .unwrap_or(true);
    let can_cool = sv
        .get("can_cool")
        .or_else(|| dv.get("can_cool"))
        .and_then(|v| v.as_bool())
        .unwrap_or(true);
    let has_emer = sv
        .get("has_emer_heat")
        .or_else(|| dv.get("has_emer_heat"))
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    if target == "heat" && !can_heat {
        return Err("Device does not support heating".into());
    }
    if target == "cool" && !can_cool {
        return Err("Device does not support cooling".into());
    }
    if target == "range" && !(can_heat && can_cool) {
        return Err("Range mode requires heating and cooling capability".into());
    }
    if target == "emergency" && !has_emer {
        return Err("Device does not have emergency heat".into());
    }
    Ok(json!({"target_temperature_type": target}))
}

fn cmd_set_away(value: &Value) -> Value {
    let away = value.as_bool().unwrap_or(false);
    json!({"manual_eco_all": away, "manual_eco_timestamp": now_secs()})
}

fn cmd_set_fan(app: &App, serial: &str, value: &Value) -> Result<Value, String> {
    let (dv, sv) = {
        let store = app.store.lock().unwrap();
        (
            store
                .get(serial, &format!("device.{serial}"))
                .map(|o| o.value.clone())
                .unwrap_or_else(|| json!({})),
            store
                .get(serial, &format!("shared.{serial}"))
                .map(|o| o.value.clone())
                .unwrap_or_else(|| json!({})),
        )
    };
    let has_fan = sv
        .get("has_fan")
        .or_else(|| dv.get("has_fan"))
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    if !has_fan {
        return Err("Device does not have a fan".into());
    }
    if let Some(s) = value.as_str() {
        match s.to_lowercase().as_str() {
            "on" => {
                let minutes = dv
                    .get("fan_timer_duration_minutes")
                    .and_then(|v| v.as_i64())
                    .unwrap_or(60);
                return Ok(json!({"fan_timer_timeout": now_secs() + minutes * 60}));
            }
            "auto" => return Ok(json!({"fan_timer_timeout": 0})),
            _ => return Ok(json!({})),
        }
    }
    if let Some(secs) = get_number(value) {
        return Ok(json!({"fan_timer_timeout": now_secs() + secs as i64}));
    }
    Ok(json!({}))
}

fn cmd_set_eco_temperatures(app: &App, serial: &str, value: &Value) -> Result<Value, String> {
    let Some(obj) = value.as_object() else {
        return Err("set_eco_temperatures value must be an object".into());
    };
    let (dv, sv) = {
        let store = app.store.lock().unwrap();
        (
            store
                .get(serial, &format!("device.{serial}"))
                .map(|o| o.value.clone())
                .unwrap_or_else(|| json!({})),
            store
                .get(serial, &format!("shared.{serial}"))
                .map(|o| o.value.clone())
                .unwrap_or_else(|| json!({})),
        )
    };
    let (min, max) = safety_bounds(&dv, &sv);
    let mut values = Map::new();
    if let Some(high) = obj.get("high").and_then(get_number) {
        values.insert("away_temperature_high".into(), json!(high.clamp(min, max)));
    }
    if let Some(low) = obj.get("low").and_then(get_number) {
        values.insert("away_temperature_low".into(), json!(low.clamp(min, max)));
    }
    Ok(Value::Object(values))
}

fn cmd_set_schedule(value: &Value) -> Result<Value, String> {
    let Some(obj) = value.as_object() else {
        return Err("Schedule must be a JSON object".into());
    };
    if obj.get("ver").and_then(|v| v.as_i64()) != Some(2) {
        return Err("Schedule ver must be 2".into());
    }
    let mode = obj
        .get("schedule_mode")
        .or_else(|| obj.get("mode"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_uppercase();
    if !matches!(mode.as_str(), "HEAT" | "COOL" | "RANGE") {
        return Err("schedule_mode must be HEAT, COOL or RANGE".into());
    }
    let Some(days) = obj.get("days").and_then(|v| v.as_object()) else {
        return Err("Schedule must contain a 'days' object".into());
    };

    let mut checked = Map::new();
    for (day_key, day) in days {
        if !matches!(day_key.as_str(), "0" | "1" | "2" | "3" | "4" | "5" | "6") {
            return Err(format!(
                "Invalid day key '{day_key}' (must be '0'-'6', Monday-Sunday)"
            ));
        }
        // The device writes each day as a dict keyed by position; the SPA and
        // upstream's dashboard use arrays. Accept both, validate every entry.
        let entries: Vec<&Value> = match day {
            Value::Array(items) => items.iter().collect(),
            Value::Object(by_index) => {
                let mut ordered: Vec<(&String, &Value)> = by_index.iter().collect();
                ordered.sort_by_key(|(k, _)| k.parse::<usize>().unwrap_or(usize::MAX));
                ordered.into_iter().map(|(_, v)| v).collect()
            }
            _ => return Err(format!("Day '{day_key}' must be a list or dict of setpoints")),
        };
        for (i, entry) in entries.iter().enumerate() {
            validate_setpoint(day_key, i, entry)?;
        }
        checked.insert(day_key.clone(), day.clone());
    }

    // Anything else the bucket carried is passed straight through. Upstream's
    // `validate_schedule` rebuilds the top level from scratch and so silently
    // drops `schedule_algorithm`, `preconditioning`, `created_at`, …; we keep
    // them because nlclient is the consumer of this bucket and may key off
    // fields we have never seen (see the schedule notes in README.md).
    let mut out = obj.clone();
    out.insert("ver".into(), json!(2));
    out.insert(
        "name".into(),
        obj.get("name").cloned().unwrap_or_else(|| json!("")),
    );
    out.insert("schedule_mode".into(), json!(mode));
    out.insert("days".into(), Value::Object(checked));
    Ok(Value::Object(out))
}

/// Mirror of upstream's per-entry checks (`command.py:295-323`), plus the
/// device's `entry_type: "continuation"` marker, which carries no temperature.
fn validate_setpoint(day_key: &str, index: usize, entry: &Value) -> Result<(), String> {
    let where_ = format!("Day '{day_key}' entry {index}");
    let obj = entry
        .as_object()
        .ok_or_else(|| format!("{where_}: must be an object"))?;

    let time = obj
        .get("time")
        .and_then(get_number)
        .ok_or_else(|| format!("{where_}: missing 'time'"))?;
    if !(0.0..86400.0).contains(&time) {
        return Err(format!("{where_}: time must be 0-86399"));
    }
    if obj.get("entry_type").and_then(|v| v.as_str()) == Some("continuation") {
        return Ok(());
    }
    let ty = obj
        .get("type")
        .and_then(|v| v.as_str())
        .map(|s| s.to_uppercase())
        .ok_or_else(|| format!("{where_}: missing 'type'"))?;
    if !matches!(ty.as_str(), "HEAT" | "COOL" | "RANGE") {
        return Err(format!("{where_}: invalid type '{ty}'"));
    }
    if ty == "RANGE" {
        for key in ["temp-min", "temp-max"] {
            let temp = obj
                .get(key)
                .and_then(get_number)
                .ok_or_else(|| format!("{where_}: RANGE requires '{key}'"))?;
            if !(TEMP_MIN_C..=TEMP_MAX_C).contains(&temp) {
                return Err(format!(
                    "{where_}: {key}={temp} outside {TEMP_MIN_C}-{TEMP_MAX_C}C"
                ));
            }
        }
    } else if let Some(temp) = obj.get("temp").and_then(get_number) {
        if !(TEMP_MIN_C..=TEMP_MAX_C).contains(&temp) {
            return Err(format!(
                "{where_}: temp={temp} outside {TEMP_MIN_C}-{TEMP_MAX_C}C"
            ));
        }
    }
    Ok(())
}

fn cmd_set_schedule_mode(value: &Value) -> Result<Value, String> {
    let mode = value.as_str().unwrap_or("").to_uppercase();
    if !matches!(mode.as_str(), "HEAT" | "COOL" | "RANGE") {
        return Err("schedule_mode must be HEAT, COOL or RANGE".into());
    }
    Ok(json!({"schedule_mode": mode}))
}

fn cmd_set_device_setting(value: &Value) -> Result<Value, String> {
    let Some(obj) = value.as_object() else {
        return Err("set_device_setting value must be an object".into());
    };
    let rejected: Vec<&str> = obj
        .keys()
        .filter(|k| !DEVICE_SETTING_WHITELIST.contains(&k.as_str()))
        .map(|k| k.as_str())
        .collect();
    if !rejected.is_empty() {
        return Err(format!("Fields not cloud-writable: {}", rejected.join(", ")));
    }
    Ok(Value::Object(obj.clone()))
}

/// Keep `sanitize_serial` referenced for control-path validation helpers.
#[allow(dead_code)]
fn _valid_serial(s: &str) -> Option<String> {
    sanitize_serial(s)
}
