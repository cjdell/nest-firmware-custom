//! Minimal blocking HTTP/1.1 request parser and response writer with chunked
//! support. Deliberately tiny: only what the Nest protocol and control API need.

use std::collections::HashMap;
use std::io::{self, BufRead, Write};
use std::net::TcpStream;

use crate::util::percent_decode;

pub struct Request {
    pub method: String,
    pub path: String,
    pub query: HashMap<String, String>,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.get(&name.to_ascii_lowercase()).map(|s| s.as_str())
    }

    pub fn query_get(&self, name: &str) -> Option<&str> {
        self.query.get(name).map(|s| s.as_str())
    }

    pub fn wants_close(&self) -> bool {
        self.header("connection")
            .map(|v| v.eq_ignore_ascii_case("close"))
            .unwrap_or(false)
    }

    pub fn json(&self) -> Option<serde_json::Value> {
        serde_json::from_slice(&self.body).ok()
    }
}

pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn new(status: u16, body: Vec<u8>) -> Self {
        Response {
            status,
            headers: Vec::new(),
            body,
        }
    }

    pub fn json(body: String) -> Self {
        let mut r = Response::new(200, body.into_bytes());
        r.headers
            .push(("Content-Type".into(), "application/json".into()));
        r
    }

    pub fn json_status(status: u16, body: String) -> Self {
        let mut r = Response::json(body);
        r.status = status;
        r
    }
}

fn read_line<R: BufRead>(reader: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut buf = Vec::new();
    let n = reader.read_until(b'\n', &mut buf)?;
    if n == 0 {
        return Ok(None);
    }
    Ok(Some(buf))
}

fn trim_crlf(mut b: Vec<u8>) -> Vec<u8> {
    while matches!(b.last(), Some(b'\n') | Some(b'\r')) {
        b.pop();
    }
    b
}

pub fn read_request<R: BufRead>(reader: &mut R) -> io::Result<Option<Request>> {
    // Skip blank lines between pipelined requests.
    let line = loop {
        match read_line(reader)? {
            None => return Ok(None),
            Some(l) if trim_crlf(l.clone()).is_empty() => continue,
            Some(l) => break l,
        }
    };
    let line = String::from_utf8_lossy(&trim_crlf(line)).into_owned();
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or("").to_string();
    let target = parts.next().unwrap_or("/").to_string();
    if method.is_empty() {
        return Ok(None);
    }

    let (raw_path, raw_query) = match target.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (target.clone(), String::new()),
    };
    let path = percent_decode(&raw_path);
    let mut query = HashMap::new();
    for pair in raw_query.split('&').filter(|s| !s.is_empty()) {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        query.insert(percent_decode(k), percent_decode(v));
    }

    let mut headers = HashMap::new();
    loop {
        let h = match read_line(reader)? {
            None => break,
            Some(h) => String::from_utf8_lossy(&trim_crlf(h)).into_owned(),
        };
        if h.is_empty() {
            break;
        }
        if let Some((name, value)) = h.split_once(':') {
            headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_string());
        }
    }

    let body = if headers
        .get("transfer-encoding")
        .map(|v| v.to_ascii_lowercase().contains("chunked"))
        .unwrap_or(false)
    {
        read_chunked_body(reader)?
    } else {
        let len: usize = headers
            .get("content-length")
            .and_then(|v| v.trim().parse().ok())
            .unwrap_or(0);
        let mut buf = vec![0u8; len];
        if len > 0 {
            reader.read_exact(&mut buf)?;
        }
        buf
    };

    Ok(Some(Request {
        method,
        path,
        query,
        headers,
        body,
    }))
}

fn read_chunked_body<R: BufRead>(reader: &mut R) -> io::Result<Vec<u8>> {
    let mut out = Vec::new();
    loop {
        let size_line = match read_line(reader)? {
            None => break,
            Some(l) => String::from_utf8_lossy(&trim_crlf(l)).into_owned(),
        };
        let size_str = size_line.split(';').next().unwrap_or("").trim();
        let size = usize::from_str_radix(size_str, 16).unwrap_or(0);
        if size == 0 {
            // consume trailers up to the blank line
            loop {
                match read_line(reader)? {
                    None => break,
                    Some(l) => {
                        if trim_crlf(l).is_empty() {
                            break;
                        }
                    }
                }
            }
            break;
        }
        let mut chunk = vec![0u8; size];
        reader.read_exact(&mut chunk)?;
        out.extend_from_slice(&chunk);
        let _ = read_line(reader)?; // trailing CRLF
    }
    Ok(out)
}

pub fn write_response(stream: &mut TcpStream, resp: &Response) -> io::Result<()> {
    let mut out = Vec::with_capacity(resp.body.len() + 256);
    out.extend_from_slice(
        format!("HTTP/1.1 {} {}\r\n", resp.status, status_text(resp.status)).as_bytes(),
    );
    let mut has_cl = false;
    for (k, v) in &resp.headers {
        if k.eq_ignore_ascii_case("content-length") {
            has_cl = true;
        }
        out.extend_from_slice(format!("{}: {}\r\n", k, v).as_bytes());
    }
    if !has_cl {
        out.extend_from_slice(format!("Content-Length: {}\r\n", resp.body.len()).as_bytes());
    }
    out.extend_from_slice(b"Connection: keep-alive\r\nServer: nest-ondevice\r\n\r\n");
    out.extend_from_slice(&resp.body);
    stream.write_all(&out)?;
    stream.flush()
}

/// Write a 200 header block for a chunked (long-poll) response.
pub fn write_chunked_headers(
    stream: &mut TcpStream,
    headers: &[(String, String)],
) -> io::Result<()> {
    let mut out = Vec::with_capacity(256);
    out.extend_from_slice(b"HTTP/1.1 200 OK\r\n");
    for (k, v) in headers {
        out.extend_from_slice(format!("{}: {}\r\n", k, v).as_bytes());
    }
    out.extend_from_slice(b"Transfer-Encoding: chunked\r\nConnection: keep-alive\r\nServer: nest-ondevice\r\n\r\n");
    stream.write_all(&out)?;
    stream.flush()
}

pub fn write_chunk(stream: &mut TcpStream, data: &[u8]) -> io::Result<()> {
    stream.write_all(format!("{:x}\r\n", data.len()).as_bytes())?;
    stream.write_all(data)?;
    stream.write_all(b"\r\n")?;
    stream.flush()
}

pub fn write_last_chunk(stream: &mut TcpStream) -> io::Result<()> {
    stream.write_all(b"0\r\n\r\n")?;
    stream.flush()
}

fn status_text(status: u16) -> &'static str {
    match status {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        _ => "OK",
    }
}
