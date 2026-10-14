mod config;
mod control;
mod debug;
mod http;
mod nest;
mod server;
mod state;
mod subs;
mod ui;
mod util;

use std::collections::{HashMap, HashSet};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use config::Config;
use state::Store;
use subs::Subs;
use util::{now_ms, sanitize_serial};

pub struct Avail {
    pub last_seen_ms: i64,
    pub available: bool,
}

pub struct App {
    pub cfg: Config,
    pub store: Mutex<Store>,
    pub subs: Subs,
    pub avail: Mutex<HashMap<String, Avail>>,
    /// Serials that have been sent the structure bucket this session. On first
    /// contact we force-push structure even if timestamps match, because the
    /// device's in-memory mode may have reset across a reboot.
    pub structure_sent: Mutex<HashSet<String>>,
    pub started_ms: i64,
    /// Ring-buffered logs/traces and the `/debug/*` surface.
    pub debug: debug::Debug,
}

impl App {
    pub fn new(cfg: Config) -> App {
        let store = Store::load(&cfg.data_dir);
        let debug = debug::Debug::new(&cfg);
        App {
            cfg,
            store: Mutex::new(store),
            subs: Subs::default(),
            avail: Mutex::new(HashMap::new()),
            structure_sent: Mutex::new(HashSet::new()),
            started_ms: now_ms(),
            debug,
        }
    }

    pub fn mark_seen(&self, serial: &str) {
        let mut a = self.avail.lock().unwrap();
        let entry = a.entry(serial.to_string()).or_insert(Avail {
            last_seen_ms: now_ms(),
            available: true,
        });
        entry.last_seen_ms = now_ms();
        entry.available = true;
    }

    pub fn is_available(&self, serial: &str) -> bool {
        self.avail
            .lock()
            .unwrap()
            .get(serial)
            .map(|s| s.available)
            .unwrap_or(false)
    }

    pub fn last_seen(&self, serial: &str) -> Option<i64> {
        self.avail.lock().unwrap().get(serial).map(|s| s.last_seen_ms)
    }

    pub fn remember_api_key(&self, serial: &str, key: &str) {
        if key.is_empty() {
            return;
        }
        let mut store = self.store.lock().unwrap();
        if store.api_key(serial) != Some(key) {
            store.set_api_key(serial, key);
        }
    }

    /// Resolve the owning user for a serial. When pairing is not required, the
    /// device is auto-claimed by the configured local user so that a
    /// factory-reset thermostat completes pairing without a separate server.
    pub fn resolve_user(&self, serial: &str) -> Option<String> {
        let mut store = self.store.lock().unwrap();
        if let Some(owner) = store.owner(serial) {
            return Some(owner.to_string());
        }
        if self.cfg.require_device_pairing {
            return None;
        }
        let user_id = self.cfg.user_id.clone();
        store.set_owner(serial, &user_id);
        store
            .data
            .users
            .entry(user_id.clone())
            .or_insert_with(|| format!("{user_id}@local"));
        Some(user_id)
    }
}

pub fn valid_serial(s: &str) -> Option<String> {
    sanitize_serial(s)
}

fn main() {
    let cfg = Config::from_env();
    println!(
        "nest-ondevice starting: device_port={} control_port={} origin={} hold={}s pairing={}",
        cfg.device_port,
        cfg.control_port,
        cfg.origin_with_port,
        cfg.connection_hold_timeout,
        cfg.require_device_pairing
    );

    let _ = std::fs::create_dir_all(&cfg.data_dir);

    let app = Arc::new(App::new(cfg.clone()));
    app.debug.log(
        2,
        format!(
            "nest-ondevice {} starting: device_port={} control_port={} data_dir={} debug={}",
            env!("CARGO_PKG_VERSION"),
            cfg.device_port,
            cfg.control_port,
            cfg.data_dir.display(),
            if cfg.debug_enabled { "on" } else { "off" }
        ),
    );

    // Periodic, debounced persistence to keep NAND writes low.
    {
        let app = app.clone();
        thread::Builder::new()
            .stack_size(128 * 1024)
            .spawn(move || loop {
                thread::sleep(Duration::from_secs(15));
                let mut store = app.store.lock().unwrap();
                store.persist_if_dirty();
            })
            .expect("spawn persistence thread");
    }

    let mut ports = vec![cfg.device_port];
    if cfg.control_port != cfg.device_port {
        ports.push(cfg.control_port);
    }

    let mut handles = Vec::new();
    for port in ports {
        let app = app.clone();
        let addr = format!("{}:{}", cfg.host, port);
        let listener = match TcpListener::bind(&addr) {
            Ok(l) => l,
            Err(e) => {
                eprintln!("failed to bind {addr}: {e}");
                app.debug.error(format!("failed to bind {addr}: {e}"));
                continue;
            }
        };
        println!("listening on {addr}");
        app.debug.log(2, format!("listening on {addr}"));
        handles.push(
            thread::Builder::new()
                .stack_size(256 * 1024)
                .spawn(move || server::serve(app, listener))
                .expect("spawn listener thread"),
        );
    }

    for h in handles {
        let _ = h.join();
    }
}
