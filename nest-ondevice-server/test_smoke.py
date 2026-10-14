#!/usr/bin/env python3
"""End-to-end smoke test for the Rust on-device Nest server."""
import base64, json, socket, threading, time, urllib.request, urllib.error

DEV = "127.0.0.1:18000"
CTL = "127.0.0.1:18082"
SERIAL = "02AA01AB501203EQ"


def auth():
    return "Basic " + base64.b64encode(f"nest.{SERIAL}:sekret".encode()).decode()


def req(port, method, path, body=None, chunked=False, timeout=10):
    url = f"http://{port}{path}"
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", auth())
    if data:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, resp.read().decode(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        # A 4xx from the control API is a result we assert on, not an exception.
        return e.code, e.read().decode(), dict(e.headers)


def check(name, cond):
    print(("PASS" if cond else "FAIL"), name)
    if not cond:
        raise SystemExit(1)


# 1. entry
st, body, _ = req(DEV, "GET", "/nest/entry")
entry = json.loads(body)
check("entry status", st == 200)
check("entry transport url", entry["transport_url"].endswith("/nest/transport"))

# 2. first subscribe: send full device bucket as an inline update
device_obj = {"object_key": f"device.{SERIAL}", "object_revision": 0, "object_timestamp": 0,
              "value": {"current_temperature": 20.5, "has_fan": True, "leaf": True}}
st, body, hdrs = req(DEV, "POST", "/nest/transport", {"chunked": False, "session": "s1",
                                                      f"device.{SERIAL}": device_obj})
resp = json.loads(body)
keys = sorted(o["object_key"] for o in resp["objects"])
check("subscribe returns device", f"device.{SERIAL}" in keys)
check("subscribe auto-pairs (user)", f"user.homeassistant" in keys)
check("subscribe injects structure", any(k.startswith("structure.") for k in keys))
check("revision before key in wire order", '"object_revision"' in body and body.index('"object_revision"') < body.index('"object_key"'))

# 3. put a shared bucket update
put = {"session": "s1", "objects": [
    {"object_key": f"shared.{SERIAL}", "value": {"target_temperature": 21.0,
     "target_temperature_type": "heat", "current_temperature": 20.5}}]}
st, body, _ = req(DEV, "POST", "/nest/transport/put", put)
check("put status", st == 200)
check("put returns no value echo", "value" not in json.loads(body)["objects"][0])

# 4. held chunked subscribe + command push
result = {}

def held():
    s = socket.create_connection(("127.0.0.1", 18000), timeout=20)
    payload = json.dumps({"chunked": True, "session": "s2",
                          f"device.{SERIAL}": {"object_key": f"device.{SERIAL}",
                                               "object_revision": 1, "object_timestamp": 1}}).encode()
    reqline = (f"POST /nest/transport HTTP/1.1\r\nHost: x\r\nAuthorization: {auth()}\r\n"
               f"Content-Type: application/json\r\nContent-Length: {len(payload)}\r\n\r\n").encode()
    s.sendall(reqline + payload)
    # read headers
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(4096)
    head, rest = buf.split(b"\r\n\r\n", 1)
    result["headers"] = head.decode()
    # read all chunks until the terminating 0-size chunk
    chunks = []
    while True:
        while b"\r\n" not in rest:
            rest += s.recv(4096)
        size_line, rest = rest.split(b"\r\n", 1)
        size = int(size_line, 16)
        if size == 0:
            break
        while len(rest) < size + 2:
            rest += s.recv(4096)
        chunks.append(rest[:size].decode())
        rest = rest[size + 2:]
    result["chunks"] = chunks
    s.close()

t = threading.Thread(target=held)
t.start()
time.sleep(0.5)
st, body, _ = req(CTL, "POST", "/command", {"serial": SERIAL, "command": "set_temperature", "value": 22.5})
cmd = json.loads(body)
check("command ok", st == 200 and cmd["success"])
t.join(timeout=15)
check("held got chunked header", "chunked" in result.get("headers", "").lower())
all_objs = []
for c in result.get("chunks", []):
    all_objs.extend(json.loads(c).get("objects", []))
pkeys = [o["object_key"] for o in all_objs]
check("held received shared bucket", f"shared.{SERIAL}" in pkeys)
tv = [o for o in all_objs if o["object_key"] == f"shared.{SERIAL}"][0]["value"]
check("held saw new target temp", tv.get("target_temperature") == 22.5)

# 5. status
st, body, _ = req(CTL, "GET", f"/status?serial={SERIAL}")
status = json.loads(body)
check("status ok", st == 200)
check("status target temperature", status["target_temperature"] == 22.5)
check("status mode", status["mode"] == "heat")
check("status api_key captured", status["api_key"] == "sekret")

# 6. devices list
st, body, _ = req(CTL, "GET", "/api/devices")
devs = json.loads(body)
check("devices lists thermostat", any(d["serial"] == SERIAL for d in devs["devices"]))

# 7. mode command + fan
st, body, _ = req(CTL, "POST", "/command", {"serial": SERIAL, "command": "set_mode", "value": "cool"})
check("set_mode rejects nothing", json.loads(body)["success"])
st, body, _ = req(CTL, "POST", "/command", {"serial": SERIAL, "command": "set_fan", "value": "on"})
check("set_fan on", json.loads(body)["success"])

# 8. debug / observability surface
st, body, _ = req(CTL, "GET", "/debug/status")
dbg = json.loads(body)
check("debug status ok", st == 200 and dbg["server"] == "nest-ondevice")
check("debug status config + counters", dbg["config"]["control_port"] == 18082 and "counters" in dbg)
check("debug status sees device", any(d["serial"] == SERIAL for d in dbg["devices"]))
st, body, _ = req(CTL, "GET", "/debug/logs?n=5")
check("debug logs", st == 200 and "lines" in json.loads(body))
st, body, _ = req(CTL, "GET", "/debug/trace?n=20")
tr = json.loads(body)["exchanges"]
check("debug trace recorded requests", any(e["path"] == "/nest/entry" for e in tr))
check("debug trace has no auth leak", all("sekret" not in json.dumps(e) for e in tr))
st, body, _ = req(CTL, "GET", "/debug/report?n=5")
rep = json.loads(body)
check("debug report bundle", st == 200 and "status" in rep and "system" in rep)
st, body, _ = req(CTL, "POST", "/debug/loglevel?level=3")
check("debug loglevel", st == 200 and json.loads(body)["level"] == 3)
st, body, _ = req(CTL, "GET", "/debug/state")
check("debug state lists serial", any(d["serial"] == SERIAL for d in json.loads(body)["devices"]))

# 9. schedule: the device publishes its own bucket, the SPA/API round-trips it
SCHED_KEY = f"schedule.{SERIAL}"
sched_obj = {
    "object_key": SCHED_KEY, "object_revision": 0, "object_timestamp": 0,
    "value": {"ver": 2, "name": "", "schedule_mode": "HEAT",
              "schedule_algorithm": "PROGRAM",
              "days": {"0": {"0": {"time": 23400, "type": "HEAT", "temp": 20.0, "entry_type": "setpoint"},
                              "1": {"time": 32400, "type": "HEAT", "temp": 16.0, "entry_type": "setpoint"}}}},
}
st, body, _ = req(DEV, "POST", "/nest/transport/put", {"session": "s1", "objects": [sched_obj]})
check("schedule put accepted", st == 200)
st, body, _ = req(CTL, "GET", f"/api/schedule?serial={SERIAL}")
sched = json.loads(body)
check("api/schedule returns the device's dict-of-dicts", sched["schedule"]["days"]["0"]["1"]["time"] == 32400)
rev0 = sched["object_revision"]

# A held long-poll, so we can see the schedule actually reach the device.
sched_push = {}

def held_schedule():
    s = socket.create_connection(("127.0.0.1", 18000), timeout=20)
    payload = json.dumps({"chunked": True, "session": "s3",
                          SCHED_KEY: {"object_key": SCHED_KEY,
                                      "object_revision": 1, "object_timestamp": 1}}).encode()
    s.sendall((f"POST /nest/transport HTTP/1.1\r\nHost: x\r\nAuthorization: {auth()}\r\n"
               f"Content-Type: application/json\r\nContent-Length: {len(payload)}\r\n\r\n").encode() + payload)
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(4096)
    head, rest = buf.split(b"\r\n\r\n", 1)
    sched_push["headers"] = head.decode()
    objs = []
    deadline = time.time() + 12
    while time.time() < deadline:
        while b"\r\n" not in rest:
            rest += s.recv(4096)
        size_line, rest = rest.split(b"\r\n", 1)
        size = int(size_line, 16)
        if size == 0:
            break
        while len(rest) < size + 2:
            rest += s.recv(4096)
        objs.extend(json.loads(rest[:size].decode()).get("objects", []))
        rest = rest[size + 2:]
        if any(o["object_key"] == SCHED_KEY and o.get("value", {}).get("days", {}).get("6") for o in objs):
            break
    sched_push["objects"] = objs
    s.close()

t2 = threading.Thread(target=held_schedule, daemon=True)
t2.start()
time.sleep(0.6)
st, body, _ = req(CTL, "POST", "/command", {"serial": SERIAL, "command": "set_schedule", "value": {
    "ver": 2, "name": "", "schedule_mode": "HEAT", "schedule_algorithm": "PROGRAM",
    "days": {"0": [{"time": 21600, "type": "HEAT", "temp": 21.0, "entry_type": "setpoint"}],
             "6": [{"time": 28800, "type": "HEAT", "temp": 19.0, "entry_type": "setpoint"}]}}})
res = json.loads(body)
check("set_schedule accepted", st == 200 and res["success"])
check("set_schedule writes the schedule bucket", res["data"]["object_key"] == SCHED_KEY)
t2.join(timeout=15)
pushed = [o for o in sched_push.get("objects", []) if o["object_key"] == SCHED_KEY]
check("schedule pushed down the long-poll", bool(pushed))
check("push carries the new days", pushed and pushed[-1]["value"]["days"]["6"][0]["temp"] == 19.0)
check("push keeps field order the device needs",
      bool(pushed) and json.dumps(pushed[-1]).index("object_revision")
      < json.dumps(pushed[-1]).index("object_key"))

st, body, _ = req(CTL, "GET", f"/api/schedule?serial={SERIAL}")
after = json.loads(body)
check("schedule bucket replaced", after["schedule"]["days"]["6"][0]["temp"] == 19.0)
check("schedule revision bumped", after["object_revision"] == rev0 + 1)
check("unknown top-level field preserved", after["schedule"].get("schedule_algorithm") == "PROGRAM")
check("entry_type round-trips", after["schedule"]["days"]["0"][0]["entry_type"] == "setpoint")


def try_schedule(days):
    return req(CTL, "POST", "/command", {"serial": SERIAL, "command": "set_schedule",
                                         "value": {"ver": 2, "schedule_mode": "HEAT", "days": days}})


st, body, _ = try_schedule({"0": [{"time": 100, "type": "HEAT", "temp": 99.0}]})
check("rejects temp above 32C", st == 400 and "outside" in json.loads(body)["message"])
st, body, _ = try_schedule({"7": []})
check("rejects day key outside 0-6", st == 400)
st, body, _ = try_schedule({"0": [{"type": "HEAT", "temp": 20.0}]})
check("rejects entry without time", st == 400)
st, body, _ = try_schedule({"0": [{"time": 0, "type": "RANGE", "temp-min": 18.0}]})
check("rejects RANGE without temp-max", st == 400)
st, body, _ = try_schedule({"0": [{"time": 0, "type": "HEAT", "temp": 20.0, "entry_type": "setpoint"},
                                  {"time": 3600, "type": "HEAT", "entry_type": "continuation"}]})
check("accepts a device continuation entry", json.loads(body)["success"])

# 10. the embedded schedule SPA (ui/, compiled by Bun, embedded by build.rs)
st, body, hdrs = req(CTL, "GET", "/")
check("SPA index served", st == 200 and 'id="app"' in body)
check("SPA index content type", "text/html" in hdrs.get("Content-Type", ""))
st, body, hdrs = req(CTL, "GET", "/index.js")
check("SPA bundle served", st == 200 and "text/javascript" in hdrs.get("Content-Type", "") and len(body) > 1000)
st, body, hdrs = req(CTL, "GET", "/app.css")
check("SPA stylesheet served", st == 200 and "text/css" in hdrs.get("Content-Type", ""))
st, body, _ = req(DEV, "GET", "/nest/entry")
check("SPA does not shadow the protocol", json.loads(body)["transport_url"].endswith("/nest/transport"))

print("\nALL TESTS PASSED")
