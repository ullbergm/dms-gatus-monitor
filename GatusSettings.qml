import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "gatus-monitor"

    StringSetting {
        settingKey: "gatusUrl"
        label: "Gatus URL"
        description: "Base URL of your Gatus instance (e.g. http://localhost:8080)"
        defaultValue: "http://localhost:8080"
        placeholder: "http://localhost:8080"
    }

    SliderSetting {
        settingKey: "refreshIntervalSec"
        label: "Refresh Interval (seconds)"
        description: "How often to poll Gatus. Allowed range: 5-300 seconds."
        defaultValue: 30
        minimum: 5
        maximum: 300
        unit: "sec"
    }

    ToggleSetting {
        settingKey: "unstableOkIfLatestSuccess"
        label: "Treat unstable as OK if latest check passed"
        description: "Show an endpoint as up (not unstable) when its most recent check succeeded, even if prior checks failed."
        defaultValue: false
    }

    SelectionSetting {
        settingKey: "pillMode"
        label: "Pill Mode"
        description: "Display mode for the status bar pill: full, text, or icon."
        options: [
            { label: "Full", value: "full" },
            { label: "Text", value: "text" },
            { label: "Icon", value: "icon" }
        ]
        defaultValue: "full"
    }

}
