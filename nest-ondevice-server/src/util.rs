//! Small self-contained helpers: clock, base64, serial parsing, percent-decoding.

use std::time::{SystemTime, UNIX_EPOCH};

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Decode standard base64 (with or without padding). Returns None on bad input.
pub fn b64_decode(input: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a') as u32 + 26),
            b'0'..=b'9' => Some((c - b'0') as u32 + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity(input.len() / 4 * 3);
    let mut buf: u32 = 0;
    let mut bits: u32 = 0;
    for &b in input.as_bytes() {
        if b == b'=' || b == b'\n' || b == b'\r' {
            continue;
        }
        let v = val(b)?;
        buf = (buf << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buf >> bits) & 0xff) as u8);
        }
    }
    Some(out)
}

/// Nest serials are uppercase alphanumeric and at least 10 chars.
pub fn sanitize_serial(s: &str) -> Option<String> {
    let cleaned: String = s
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect::<String>()
        .to_uppercase();
    if cleaned.len() >= 10 {
        Some(cleaned)
    } else {
        None
    }
}

/// Extract the serial from a Basic-Auth username. Accepts `nest.SERIAL`,
/// `d.SERIAL.rand` and bare `SERIAL`.
pub fn serial_from_basic(auth_header: &str) -> Option<String> {
    let encoded = auth_header.strip_prefix("Basic ")?;
    let decoded = b64_decode(encoded.trim())?;
    let decoded = String::from_utf8(decoded).ok()?;
    let user = decoded.split(':').next()?;
    let serial = match user.split_once('.') {
        Some((_, rest)) if !rest.is_empty() => rest,
        _ => user,
    };
    sanitize_serial(serial)
}

pub fn basic_auth_password(auth_header: &str) -> Option<String> {
    let encoded = auth_header.strip_prefix("Basic ")?;
    let decoded = b64_decode(encoded.trim())?;
    let decoded = String::from_utf8(decoded).ok()?;
    decoded.split_once(':').map(|(_, p)| p.to_string())
}

/// `d.{SERIAL}.{random}` used by the device when it has DEFAULT credentials.
pub fn serial_from_client_id(client_id: &str) -> Option<String> {
    match client_id.split_once('.') {
        Some((_, rest)) if !rest.is_empty() => {
            let serial = rest.split('.').next().unwrap_or(rest);
            sanitize_serial(serial)
        }
        _ => sanitize_serial(client_id),
    }
}

/// Percent-decode a query-string component (`+` becomes space).
pub fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                let hi = hex_val(bytes[i + 1]);
                let lo = hex_val(bytes[i + 2]);
                if let (Some(h), Some(l)) = (hi, lo) {
                    out.push((h << 4) | l);
                    i += 3;
                    continue;
                }
                out.push(b'%');
                i += 1;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Mirrors `derive_structure_id`: strips a leading `user_`.
pub fn derive_structure_id(user_id: &str) -> String {
    user_id.strip_prefix("user_").unwrap_or(user_id).to_string()
}

/// Deep-ish JSON merge used by the schedule replace path. Kept shallow to match
/// the reference server (top-level object merge).
pub fn shallow_merge(base: &serde_json::Value, delta: &serde_json::Value) -> serde_json::Value {
    match (base, delta) {
        (serde_json::Value::Object(a), serde_json::Value::Object(b)) => {
            let mut out = a.clone();
            for (k, v) in b {
                out.insert(k.clone(), v.clone());
            }
            serde_json::Value::Object(out)
        }
        _ => delta.clone(),
    }
}
