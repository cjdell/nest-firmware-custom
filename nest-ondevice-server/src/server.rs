//! Thread-per-connection server. Connections are cheap (small stacks, few of
//! them) and this keeps the long-poll hold logic trivial and memory-safe.

use std::io::{self, BufReader};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use crate::debug::Trace;
use crate::http;
use crate::nest::{self, SubscribeOutcome};
use crate::{control, util, App};

pub fn serve(app: Arc<App>, listener: TcpListener) {
    for conn in listener.incoming() {
        match conn {
            Ok(stream) => {
                let app = app.clone();
                let _ = thread::Builder::new()
                    .stack_size(512 * 1024)
                    .spawn(move || {
                        let _ = handle_conn(stream, app);
                    });
            }
            Err(_) => continue,
        }
    }
}

fn handle_conn(mut stream: TcpStream, app: Arc<App>) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(120)))?;
    stream.set_write_timeout(Some(Duration::from_secs(30)))?;
    stream.set_nodelay(true).ok();

    let remote = stream
        .peer_addr()
        .map(|a| a.to_string())
        .unwrap_or_default();
    let read_half = stream.try_clone()?;
    let mut reader = BufReader::new(read_half);

    loop {
        let t0 = util::now_ms();
        let req = match http::read_request(&mut reader) {
            Ok(Some(r)) => r,
            Ok(None) => return Ok(()),
            Err(_) => return Ok(()),
        };

        let serial = nest::extract_serial(&req);
        if let Some(s) = &serial {
            app.mark_seen(s);
            if let Some(auth) = req.header("authorization") {
                if let Some(pw) = util::basic_auth_password(auth) {
                    app.remember_api_key(s, &pw);
                }
            }
        }

        if nest::is_subscribe(&req) {
            match nest::prepare_subscribe(&app, &req) {
                SubscribeOutcome::Normal(resp) => {
                    app.debug.record(Trace::capture(
                        &req,
                        &remote,
                        serial.as_deref(),
                        resp.status,
                        util::now_ms() - t0,
                        resp.body.len(),
                        None,
                    ));
                    http::write_response(&mut stream, &resp)?;
                    return Ok(());
                }
                SubscribeOutcome::Held {
                    serial,
                    initial,
                    headers,
                } => {
                    let result = handle_held(&mut stream, &app, &serial, initial, &headers);
                    app.debug.record(Trace::capture(
                        &req,
                        &remote,
                        Some(&serial),
                        200,
                        util::now_ms() - t0,
                        0,
                        Some("held".to_string()),
                    ));
                    return result;
                }
            }
        }

        let resp = route(&app, &req);
        let close = req.wants_close();
        app.debug.record(Trace::capture(
            &req,
            &remote,
            serial.as_deref(),
            resp.status,
            util::now_ms() - t0,
            resp.body.len(),
            None,
        ));
        http::write_response(&mut stream, &resp)?;
        if close {
            return Ok(());
        }
    }
}

fn route(app: &App, req: &crate::http::Request) -> http::Response {
    if req.path == "/health" {
        return http::Response::json("{\"status\":\"ok\"}".to_string());
    }
    if let Some(resp) = crate::debug::route(app, req) {
        return resp;
    }
    if let Some(resp) = nest::route(app, req) {
        return resp;
    }
    if let Some(resp) = control::route(app, req) {
        return resp;
    }
    http::Response::json_status(404, "{\"error\":\"not found\"}".to_string())
}

/// Hold a chunked subscribe connection open. Registering the subscription
/// before any wait guarantees a command issued during header write is not lost.
fn handle_held(
    stream: &mut TcpStream,
    app: &App,
    serial: &str,
    initial: Option<String>,
    headers: &[(String, String)],
) -> io::Result<()> {
    // Register the subscription *before* writing headers so a command issued in
    // this window is queued instead of lost (single-threaded Python has no such
    // race; the thread-per-connection model must close it explicitly).
    let (tx, rx) = mpsc::channel();
    let (id, pending) = app.subs.add(serial, tx);

    let result = (|| -> io::Result<()> {
        http::write_chunked_headers(stream, headers)?;

        let mut first_bodies: Vec<Vec<u8>> = Vec::new();
        if let Some(body) = initial {
            first_bodies.push(body.into_bytes());
        }
        if let Some(objs) = pending {
            first_bodies.push(crate::state::objects_body(&objs).into_bytes());
        }

        if !first_bodies.is_empty() {
            for body in first_bodies {
                http::write_chunk(stream, &body)?;
            }
            drain_batch(stream, &rx)?;
            http::write_last_chunk(stream)?;
        } else {
            match rx.recv_timeout(Duration::from_secs(app.cfg.connection_hold_timeout)) {
                Ok(objs) => {
                    http::write_chunk(stream, crate::state::objects_body(&objs).as_bytes())?;
                    drain_batch(stream, &rx)?;
                    http::write_last_chunk(stream)?;
                }
                // Normal timeout path: close without a body (no tickle). The
                // close wakes the device via WoWLAN and it resubscribes.
                Err(_) => {}
            }
        }
        Ok(())
    })();

    app.subs.remove(serial, id);
    result
}

/// After the first chunk, batch additional pushes for up to 3 s. The device
/// resets its 5 s inter-chunk timer on every chunk, so 3 s is safe.
fn drain_batch(stream: &mut TcpStream, rx: &mpsc::Receiver<Vec<crate::state::DeviceObject>>) -> io::Result<()> {
    loop {
        match rx.recv_timeout(Duration::from_secs(3)) {
            Ok(objs) => http::write_chunk(stream, crate::state::objects_body(&objs).as_bytes())?,
            Err(_) => break,
        }
    }
    Ok(())
}
