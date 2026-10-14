/**
 *  NoLongerEvil Thermostat
 *
 *  Hubitat driver for a Nest Learning Thermostat (Gen 1/2, including the UK
 *  Gen 2 + Heat Link) running the NoLongerEvil firmware.
 *
 *  Talks to a NoLongerEvil self-hosted control server (default port 8082):
 *    GET  /status?serial=<serial>   -> full device state
 *    POST /command                  -> {serial, command, value}
 *  In this repo that server is the Rust nest-ondevice daemon running on the
 *  thermostat itself (http://192.168.1.2:8082), not a Docker/Python host.
 *
 *  LOCAL FORK of upstream codykociemba/NoLongerEvil-Hubitat (MIT). Two fixes
 *  applied — see hubitat/README.md "Provenance and our deltas" before
 *  re-importing anything from upstream:
 *    1. effectiveServerUrl(): replaceAll("/+$", …) is an illegal GString and
 *       the driver does not compile; the regex must be single-quoted.
 *    2. Heat-only units must also publish coolingSetpoint or the Hubitat
 *       Google Home app drops the device as "not compatible".
 *
 *  License: MIT (upstream), Copyright (c) 2025 Cody Kociemba
 */

import groovy.json.JsonOutput
import groovy.json.JsonSlurper

metadata {
    definition(
        name: "NoLongerEvil Thermostat",
        namespace: "nolongerevil",
        author: "NoLongerEvil",
        importUrl: "https://raw.githubusercontent.com/codykociemba/NoLongerEvil-Hubitat/main/drivers/nolongerevil-thermostat.groovy"
    ) {
        capability "Actuator"
        capability "Sensor"
        capability "Temperature Measurement"
        capability "RelativeHumidityMeasurement"
        capability "Thermostat"
        capability "Refresh"
        capability "Health Check"

        attribute "away", "ENUM"
        attribute "ecoMode", "ENUM"
        attribute "hasLeaf", "ENUM"
        attribute "isAvailable", "ENUM"
        attribute "hvacAction", "ENUM"

        command "configure"
        command "setAway", ["BOOLEAN"]
        command "setEcoTemperatures", [[name: "High*", type: "NUMBER"], [name: "Low*", type: "NUMBER"]]
        command "setScheduleMode", [[name: "Mode*", type: "ENUM", constraints: ["HEAT", "COOL", "RANGE"]]]
    }

    preferences {
        input name: "serverUrl", type: "text", title: "NoLongerEvil server URL",
            description: "Full URL of the self-hosted control server, e.g. http://192.168.1.100:8082",
            required: true
        input name: "serial", type: "text", title: "Thermostat serial", required: true
        input name: "pollInterval", type: "enum", title: "Poll interval (seconds)",
            options: ["15", "30", "60", "120", "300", "600"], defaultValue: "60"
        input name: "logEnable", type: "bool", title: "Enable debug logging", defaultValue: false
        input name: "txtEnable", type: "bool", title: "Enable description text logging", defaultValue: true
    }
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

def installed() {
    log.info "${device.displayName} installed (${device.deviceNetworkId})"
    configure()
}

def updated() {
    log.info "${device.displayName} updated"
    if (settings.logEnable) {
        runIn(1800, "logsOff")
    }
    configure()
}

def uninstalled() {
    unschedule()
}

def configure() {
    unschedule()
    // Tell the platform how long it may wait before treating us as offline.
    sendEvent(name: "checkInterval", value: (getPollSeconds() * 2) + 120, displayed: false, data: [protocol: "LAN"])
    refresh()
}

def logsOff() {
    log.warn "debug logging disabled..."
    device.updateSetting("logEnable", [value: "false", type: "bool"])
}

def refresh() {
    poll()
}

def ping() {
    poll()
}

// ---------------------------------------------------------------------------
// Polling
// ---------------------------------------------------------------------------

def poll() {
    def url = effectiveServerUrl()
    def ser = effectiveSerial()
    if (!url) {
        log.warn "poll() skipped: server URL not configured"
        markOffline()
        scheduleNextPoll()
        return
    }
    if (!ser) {
        log.warn "poll() skipped: thermostat serial not configured"
        markOffline()
        scheduleNextPoll()
        return
    }

    if (logEnable) log.debug "GET ${url}/status?serial=${ser}"
    try {
        asynchttpGet("statusCallback", [
            uri    : url,
            path   : "/status",
            query  : [serial: ser],
            timeout: 10,
        ])
    } catch (Exception e) {
        log.warn "poll() request failed: ${e.message}"
        markOffline()
        scheduleNextPoll()
    }
}

def statusCallback(response, data) {
    try {
        if (response == null || response.status != 200) {
            def code = response?.status
            log.warn "Status request failed (HTTP ${code})${response?.errorMessage ? ": ${response.errorMessage}" : ""}"
            markOffline()
            return
        }
        def json = response.json
        if (json == null) {
            log.warn "Status response was not valid JSON"
            markOffline()
            return
        }
        applyStatus(json)
        markOnline()
    } catch (Exception e) {
        log.error "Error handling status response: ${e.message}"
        markOffline()
    } finally {
        scheduleNextPoll()
    }
}

private void applyStatus(Map json) {
    def scale = getTemperatureScale()

    // --- Temperatures -----------------------------------------------------
    def current = asNumber(json.current_temperature)
    if (current != null) {
        sendEvent(name: "temperature", value: round1(convertFromCelsius(current, scale)), unit: "°${scale}")
    }

    def humidity = asNumber(json.humidity)
    if (humidity != null) {
        sendEvent(name: "humidity", value: round1(humidity), unit: "%")
    }

    def mode = toHubMode(json.mode)
    if (mode != null) {
        sendEvent(name: "thermostatMode", value: mode)
    }

    def isRange = (json.mode == "range")
    if (isRange) {
        def low = asNumber(json.target_temperature_low)
        def high = asNumber(json.target_temperature_high)
        if (low != null) {
            sendEvent(name: "heatingSetpoint", value: round1(convertFromCelsius(low, scale)), unit: "°${scale}")
            sendEvent(name: "thermostatSetpoint", value: round1(convertFromCelsius(low, scale)), unit: "°${scale}")
        }
        if (high != null) {
            sendEvent(name: "coolingSetpoint", value: round1(convertFromCelsius(high, scale)), unit: "°${scale}")
        }
    } else {
        def target = asNumber(json.target_temperature)
        if (target != null) {
            def t = round1(convertFromCelsius(target, scale))
            sendEvent(name: "thermostatSetpoint", value: t, unit: "°${scale}")
            if (mode == "cool") {
                sendEvent(name: "coolingSetpoint", value: t, unit: "°${scale}")
            } else {
                sendEvent(name: "heatingSetpoint", value: t, unit: "°${scale}")
                // Heat-only units still must publish coolingSetpoint or the Hubitat
                // Google Home app deems the Thermostat capability incomplete (trap 18).
                sendEvent(name: "coolingSetpoint", value: t, unit: "°${scale}")
            }
        }
    }

    // --- Fan --------------------------------------------------------------
    def fanOn = (json.fan_timer_active == true)
    sendEvent(name: "thermostatFanMode", value: fanOn ? "on" : "auto")

    // --- Operating state --------------------------------------------------
    def hvac = json.hvac ?: [:]
    def opState = "idle"
    if (hvac.heater || hvac.heat_x2 || hvac.heat_x3 || hvac.aux_heat || hvac.emer_heat || hvac.alt_heat) {
        opState = "heating"
    } else if (hvac.ac || hvac.cool_x2 || hvac.cool_x3) {
        opState = "cooling"
    } else if (hvac.fan) {
        opState = "fan only"
    }
    sendEvent(name: "thermostatOperatingState", value: opState)
    sendEvent(name: "hvacAction", value: opState)

    // --- Capabilities / supported modes -----------------------------------
    def caps = json.capabilities ?: [:]
    def modes = ["off"]
    if (caps.can_heat != false) modes << "heat"
    if (caps.can_cool == true) modes << "cool"
    if (caps.can_heat != false && caps.can_cool == true) modes << "auto"
    if (caps.has_emer_heat == true) modes << "emergency heat"
    sendEvent(name: "supportedThermostatModes", value: JsonOutput.toJson(modes))

    def fanModes = (caps.has_fan == true) ? ["auto", "on"] : ["auto"]
    sendEvent(name: "supportedThermostatFanModes", value: JsonOutput.toJson(fanModes))

    // --- Misc / convenience ----------------------------------------------
    sendEvent(name: "away", value: (json.away == true) ? "away" : "home")
    if (json.eco_mode != null) sendEvent(name: "ecoMode", value: json.eco_mode.toString())
    sendEvent(name: "hasLeaf", value: (json.has_leaf == true) ? "yes" : "no")
    sendEvent(name: "isAvailable", value: (json.is_available == true) ? "online" : "offline")
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

def auto()             { setThermostatMode("auto") }
def cool()             { setThermostatMode("cool") }
def emergencyHeat()    { setThermostatMode("emergency heat") }
def heat()             { setThermostatMode("heat") }
def off()              { setThermostatMode("off") }

def fanAuto()          { setThermostatFanMode("auto") }
def fanCirculate()     { setThermostatFanMode("on") }
def fanOn()            { setThermostatFanMode("on") }

def setThermostatMode(mode) {
    def nleMode = toNleMode(mode)
    if (nleMode == null) {
        log.warn "Unsupported thermostat mode: ${mode}"
        return
    }
    sendCommand("set_mode", nleMode)
}

def setThermostatFanMode(fanMode) {
    def nleFan = (fanMode == "on" || fanMode == "circulate") ? "on" : "auto"
    sendCommand("set_fan", nleFan)
}

def setThermostatSetpoint(temp) {
    def c = asNumber(temp)
    if (c == null) return
    sendCommand("set_temperature", round1(toCelsius(c)))
}

def setHeatingSetpoint(temp) {
    def c = asNumber(temp)
    if (c == null) return
    if (isRangeMode()) {
        def high = asNumber(device.currentValue("coolingSetpoint"))
        if (high == null) {
            sendCommand("set_temperature", round1(toCelsius(c)))
        } else {
            sendCommand("set_temperature", [low: round1(toCelsius(c)), high: round1(toCelsius(high))])
        }
    } else {
        sendCommand("set_temperature", round1(toCelsius(c)))
    }
}

def setCoolingSetpoint(temp) {
    def c = asNumber(temp)
    if (c == null) return
    if (isRangeMode()) {
        def low = asNumber(device.currentValue("heatingSetpoint"))
        if (low == null) {
            sendCommand("set_temperature", round1(toCelsius(c)))
        } else {
            sendCommand("set_temperature", [low: round1(toCelsius(low)), high: round1(toCelsius(c))])
        }
    } else {
        sendCommand("set_temperature", round1(toCelsius(c)))
    }
}

def setAway(Boolean away) {
    sendCommand("set_away", away == true)
}

def setEcoTemperatures(high, low) {
    def h = asNumber(high)
    def l = asNumber(low)
    if (h == null || l == null) {
        log.warn "setEcoTemperatures requires both high and low"
        return
    }
    sendCommand("set_eco_temperatures", [high: round1(toCelsius(h)), low: round1(toCelsius(l))])
}

def setScheduleMode(mode) {
    if (mode == null) return
    sendCommand("set_schedule_mode", mode.toString().toUpperCase())
}

def setSchedule(schedule) {
    if (schedule == null) return
    def value = schedule
    if (schedule instanceof CharSequence) {
        try {
            value = new JsonSlurper().parseText(schedule.toString())
        } catch (Exception ignored) {
            log.warn "setSchedule: could not parse schedule JSON"
            return
        }
    }
    sendCommand("set_schedule", value)
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

private void sendCommand(String command, value) {
    def url = effectiveServerUrl()
    def ser = effectiveSerial()
    if (!url || !ser) {
        log.warn "Cannot send '${command}': server URL or serial not configured"
        return
    }

    def body = JsonOutput.toJson([serial: ser, command: command, value: value])
    if (logEnable) log.debug "POST ${url}/command ${body}"

    try {
        asynchttpPost("commandCallback", [
            uri                : url,
            path               : "/command",
            requestContentType : "application/json",
            contentType        : "application/json",
            body               : body,
            timeout            : 10,
            data               : [command: command],
        ])
    } catch (Exception e) {
        log.warn "Command '${command}' request failed: ${e.message}"
    }
}

def commandCallback(response, data) {
    def command = data?.command
    if (response == null || response.status != 200) {
        log.warn "Command '${command}' failed (HTTP ${response?.status})"
        // Re-sync anyway
        runIn(2, "poll")
        return
    }
    def json = null
    try {
        json = response.json
    } catch (Exception ignored) {
        json = null
    }
    if (json?.success == false) {
        log.warn "Command '${command}' rejected: ${json?.message}"
    } else if (logEnable) {
        log.debug "Command '${command}' accepted"
    }
    // Give the thermostat a moment to apply then refresh our state.
    runIn(3, "poll")
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private String effectiveServerUrl() {
    def url = settings.serverUrl ?: device?.getDataValue("serverUrl")
    if (!url) return null
    return url.toString().replaceAll('/+$', "")
}

private String effectiveSerial() {
    return (settings.serial ?: device?.getDataValue("serial"))?.toString()
}

private boolean isRangeMode() {
    return toHubMode(device.currentValue("thermostatMode")) == "auto"
}

private void scheduleNextPoll() {
    unschedule("poll")
    runIn(getPollSeconds(), "poll")
}

private int getPollSeconds() {
    def seconds = 60
    try {
        seconds = (settings.pollInterval ?: "60").toString().toInteger()
    } catch (Exception ignored) {
        seconds = 60
    }
    if (seconds < 15) seconds = 15
    return seconds
}

private void markOnline() {
    sendEvent(name: "DeviceWatch-DeviceStatus", value: "online")
}

private void markOffline() {
    sendEvent(name: "DeviceWatch-DeviceStatus", value: "offline")
    sendEvent(name: "isAvailable", value: "offline")
}

private static String toHubMode(String nleMode) {
    switch (nleMode) {
        case "heat":      return "heat"
        case "cool":      return "cool"
        case "range":     return "auto"
        case "off":       return "off"
        case "emergency": return "emergency heat"
        default:          return null
    }
}

private static String toNleMode(String hubMode) {
    switch (hubMode) {
        case "heat":           return "heat"
        case "cool":           return "cool"
        case "auto":           return "heat-cool"
        case "off":            return "off"
        case "emergency heat": return "emergency"
        default:               return null
    }
}

private static BigDecimal asNumber(value) {
    if (value == null) return null
    if (value instanceof Number) return value as BigDecimal
    def s = value.toString().trim()
    if (s.isEmpty()) return null
    try {
        return new BigDecimal(s)
    } catch (Exception ignored) {
        return null
    }
}

private static BigDecimal round1(BigDecimal value) {
    if (value == null) return null
    return value.setScale(1, java.math.RoundingMode.HALF_UP)
}

/**
 * Convert a Celsius value reported by the NoLongerEvil API to the hub's
 * configured temperature scale.
 */
private BigDecimal convertFromCelsius(BigDecimal celsius, String scale) {
    if (celsius == null) return null
    if (scale == "F") {
        return celsiusToFahrenheit(celsius)
    }
    return celsius
}

/** Convert a hub-scale temperature to Celsius for the NoLongerEvil API. */
private BigDecimal toCelsius(BigDecimal value) {
    if (value == null) return null
    if (getTemperatureScale() == "F") {
        return fahrenheitToCelsius(value)
    }
    return value
}
