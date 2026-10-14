//! Serve the embedded schedule SPA (see `ui/`, `build.rs`).
//!
//! Three byte blobs compiled into the binary — no filesystem, no directory to
//! create on the flash root, nothing to keep in sync at runtime. Registered
//! *after* the Nest protocol and control routes, so it can only ever answer
//! paths those two left alone (`/`, `/index.js`, `/app.css`).

use crate::http::{Request, Response};

mod assets {
    include!(concat!(env!("OUT_DIR"), "/ui_assets.rs"));
}

pub struct Asset {
    pub body: &'static [u8],
    pub content_type: &'static str,
}

const NOT_BUILT: &str = "<!doctype html><meta charset=utf-8>\
<title>Nest schedule — UI not built</title>\
<p>The schedule editor is not embedded in this binary.</p>\
<p>Build it with <code>./build ui</code> (Bun), then rebuild the server; \
<code>nest-ondevice-server/ui/dist/</code> is embedded at compile time.</p>";

pub fn route(req: &Request) -> Option<Response> {
    if req.method != "GET" {
        return None;
    }
    let asset = match req.path.as_str() {
        "/" | "/ui" | "/ui/" | "/index.html" => {
            if !assets::PRESENT {
                let mut resp = Response::new(200, NOT_BUILT.as_bytes().to_vec());
                resp.headers.push(("Content-Type".into(), "text/html; charset=utf-8".into()));
                return Some(resp);
            }
            &assets::INDEX_HTML
        }
        "/index.js" if assets::PRESENT => &assets::APP_JS,
        "/app.css" if assets::PRESENT => &assets::APP_CSS,
        _ => return None,
    };

    let mut resp = Response::new(200, asset.body.to_vec());
    resp.headers
        .push(("Content-Type".into(), asset.content_type.to_string()));
    // The bundle is embedded, so its bytes change exactly when the binary does:
    // revalidation is cheap and a stale editor is not worth a cache entry.
    resp.headers
        .push(("Cache-Control".into(), "no-cache".into()));
    resp.headers
        .push(("X-Content-Type-Options".into(), "nosniff".into()));
    Some(resp)
}
