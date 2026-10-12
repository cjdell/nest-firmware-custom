//! Long-poll subscription registry.
//!
//! Each held HTTP connection owns a `Receiver`; the server holds the matching
//! `Sender` here. When a command changes a bucket, `notify` pushes the change to
//! every live connection for that serial.

use std::collections::HashMap;
use std::sync::mpsc::Sender;
use std::sync::Mutex;

use crate::state::DeviceObject;

struct Subscription {
    id: u64,
    tx: Sender<Vec<DeviceObject>>,
}

#[derive(Default)]
struct Inner {
    next_id: u64,
    by_serial: HashMap<String, Vec<Subscription>>,
    /// Objects that could not be delivered because the connection was gone.
    pending: HashMap<String, Vec<DeviceObject>>,
}

#[derive(Default)]
pub struct Subs {
    inner: Mutex<Inner>,
}

impl Subs {
    /// Register a held connection. Returns its id and any objects buffered from
    /// a previous broken connection (to be replayed immediately).
    pub fn add(&self, serial: &str, tx: Sender<Vec<DeviceObject>>) -> (u64, Option<Vec<DeviceObject>>) {
        let mut g = self.inner.lock().unwrap();
        g.next_id += 1;
        let id = g.next_id;
        g.by_serial
            .entry(serial.to_string())
            .or_default()
            .push(Subscription { id, tx });
        let pending = g.pending.remove(serial);
        (id, pending)
    }

    pub fn remove(&self, serial: &str, id: u64) {
        let mut g = self.inner.lock().unwrap();
        if let Some(v) = g.by_serial.get_mut(serial) {
            v.retain(|s| s.id != id);
            if v.is_empty() {
                g.by_serial.remove(serial);
            }
        }
    }

    /// Push changed objects to all held connections. Buffers them for replay if
    /// any delivery failed.
    pub fn notify(&self, serial: &str, objs: Vec<DeviceObject>) -> usize {
        let mut g = self.inner.lock().unwrap();
        let mut failed = false;
        let mut count = 0usize;
        if let Some(v) = g.by_serial.get_mut(serial) {
            v.retain(|s| match s.tx.send(objs.clone()) {
                Ok(_) => {
                    count += 1;
                    true
                }
                Err(_) => {
                    failed = true;
                    false
                }
            });
            if v.is_empty() {
                g.by_serial.remove(serial);
            }
        }
        if failed {
            g.pending.entry(serial.to_string()).or_default().extend(objs);
        }
        count
    }

    pub fn count(&self, serial: &str) -> usize {
        self.inner
            .lock()
            .unwrap()
            .by_serial
            .get(serial)
            .map(|v| v.len())
            .unwrap_or(0)
    }

    pub fn total(&self) -> usize {
        self.inner
            .lock()
            .unwrap()
            .by_serial
            .values()
            .map(|v| v.len())
            .sum()
    }
}
