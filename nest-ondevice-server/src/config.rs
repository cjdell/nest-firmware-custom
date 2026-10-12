//! Runtime configuration. Values come from the environment so the same binary
//! works on a workstation and on the Nest rootfs (where it is started by an
//! `/etc/init.d` script).

use std::env;
use std::path::PathBuf;

#[derive(Clone)]
pub struct Config {
    /// Public origin used for URLs handed back to the thermostat.
    pub api_origin: String,
    /// `api_origin` with an explicit port (the device parses the port for WoWLAN).
    pub origin_with_port: String,
    pub host: String,
    pub device_port: u16,
    pub control_port: u16,
    pub suspend_time_max: u64,
    pub defer_device_window: u64,
    pub disable_defer_window: u64,
    pub connection_hold_timeout: u64,
    pub require_device_pairing: bool,
    pub entry_key_ttl_seconds: u64,
    pub data_dir: PathBuf,
    pub user_id: String,
    pub store_device_logs: bool,
    pub weather_cache_ttl: u64,
    /// Observability knobs for the `/debug/*` surface. See `debug.rs`.
    pub debug_enabled: bool,
    pub debug_token: Option<String>,
    pub debug_log_file: Option<PathBuf>,
    pub log_level: u8,
}

impl Config {
    pub fn from_env() -> Config {
        let device_port = env_num("SERVER_PORT", 8000) as u16;
        let control_port = env_num("CONTROL_PORT", 8082) as u16;
        let host = env::var("SERVER_HOST").unwrap_or_else(|_| "0.0.0.0".to_string());
        let api_origin = env::var("API_ORIGIN")
            .unwrap_or_else(|_| format!("http://127.0.0.1:{}", device_port));
        let origin_with_port = ensure_port(&api_origin, device_port);

        let suspend_time_max = env_num("SUSPEND_TIME_MAX", 300).clamp(5, 350);
        let connection_hold_timeout = suspend_time_max.saturating_sub(10).max(1);

        Config {
            api_origin,
            origin_with_port,
            host,
            device_port,
            control_port,
            suspend_time_max,
            defer_device_window: env_num("DEFER_DEVICE_WINDOW", 15),
            disable_defer_window: env_num("DISABLE_DEFER_WINDOW", 60),
            connection_hold_timeout,
            require_device_pairing: env_bool("REQUIRE_DEVICE_PAIRING", false),
            entry_key_ttl_seconds: env_num("ENTRY_KEY_TTL_SECONDS", 3600),
            data_dir: PathBuf::from(
                env::var("DATA_DIR").unwrap_or_else(|_| "./data".to_string()),
            ),
            user_id: env::var("USER_ID").unwrap_or_else(|_| "homeassistant".to_string()),
            store_device_logs: env_bool("STORE_DEVICE_LOGS", false),
            weather_cache_ttl: env_num("WEATHER_CACHE_TTL_MS", 600_000) / 1000,
            debug_enabled: env_bool("DEBUG_ENABLED", true),
            debug_token: env::var("DEBUG_TOKEN").ok().filter(|s| !s.is_empty()),
            debug_log_file: env::var("DEBUG_LOG_FILE").ok().filter(|s| !s.is_empty()).map(PathBuf::from),
            log_level: env_num("LOG_LEVEL", 2).min(3) as u8,
        }
    }
}

fn env_num(key: &str, default: u64) -> u64 {
    env::var(key)
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(default)
}

fn env_bool(key: &str, default: bool) -> bool {
    match env::var(key) {
        Ok(v) => matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"),
        Err(_) => default,
    }
}

/// Insert an explicit port into a URL authority if one is not already present.
fn ensure_port(origin: &str, port: u16) -> String {
    let Some(scheme_end) = origin.find("://") else {
        return origin.to_string();
    };
    let auth_start = scheme_end + 3;
    let auth_end = origin[auth_start..]
        .find('/')
        .map(|i| auth_start + i)
        .unwrap_or(origin.len());
    let authority = &origin[auth_start..auth_end];
    // Already has a port (ignore IPv6 brackets for simplicity).
    if authority.contains(':') {
        return origin.to_string();
    }
    format!(
        "{}{}:{}{}",
        &origin[..auth_start],
        authority,
        port,
        &origin[auth_end..]
    )
}
