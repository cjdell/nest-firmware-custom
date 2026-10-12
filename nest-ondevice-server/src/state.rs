//! Bucket store with the same revision/timestamp merge semantics as the
//! reference Python server, plus simple JSON-file persistence.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::util::{now_ms, shallow_merge};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeviceObject {
    pub object_key: String,
    pub object_revision: i64,
    pub object_timestamp: i64,
    pub value: Value,
}

impl DeviceObject {
    pub fn new(object_key: String, object_revision: i64, object_timestamp: i64, value: Value) -> Self {
        DeviceObject {
            object_key,
            object_revision,
            object_timestamp,
            value,
        }
    }

    /// Serialize in the wire order the device requires: revision, timestamp,
    /// key, then value.
    pub fn response_json(&self, include_value: bool) -> String {
        let key = serde_json::to_string(&self.object_key).unwrap_or_else(|_| "\"\"".into());
        if include_value {
            let value = serde_json::to_string(&self.value).unwrap_or_else(|_| "null".into());
            format!(
                "{{\"object_revision\":{},\"object_timestamp\":{},\"object_key\":{},\"value\":{}}}",
                self.object_revision, self.object_timestamp, key, value
            )
        } else {
            format!(
                "{{\"object_revision\":{},\"object_timestamp\":{},\"object_key\":{}}}",
                self.object_revision, self.object_timestamp, key
            )
        }
    }
}

/// Format a list of objects as `{"objects":[...]}` with values included.
pub fn objects_body(objs: &[DeviceObject]) -> String {
    let mut out = String::from("{\"objects\":[");
    for (i, o) in objs.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&o.response_json(true));
    }
    out.push_str("]}");
    out
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EntryKey {
    pub code: String,
    pub serial: String,
    pub created_at_ms: i64,
    pub expires_at_ms: i64,
    pub claimed_by: Option<String>,
    pub claimed_at_ms: Option<i64>,
}

#[derive(Default, Serialize, Deserialize)]
pub struct Persist {
    /// serial -> object_key -> object
    pub objects: HashMap<String, HashMap<String, DeviceObject>>,
    /// serial -> user id
    pub owners: HashMap<String, String>,
    /// entry code -> entry key
    pub entry_keys: HashMap<String, EntryKey>,
    /// user id -> email
    pub users: HashMap<String, String>,
    /// serial -> captured Basic-Auth api_key
    pub api_keys: HashMap<String, String>,
}

pub struct Store {
    pub data: Persist,
    pub dirty: bool,
    path: PathBuf,
}

impl Store {
    pub fn load(data_dir: &Path) -> Store {
        let path = data_dir.join("state.json");
        let data = fs::read(&path)
            .ok()
            .and_then(|b| serde_json::from_slice::<Persist>(&b).ok())
            .unwrap_or_default();
        Store {
            data,
            dirty: false,
            path,
        }
    }

    pub fn persist_if_dirty(&mut self) {
        if !self.dirty {
            return;
        }
        if let Some(parent) = self.path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        if let Ok(bytes) = serde_json::to_vec(&self.data) {
            let tmp = self.path.with_extension("json.tmp");
            if fs::write(&tmp, bytes).is_ok() {
                let _ = fs::rename(&tmp, &self.path);
                self.dirty = false;
            }
        }
    }

    pub fn get(&self, serial: &str, key: &str) -> Option<&DeviceObject> {
        self.data.objects.get(serial).and_then(|m| m.get(key))
    }

    pub fn objects_by_serial(&self, serial: &str) -> Vec<DeviceObject> {
        self.data
            .objects
            .get(serial)
            .map(|m| m.values().cloned().collect())
            .unwrap_or_default()
    }

    pub fn all_serials(&self) -> Vec<String> {
        self.data.objects.keys().cloned().collect()
    }

    pub fn upsert(&mut self, serial: &str, obj: DeviceObject) {
        self.data
            .objects
            .entry(serial.to_string())
            .or_default()
            .insert(obj.object_key.clone(), obj);
        self.dirty = true;
    }

    /// Merge `values` into an existing bucket (creating it when absent).
    pub fn merge_values(
        &mut self,
        serial: &str,
        key: &str,
        values: Value,
        revision: i64,
        timestamp: i64,
    ) -> DeviceObject {
        let merged = match self.get(serial, key) {
            Some(existing) => shallow_merge(&existing.value, &values),
            None => values,
        };
        let obj = DeviceObject::new(key.to_string(), revision, timestamp, merged);
        self.upsert(serial, obj.clone());
        obj
    }

    pub fn delete_device(&mut self, serial: &str) -> usize {
        let n = self.data.objects.remove(serial).map(|m| m.len()).unwrap_or(0);
        self.data.owners.remove(serial);
        if n > 0 {
            self.dirty = true;
        }
        n
    }

    pub fn owner(&self, serial: &str) -> Option<&str> {
        self.data.owners.get(serial).map(|s| s.as_str())
    }

    pub fn set_owner(&mut self, serial: &str, user_id: &str) {
        self.data
            .owners
            .insert(serial.to_string(), user_id.to_string());
        self.dirty = true;
    }

    pub fn user_devices(&self, user_id: &str) -> Vec<String> {
        self.data
            .owners
            .iter()
            .filter(|(_, u)| u.as_str() == user_id)
            .map(|(s, _)| s.clone())
            .collect()
    }

    pub fn api_key(&self, serial: &str) -> Option<&str> {
        self.data.api_keys.get(serial).map(|s| s.as_str())
    }

    pub fn set_api_key(&mut self, serial: &str, key: &str) {
        self.data.api_keys.insert(serial.to_string(), key.to_string());
        self.dirty = true;
    }

    /// Return an existing unexpired, unclaimed key for the serial if present.
    pub fn active_entry_key(&self, serial: &str) -> Option<&EntryKey> {
        let now = now_ms();
        self.data
            .entry_keys
            .values()
            .filter(|k| k.serial == serial && k.claimed_by.is_none() && k.expires_at_ms > now)
            .max_by_key(|k| k.created_at_ms)
    }

    pub fn latest_entry_key(&self, serial: &str) -> Option<&EntryKey> {
        self.data
            .entry_keys
            .values()
            .filter(|k| k.serial == serial)
            .max_by_key(|k| k.created_at_ms)
    }

    pub fn entry_key(&self, code: &str) -> Option<&EntryKey> {
        self.data.entry_keys.get(code)
    }

    pub fn generate_entry_key(&mut self, serial: &str, ttl_seconds: u64) -> EntryKey {
        // Invalidate previous keys for this serial (matches reference behaviour).
        self.data.entry_keys.retain(|_, k| k.serial != serial);
        let now = now_ms();
        let mut code = String::new();
        for _ in 0..32 {
            let candidate = fresh_code();
            if !self.data.entry_keys.contains_key(&candidate) {
                code = candidate;
                break;
            }
        }
        let key = EntryKey {
            code: code.clone(),
            serial: serial.to_string(),
            created_at_ms: now,
            expires_at_ms: now + (ttl_seconds as i64 * 1000),
            claimed_by: None,
            claimed_at_ms: None,
        };
        self.data.entry_keys.insert(code, key.clone());
        self.dirty = true;
        key
    }

    pub fn claim_entry_key(&mut self, code: &str, user_id: &str) -> bool {
        let now = now_ms();
        match self.data.entry_keys.get_mut(code) {
            Some(k)
                if k.claimed_by.is_none() && k.expires_at_ms > now =>
            {
                k.claimed_by = Some(user_id.to_string());
                k.claimed_at_ms = Some(now);
                self.dirty = true;
                true
            }
            _ => false,
        }
    }
}

fn fresh_code() -> String {
    // 3 digits + 4 uppercase letters, matching the device's expected format.
    use std::time::{SystemTime, UNIX_EPOCH};
    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos() as u64 ^ d.as_secs())
        .unwrap_or(0);
    let mut x = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    let mut next = || {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x
    };
    let digits = b"0123456789";
    let letters = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let mut s = String::with_capacity(7);
    for _ in 0..3 {
        s.push(digits[(next() % 10) as usize] as char);
    }
    for _ in 0..4 {
        s.push(letters[(next() % 26) as usize] as char);
    }
    s
}
