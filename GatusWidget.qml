import QtQuick
import Quickshell

import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // --- State ---
    property var endpoints: []
    property var downEndpoints: []
    property var unstableEndpoints: []
    property var upEndpoints: []
    property string overallStatus: "offline"  // "all_up", "some_unstable", "some_down", "all_down", "idle", "offline"

    property bool apiError: false
    property string errorMessage: ""
    property string lastUpdated: ""

    // --- Settings ---
    property string gatusUrl: pluginData.gatusUrl || "http://localhost:8080"
    property var refreshIntervalSetting: pluginData.refreshIntervalSec
    property string pillModeSetting: pluginData.pillMode || "full"
    property bool unstableOkIfLatestSuccess: pluginData.unstableOkIfLatestSuccess || false

    // --- Colors ---
    readonly property color colorDown: "#ff3b30"
    readonly property color colorDownBorder: "#ff8a82"
    readonly property color colorUnstable: "#f0a530"
    readonly property color colorUnstableBorder: "#f8c97a"
    readonly property color colorAlertText: "#ffffff"

    // --- Polling and URL state ---
    readonly property int baseInterval: parseRefreshIntervalMs(refreshIntervalSetting)
    property int currentInterval: baseInterval
    property int consecutiveFailures: 0
    readonly property int maxBackoffInterval: 60000
    property bool requestInFlight: false
    readonly property string normalizedGatusUrl: normalizeUrl(gatusUrl)
    readonly property bool validGatusUrl: isValidUrl(normalizedGatusUrl)
    readonly property string normalizedPillMode: normalizePillMode(pillModeSetting)

    onBaseIntervalChanged: {
        if (consecutiveFailures === 0)
            currentInterval = baseInterval
    }

    // ---------------------------------------------------------------
    // Collapsible endpoint section used in the popout
    // ---------------------------------------------------------------
    component SectionBlock: Column {
        id: sectionRoot
        property var epList: []
        property bool expanded: true
        property color sectionColor: "white"
        property string itemIcon: "check_circle"
        property string sectionLabel: ""

        width: parent.width
        spacing: Theme.spacingXS
        visible: epList.length > 0

        Row {
            width: parent.width
            spacing: Theme.spacingXS

            TapHandler {
                onTapped: sectionRoot.expanded = !sectionRoot.expanded
            }

            DankIcon {
                name: sectionRoot.expanded ? "expand_more" : "chevron_right"
                color: sectionRoot.sectionColor
            }

            StyledText {
                text: sectionRoot.sectionLabel + " (" + sectionRoot.epList.length + ")"
                color: sectionRoot.sectionColor
                font.pixelSize: Theme.fontSizeSmall
                font.bold: true
            }
        }

        Column {
            width: parent.width
            spacing: Theme.spacingXS
            visible: sectionRoot.expanded

            Repeater {
                model: sectionRoot.epList.length

                delegate: Item {
                    required property int index
                    readonly property var ep: sectionRoot.epList[index]
                    width: parent.width
                    height: epRow.implicitHeight + Theme.spacingXS * 2

                    Row {
                        id: epRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacingXS
                        anchors.rightMargin: Theme.spacingXS
                        spacing: Theme.spacingS

                        DankIcon {
                            name: sectionRoot.itemIcon
                            color: sectionRoot.sectionColor
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - Theme.spacingS * 2 - 24 - durationText.implicitWidth

                            StyledText {
                                width: parent.width
                                text: ep.group !== "" ? ep.group + " / " + ep.name : ep.name
                                elide: Text.ElideRight
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeMedium
                                font.bold: true
                            }
                        }

                        StyledText {
                            id: durationText
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.formatDuration(ep.durationMs)
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            visible: ep.durationMs >= 0
                        }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // Periodic refresh
    // ---------------------------------------------------------------
    Timer {
        id: pollTimer
        interval: root.currentInterval
        running: root.validGatusUrl
        repeat: true
        triggeredOnStart: true
        onTriggered: root.fetchStatuses()
    }

    // ---------------------------------------------------------------
    // API calls
    // ---------------------------------------------------------------
    function fetchStatuses() {
        if (requestInFlight)
            return

        if (!validGatusUrl) {
            setApiFailure("invalid_url")
            return
        }

        requestInFlight = true
        var xhr = new XMLHttpRequest()
        var url = normalizedGatusUrl + "/api/v1/endpoints/statuses?_ts=" + Date.now()

        xhr.timeout = 5000
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return

            requestInFlight = false

            if (xhr.status === 200) {
                try {
                    var arr = JSON.parse(xhr.responseText)
                    handleStatusResponse(arr)
                    setApiSuccess()
                } catch (e) {
                    setApiFailure("invalid_json")
                }
                return
            }

            if (xhr.status === 401 || xhr.status === 403) {
                setApiFailure("auth")
            } else if (xhr.status === 404) {
                setApiFailure("not_found")
            } else if (xhr.status === 0) {
                setApiFailure("unreachable")
            } else {
                setApiFailure("http_" + xhr.status)
            }
        }

        xhr.ontimeout = function() {
            requestInFlight = false
            setApiFailure("timeout")
        }

        xhr.open("GET", url)
        xhr.setRequestHeader("Cache-Control", "no-cache")
        xhr.setRequestHeader("Pragma", "no-cache")
        xhr.send()
    }

    function handleStatusResponse(arr) {
        if (!Array.isArray(arr)) {
            setApiFailure("invalid_payload")
            return
        }

        var all = []
        var downList = []
        var unstableList = []
        var upList = []

        for (var i = 0; i < arr.length; i++) {
            var ep = arr[i]
            var results = ep.results || []
            var latestResult = results.length > 0 ? results[results.length - 1] : null
            var state = endpointState(ep, latestResult, results)

            var row = {
                name: ep.name || ep.key || "Unknown",
                group: ep.group || "",
                key: ep.key || "",
                state: state,
                durationMs: endpointDurationMs(ep, latestResult)
            }
            all.push(row)

            if (state === "down") downList.push(row)
            else if (state === "unstable") unstableList.push(row)
            else upList.push(row)
        }

        endpoints = all
        downEndpoints = downList
        unstableEndpoints = unstableList
        upEndpoints = upList

        if (all.length === 0) {
            overallStatus = "idle"
        } else if (downList.length > 0) {
            overallStatus = upList.length === 0 && unstableList.length === 0 ? "all_down" : "some_down"
        } else if (unstableList.length > 0) {
            overallStatus = "some_unstable"
        } else {
            overallStatus = "all_up"
        }
    }

    function endpointSuccess(endpoint, latestResult) {
        // Prefer endpoint-level status because it represents current aggregate state.
        if (typeof endpoint.success === "boolean")
            return endpoint.success

        var status = (endpoint.status || endpoint.health || "").toString().toLowerCase()
        if (status === "up" || status === "healthy" || status === "ok" || status === "passing")
            return true
        if (status === "down" || status === "critical" || status === "failing" || status === "failed" || status === "error")
            return false

        // Fall back to latest result when endpoint-level fields are absent.
        if (latestResult && typeof latestResult.success === "boolean")
            return latestResult.success

        return false
    }

    function endpointState(endpoint, latestResult, results) {
        if (!endpointSuccess(endpoint, latestResult))
            return "down"

        if (isEndpointExplicitlyUnstable(endpoint) || hasAnyFailure(results)) {
            if (root.unstableOkIfLatestSuccess && latestResult && latestResult.success === true)
                return "up"
            return "unstable"
        }

        return "up"
    }

    function isEndpointExplicitlyUnstable(endpoint) {
        var health = (endpoint.health || "").toString().toLowerCase()
        var status = (endpoint.status || "").toString().toLowerCase()
        return health === "unhealthy" || status === "unhealthy" || status === "degraded"
    }

    function hasAnyFailure(results) {
        if (!Array.isArray(results) || results.length === 0)
            return false

        for (var i = 0; i < results.length; i++) {
            if (results[i] && results[i].success === false)
                return true
        }

        return false
    }

    function endpointDurationMs(endpoint, latestResult) {
        var raw = null

        if (latestResult && latestResult.duration !== undefined)
            raw = latestResult.duration
        else if (endpoint.responseTime !== undefined)
            raw = endpoint.responseTime

        if (raw === null)
            return -1

        var n = Number(raw)
        if (isNaN(n) || !isFinite(n) || n < 0)
            return -1

        // Most Gatus payloads expose duration in nanoseconds.
        if (n >= 1000000)
            return Math.round(n / 1000000)

        return Math.round(n)
    }


    // ---------------------------------------------------------------
    // Input normalization
    // ---------------------------------------------------------------
    function normalizeUrl(input) {
        var s = (input || "").trim()
        if (s === "") return ""
        if (!/^https?:\/\//i.test(s)) s = "http://" + s
        s = s.replace(/\/+$/, "")
        return s
    }

    function isValidUrl(input) {
        if (!input || input === "") return false
        return /^https?:\/\/[^\s]+$/i.test(input)
    }

    function parseRefreshIntervalMs(rawValue) {
        var normalized = rawValue
        if (normalized === undefined || normalized === null || normalized === "")
            normalized = 30
        var sec = parseInt(normalized, 10)
        if (isNaN(sec)) sec = 30
        if (sec < 5) sec = 5
        if (sec > 300) sec = 300
        return sec * 1000
    }

    function normalizePillMode(rawValue) {
        var mode = (rawValue || "full").toString().trim().toLowerCase()
        if (mode === "icon" || mode === "text" || mode === "full")
            return mode
        return "full"
    }

    // ---------------------------------------------------------------
    // API state management
    // ---------------------------------------------------------------
    function setApiSuccess() {
        apiError = false
        errorMessage = ""
        consecutiveFailures = 0
        currentInterval = baseInterval
        var now = new Date()
        lastUpdated = now.toLocaleTimeString(Qt.locale(), "HH:mm:ss")
    }

    function setApiFailure(reason) {
        apiError = true
        overallStatus = "offline"
        errorMessage = errorMessageFor(reason)
        consecutiveFailures += 1
        var next = baseInterval * Math.pow(2, consecutiveFailures)
        currentInterval = Math.min(maxBackoffInterval, next)
        pollTimer.restart()
    }

    function errorMessageFor(reason) {
        if (reason === "invalid_url") return "Invalid Gatus URL"
        if (reason === "auth") return "Authentication failed"
        if (reason === "not_found") return "Gatus API endpoint not found"
        if (reason === "timeout") return "Request timed out"
        if (reason === "unreachable") return "Unable to reach Gatus"
        if (reason === "invalid_json") return "Invalid response from Gatus"
        if (reason === "invalid_payload") return "Unexpected response payload"
        return "Request failed"
    }

    // ---------------------------------------------------------------
    // Status display helpers
    // ---------------------------------------------------------------
    function isDownOverallStatus() {
        return overallStatus === "some_down" || overallStatus === "all_down"
    }

    function isAlertStatus() {
        return isDownOverallStatus() || overallStatus === "some_unstable"
    }

    function statusColor() {
        if (isDownOverallStatus()) return colorDown
        switch (overallStatus) {
            case "all_up":        return Theme.primary
            case "some_unstable": return colorUnstable
            case "idle":          return Theme.surfaceVariantText
            default:              return Theme.error
        }
    }

    function pillBorderColor() {
        if (isDownOverallStatus()) return colorDownBorder
        if (overallStatus === "some_unstable") return colorUnstableBorder
        return "transparent"
    }

    function statusIcon() {
        if (isDownOverallStatus()) return "error"
        switch (overallStatus) {
            case "all_up":        return "check_circle"
            case "some_unstable": return "warning"
            case "idle":          return "monitor_heart"
            default:              return "cloud_off"
        }
    }

    function statusLabel() {
        if (!validGatusUrl) return "Invalid URL"
        if (apiError) return "Offline"
        if (overallStatus === "idle") return "0"
        if (overallStatus === "all_up") return String(upEndpoints.length)
        if (overallStatus === "some_unstable") return String(unstableEndpoints.length)
        if (isDownOverallStatus()) return String(downEndpoints.length)
        return "Offline"
    }

    function statusSummaryLabel() {
        if (!validGatusUrl) return "Invalid URL"
        if (apiError) return "Offline"
        if (overallStatus === "idle") return "No endpoints"
        if (overallStatus === "all_up") return upEndpoints.length + " up"
        if (overallStatus === "some_unstable") return unstableEndpoints.length + " unstable"
        if (isDownOverallStatus()) return downEndpoints.length + " down"
        return "Offline"
    }

    function formatDuration(ms) {
        if (ms < 0) return ""
        if (ms < 1000) return ms + "ms"
        return (ms / 1000).toFixed(1) + "s"
    }

    // ---------------------------------------------------------------
    // Status bar pill
    // ---------------------------------------------------------------
    horizontalBarPill: Component {
        Rectangle {
            radius: Theme.cornerRadius
            color: root.isAlertStatus() ? root.statusColor() : "transparent"
            border.width: root.isAlertStatus() ? 1 : 0
            border.color: root.pillBorderColor()
            implicitWidth: pillRow.implicitWidth + (root.isAlertStatus() ? Theme.spacingS * 2 : 0)
            implicitHeight: pillRow.implicitHeight + (root.isAlertStatus() ? Theme.spacingXS * 2 : 0)

            Row {
                id: pillRow
                anchors.centerIn: parent
                spacing: Theme.spacingS

                DankIcon {
                    name: root.statusIcon()
                    color: root.isAlertStatus() ? root.colorAlertText : root.statusColor()
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.normalizedPillMode !== "text"
                }

                StyledText {
                    text: root.statusLabel()
                    font.pixelSize: Theme.fontSizeSmall
                    font.bold: root.isAlertStatus()
                    color: root.isAlertStatus() ? root.colorAlertText : root.statusColor()
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.normalizedPillMode !== "icon"
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // Popout panel
    // ---------------------------------------------------------------
    popoutContent: Component {
        PopoutComponent {
            headerText: "Gatus"
            showCloseButton: true

            Column {
                width: parent.width
                spacing: Theme.spacingL

                // Overall status header
                Row {
                    width: parent.width
                    spacing: Theme.spacingM

                    DankIcon {
                        name: root.statusIcon()
                        color: root.statusColor()
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: root.apiError ? root.errorMessage : root.statusSummaryLabel()
                        font.pixelSize: Theme.fontSizeLarge
                        font.bold: true
                        color: root.statusColor()
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // Refresh / Open buttons
                Row {
                    width: parent.width
                    spacing: Theme.spacingS
                    visible: root.validGatusUrl

                    Rectangle {
                        width: btnLabel.implicitWidth + Theme.spacingM * 2
                        height: btnLabel.implicitHeight + Theme.spacingS * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceVariant

                        StyledText {
                            id: btnLabel
                            anchors.centerIn: parent
                            text: "Refresh"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.fetchStatuses()
                        }
                    }

                    Rectangle {
                        width: openLabel.implicitWidth + Theme.spacingM * 2
                        height: openLabel.implicitHeight + Theme.spacingS * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceVariant

                        StyledText {
                            id: openLabel
                            anchors.centerIn: parent
                            text: "Open in Gatus"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: Qt.openUrlExternally(root.normalizedGatusUrl)
                        }
                    }
                }

                // Last updated timestamp
                StyledText {
                    visible: root.lastUpdated !== "" && root.validGatusUrl
                    text: "Updated " + root.lastUpdated
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                // Endpoint list grouped by status
                Column {
                    width: parent.width
                    spacing: Theme.spacingS
                    visible: !root.apiError && root.endpoints.length > 0

                    SectionBlock {
                        epList: root.downEndpoints
                        sectionColor: Theme.error
                        itemIcon: "cancel"
                        sectionLabel: "Down"
                    }

                    SectionBlock {
                        epList: root.unstableEndpoints
                        sectionColor: root.colorUnstable
                        itemIcon: "warning"
                        sectionLabel: "Unstable"
                    }

                    SectionBlock {
                        epList: root.upEndpoints
                        expanded: false
                        sectionColor: Theme.primary
                        itemIcon: "check_circle"
                        sectionLabel: "Up"
                    }
                }

                // Backoff notice
                StyledText {
                    visible: root.apiError && root.validGatusUrl
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "Retrying every " + Math.round(root.currentInterval / 1000) + "s (backoff active)."
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                // Invalid URL hint
                StyledText {
                    visible: !root.validGatusUrl
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "Open plugin settings and enter your Gatus URL (e.g. http://localhost:8080)."
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }
            }
        }
    }
}
