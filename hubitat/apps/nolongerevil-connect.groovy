/**
 *  NoLongerEvil Connect
 *
 *  Hubitat app that discovers NoLongerEvil self-hosted servers on the local
 *  network and creates a "NoLongerEvil Thermostat" child device for every
 *  thermostat the server knows about.
 *
 *  Discovery order:
 *    1. mDNS browse for "_nolongerevil._tcp" (only works if the server
 *       advertises the service; harmless if it does not).
 *    2. A /24 subnet probe of the hub's own subnet on the control port,
 *       looking for the server's /api/config endpoint.
 *    3. Manual entry of host/port.
 *
 *  License: MIT
 */

definition(
    name: "NoLongerEvil Connect",
    namespace: "nolongerevil",
    author: "NoLongerEvil",
    description: "Discover NoLongerEvil thermostats on your LAN and add them to Hubitat.",
    category: "Convenience",
    iconUrl: "",
    iconX2Url: "",
    singleInstance: true,
    importUrl: "https://raw.githubusercontent.com/codykociemba/NoLongerEvil-Hubitat/main/apps/nolongerevil-connect.groovy"
)

preferences {
    page(name: "mainPage")
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

def installed() {
    log.info "NoLongerEvil Connect installed"
    initialize()
}

def updated() {
    log.info "NoLongerEvil Connect updated"
    initialize()
}

def uninstalled() {
    getChildDevices()?.each { child ->
        try {
            deleteChildDevice(child.deviceNetworkId)
        } catch (Exception e) {
            log.warn "Failed to delete child ${child.deviceNetworkId}: ${e.message}"
        }
    }
}

def initialize() {
    state.scanResults = state.scanResults instanceof Map ? state.scanResults : [:]
    state.scanQueue = state.scanQueue instanceof List ? state.scanQueue : []
    state.scanRunning = state.scanRunning == true
    state.scanStatus = state.scanStatus ?: "Not scanned yet."
    state.deviceStatus = state.deviceStatus ?: "No devices added yet."
}

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------

def mainPage() {
    dynamicPage(name: "mainPage", title: "No Longer Evil Thermostat", install: true, uninstall: true) {
        section("NoLongerEvil server") {
            paragraph "This app talks to a <b>NoLongerEvil self-hosted server</b> " +
                "(the same server your thermostat connects to). The control API listens on " +
                "port <b>8082</b> by default."

            input name: "serverHost", type: "text", title: "Server IP address or hostname",
                required: false, submitOnChange: true
            input name: "serverPort", type: "number", title: "Control API port",
                defaultValue: 8082, required: true, submitOnChange: true

            input name: "scanBtn", type: "button", title: "Scan LAN for servers"
            input name: "refreshBtn", type: "button", title: "Refresh"

            paragraph buildScanHtml()
        }

        section("Thermostats") {
            input name: "discoverBtn", type: "button", title: "Discover and add thermostats"
            paragraph buildDevicesHtml()
        }
    }
}

def appButtonHandler(String btn) {
    switch (btn) {
        case "scanBtn":
            startScan()
            break
        case "refreshBtn":
            // Re-render the page with the latest state.
            break
        case "discoverBtn":
            discoverDevices()
            break
        default:
            log.debug "Unknown button: ${btn}"
    }
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

private void startScan() {
    state.scanResults = [:]
    state.scanRunning = true
    state.scanStatus = "Starting scan..."

    // 1. Best-effort mDNS browse. Requires hub firmware 2.5.1+ and a server
    //    that advertises _nolongerevil._tcp; failures are non-fatal.
    if (tryMdns()) {
        state.scanStatus = "mDNS found ${state.scanResults.size()} server(s)."
        state.scanRunning = false
        if (!settings.serverHost) {
            autoSelectFirstServer()
        }
        return
    }

    // 2. Subnet probe.
    def hubIp = location?.hub?.localIP
    if (!hubIp) {
        state.scanRunning = false
        state.scanStatus = "Could not determine hub IP. Enter the server address manually."
        return
    }
    def parts = hubIp.toString().tokenize(".")
    if (parts.size() != 4) {
        state.scanRunning = false
        state.scanStatus = "Unexpected hub IP ${hubIp}. Enter the server address manually."
        return
    }
    def prefix = parts[0..2].join(".")
    state.scanQueue = (1..254).collect { "${prefix}.${it}".toString() }
    state.scanTotal = state.scanQueue.size()
    state.scanDone = 0
    state.scanStatus = "Scanning ${prefix}.0/24 on port ${settings.serverPort ?: 8082}..."
    scanNextBatch()
}

private boolean tryMdns() {
    def serviceTypes = ["_nolongerevil._tcp.local", "_nolongerevil._tcp"]
    for (st in serviceTypes) {
        try {
            def results = hubitat.helper.NetworkUtils.getMDNSServiceResults(st, 4000)
            results?.each { svc ->
                def ips = svc?.ip4Addresses ?: []
                def port = svc?.port ?: (settings.serverPort ?: 8082)
                ips.each { ip ->
                    recordServer(ip.toString(), port, "mDNS")
                }
            }
            if ((state.scanResults ?: [:]).size() > 0) {
                return true
            }
        } catch (Throwable t) {
            log.debug "mDNS browse for ${st} unavailable: ${t.message}"
        }
    }
    return false
}

private void scanNextBatch() {
    def queue = state.scanQueue instanceof List ? state.scanQueue : []
    if (!queue.isEmpty()) {
        def batchSize = 25
        def batch = queue.take(batchSize)
        state.scanQueue = queue.drop(batchSize)
        batch.each { ip ->
            probeServer(ip.toString())
        }
        state.scanDone = (state.scanDone ?: 0) + batch.size()
        runIn(2, "scanNextBatch")
    } else {
        state.scanRunning = false
        state.scanStatus = "Scan complete. Found ${(state.scanResults ?: [:]).size()} server(s)."
        if (!settings.serverHost) {
            autoSelectFirstServer()
        }
    }
}

private void probeServer(String ip) {
    def port = settings.serverPort ?: 8082
    try {
        asynchttpGet("scanCallback", [
            uri    : "http://${ip}:${port}",
            path   : "/api/config",
            timeout: 2,
            data   : [ip: ip, port: port],
        ])
    } catch (Exception e) {
        log.debug "Probe of ${ip} failed: ${e.message}"
    }
}

def scanCallback(response, data) {
    if (response == null || response.status != 200) {
        return
    }
    def json = null
    try {
        json = response.json
    } catch (Exception ignored) {
        return
    }
    if (json == null) {
        return
    }
    // /api/config always reports api_origin for a NoLongerEvil control server.
    if (json.api_origin != null || json.cloudregisterurl != null) {
        recordServer(data?.ip?.toString(), data?.port ?: (settings.serverPort ?: 8082), "scan")
    }
}

private void recordServer(String ip, port, source) {
    if (!ip) return
    def results = state.scanResults instanceof Map ? state.scanResults : [:]
    results[ip] = [port: port, source: source, apiOrigin: "http://${ip}:${port}"]
    state.scanResults = results
}

private void autoSelectFirstServer() {
    def first = (state.scanResults ?: [:]).keySet()?.sort()?.getAt(0)
    if (first) {
        try {
            app.updateSetting("serverHost", [value: first, type: "text"])
            state.scanStatus = "${state.scanStatus} Selected ${first}."
        } catch (Exception e) {
            log.debug "Could not auto-select ${first}: ${e.message}"
        }
    }
}

// ---------------------------------------------------------------------------
// Device creation
// ---------------------------------------------------------------------------

private void discoverDevices() {
    def host = settings.serverHost
    def port = settings.serverPort ?: 8082
    if (!host) {
        state.deviceStatus = "Enter or scan for a server first."
        return
    }
    state.deviceStatus = "Fetching thermostats from ${host}:${port}..."
    try {
        asynchttpGet("devicesCallback", [
            uri    : "http://${host}:${port}",
            path   : "/api/devices",
            timeout: 10,
        ])
    } catch (Exception e) {
        state.deviceStatus = "Request failed: ${e.message}"
    }
}

def devicesCallback(response, data) {
    if (response == null || response.status != 200) {
        state.deviceStatus = "Failed to list devices (HTTP ${response?.status})."
        return
    }
    def json = null
    try {
        json = response.json
    } catch (Exception ignored) {
        state.deviceStatus = "Server returned invalid JSON."
        return
    }
    def devices = json?.devices ?: []
    if (!devices) {
        state.deviceStatus = "No thermostats reported by the server yet. " +
            "Make sure your thermostat is paired and online."
        return
    }

    def host = settings.serverHost
    def port = settings.serverPort ?: 8082
    def added = 0
    def refreshed = 0

    devices.each { d ->
        def serial = d?.serial?.toString()
        if (!serial) return
        def dni = "nolongerevil-${serial}"
        def label = d?.name ?: "NoLongerEvil Thermostat"
        def existing = getChildDevice(dni)
        try {
            if (existing) {
                existing.updateSetting("serverUrl", "http://${host}:${port}".toString())
                existing.updateSetting("serial", serial)
                existing.configure()
                refreshed++
            } else {
                def child = addChildDevice("nolongerevil", "NoLongerEvil Thermostat", dni, [
                    name : "NLE ${d?.name ?: serial}",
                    label: label,
                ])
                child.updateSetting("serverUrl", "http://${host}:${port}".toString())
                child.updateSetting("serial", serial)
                child.updateSetting("pollInterval", "60")
                child.configure()
                added++
            }
        } catch (Exception e) {
            log.error "Failed to create/refresh device ${serial}: ${e.message}"
        }
    }

    state.deviceStatus = "Added ${added} new, refreshed ${refreshed} existing (${devices.size()} total)."
}

// ---------------------------------------------------------------------------
// UI helpers
// ---------------------------------------------------------------------------

private String buildScanHtml() {
    def sb = new StringBuilder()
    sb.append("<b>Status:</b> ${state.scanStatus ?: 'Not scanned yet.'}<br>")
    def results = state.scanResults ?: [:]
    if (results) {
        sb.append("<b>Discovered servers:</b><br>")
        results.sort { it.key }.each { ip, info ->
            sb.append("&nbsp;&nbsp;• ${ip}:${info.port} <i>(${info.source})</i><br>")
        }
    } else if (state.scanRunning) {
        def done = state.scanDone ?: 0
        def total = state.scanTotal ?: 254
        sb.append("<i>Probing ${done}/${total} addresses...</i><br>")
    }
    return sb.toString()
}

private String buildDevicesHtml() {
    def sb = new StringBuilder()
    sb.append("<b>Status:</b> ${state.deviceStatus ?: 'No devices added yet.'}<br>")
    def children = getChildDevices() ?: []
    if (children) {
        sb.append("<b>Thermostats:</b><br>")
        children.each { child ->
            sb.append("&nbsp;&nbsp;• ${child.displayName} (${child.deviceNetworkId})<br>")
        }
    }
    return sb.toString()
}
