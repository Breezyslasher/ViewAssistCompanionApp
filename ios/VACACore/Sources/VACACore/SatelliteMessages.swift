import Foundation

/// Event type names used between Home Assistant and the satellite.
/// Standard Wyoming types come from the `wyoming` Python package; the VACA
/// ones come from `custom_components/vaca/custom.py`.
public enum EventType {
    public static let describe = "describe"
    public static let info = "info"
    public static let ping = "ping"
    public static let pong = "pong"
    public static let runSatellite = "run-satellite"
    public static let pauseSatellite = "pause-satellite"
    public static let runPipeline = "run-pipeline"
    public static let detect = "detect"
    public static let detection = "detection"
    public static let transcribe = "transcribe"
    public static let transcript = "transcript"
    public static let voiceStarted = "voice-started"
    public static let voiceStopped = "voice-stopped"
    public static let synthesize = "synthesize"
    public static let audioStart = "audio-start"
    public static let audioChunk = "audio-chunk"
    public static let audioStop = "audio-stop"
    public static let played = "played"
    public static let error = "error"
    public static let handled = "handled"

    // VACA additions
    public static let capabilities = "capabilities"
    public static let customEvent = "custom-event"
    public static let pipelineEnded = "pipeline-ended"
}

/// The `event_type` values carried inside a VACA `custom-event`.
public enum CustomEventType {
    public static let settings = "settings"
    public static let action = "action"
    public static let status = "status"
    public static let logs = "logs"
    public static let capabilities = "capabilities"
}

/// Microphone audio format Home Assistant expects (const.py).
public enum MicFormat {
    public static let rate = 16_000
    public static let width = 2
    public static let channels = 1
}

/// Builders for the events this app sends.
public enum SatelliteMessages {
    /// Reply to `describe` (WyomingInfoBuilder.kt). `wakeWords` are the
    /// on-device wake words, grouped by engine ("microwakeword").
    public static func info(
        name: String,
        appVersion: String,
        area: String = "",
        activeWakeWord: String,
        wakeWords: [(engine: String, id: String, phrase: String)]
    ) -> WyomingEvent {
        let empty: [String: Any] = ["name": "", "url": ""]
        let models: [[String: Any]] = wakeWords.map { w in
            [
                "name": w.id,
                "attribution": ["name": w.engine.lowercased(), "url": ""],
                "installed": true,
                "description": w.phrase,
                "version": appVersion,
                "languages": ["en"],
                "phrase": w.phrase,
            ]
        }
        let wake: [String: Any] = [
            "name": "available_wake_words",
            "attribution": empty,
            "installed": true,
            "description": "On-device wake words",
            "version": appVersion,
            "models": models,
        ]
        let satellite: [String: Any] = [
            "name": name,
            "attribution": empty,
            "installed": true,
            "description": "View Assist Companion App",
            "version": appVersion,
            "area": area,
            "has_vad": false,
            "snd_format": ["channels": 1, "rate": 16_000, "width": 2],
            "active_wake_words": [activeWakeWord],
            "max_active_wake_words": 1,
        ]
        return WyomingEvent(type: EventType.info, data: [
            "version": appVersion,
            "asr": [Any](), "tts": [Any](), "handle": [Any](), "intent": [Any](), "stt": [Any](),
            "wake": [wake],
            "satellite": satellite,
        ])
    }

    /// Reply to `capabilities` (DeviceInfo.getJson + WyomingCapabilitiesBuilder).
    /// Features iOS can't offer (camera stream, light sensor, DND) are off so
    /// HA doesn't create entities for them.
    public static func capabilities(
        appVersion: String,
        osVersion: String,
        model: String,
        hasBattery: Bool,
        wakeSounds: [(id: String, name: String)],
        alarms: [(id: String, name: String)]
    ) -> WyomingEvent {
        WyomingEvent(type: EventType.capabilities, data: [
            "device_signature": model,
            "app_version": appVersion,
            "release": osVersion,
            "has_battery": hasBattery,
            "has_front_camera": false,
            "has_rtsp": false,
            "has_dnd": false,
            "proximity_sensor_type": "none",
            "audio": [
                "max_music_volume": 10,
                "max_notification_volume": 10,
                "max_alarm_volume": 10,
                "has_agc": false,
                "has_ns": false,
                "has_aec": true,
                "inputs": [Any](),
                "outputs": [Any](),
            ],
            "sensors": [Any](),
            "wake_sounds": wakeSounds.map { ["id": $0.id, "name": $0.name] },
            "alarms": alarms.map { ["id": $0.id, "name": $0.name] },
        ])
    }

    /// A setting changed on the device, for Home Assistant (Satellite.sendSetting).
    public static func setting(_ name: String, _ value: Any) -> WyomingEvent {
        custom(CustomEventType.settings, ["timestamp": isoNow(), "settings": [name: value]])
    }

    /// `audio-stop` as the Android pipeline sends it, to end listening.
    public static func pipelineAudioStop() -> WyomingEvent {
        WyomingEvent(type: EventType.audioStop, data: ["timestamp": isoNow()])
    }

    public static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// Ask HA to run a pipeline. `start` is "wake" (HA listens for the wake
    /// word in the streamed audio) or "asr" (start listening right away).
    public static func runPipeline(start: String, end: String = "tts", restartOnEnd: Bool = false) -> WyomingEvent {
        WyomingEvent(type: EventType.runPipeline, data: [
            "start_stage": start,
            "end_stage": end,
            "restart_on_end": restartOnEnd,
            "snd_format": ["rate": 22_050, "width": 2, "channels": 1],
        ])
    }

    public static func micChunk(_ pcm: Data, timestampMs: Int) -> WyomingEvent {
        WyomingEvent(type: EventType.audioChunk, data: [
            "rate": MicFormat.rate,
            "width": MicFormat.width,
            "channels": MicFormat.channels,
            "timestamp": timestampMs,
        ], payload: pcm)
    }

    public static func audioStop(timestampMs: Int? = nil) -> WyomingEvent {
        var data: [String: Any] = [:]
        if let timestampMs { data["timestamp"] = timestampMs }
        return WyomingEvent(type: EventType.audioStop, data: data)
    }

    public static func played() -> WyomingEvent { WyomingEvent(type: EventType.played) }

    public static func pong(text: String?) -> WyomingEvent {
        var data: [String: Any] = [:]
        if let text { data["text"] = text }
        return WyomingEvent(type: EventType.pong, data: data)
    }

    /// A VACA custom event from the device. The integration reads the body
    /// from `data` (`CustomEvent.from_event`).
    public static func custom(_ eventType: String, _ body: [String: Any]) -> WyomingEvent {
        WyomingEvent(type: EventType.customEvent, data: ["event_type": eventType, "data": body])
    }

    /// Status report: sensor values and media player state.
    public static func status(sensors: [String: Any], mediaPlaying: Bool? = nil) -> WyomingEvent {
        var body: [String: Any] = ["sensors": sensors]
        if let mediaPlaying { body["media_player"] = ["playing": mediaPlaying] }
        return custom(CustomEventType.status, body)
    }

    /// An empty settings event asks HA to send all settings again.
    public static func requestSettings() -> WyomingEvent {
        WyomingEvent(type: EventType.customEvent, data: ["event_type": CustomEventType.settings])
    }

    public static func ping() -> WyomingEvent { WyomingEvent(type: EventType.ping, data: ["text": ""]) }
}

/// A VACA custom event received from HA. HA flattens the body into `data`
/// next to `event_type` (see `CustomEvent.event()` in custom.py).
public struct IncomingCustomEvent {
    public let eventType: String
    public let data: [String: Any]

    public init?(_ event: WyomingEvent) {
        guard event.type == EventType.customEvent, let type = event.string("event_type") else { return nil }
        eventType = type
        data = event.data
    }

    /// Settings in a `settings` event (all of them, or the one that changed).
    public var settings: [String: Any] { data[CustomEventType.settings] as? [String: Any] ?? [:] }

    /// The action name in an `action` event, e.g. "wake" or "play-media".
    public var action: String? { data["action"] as? String }

    /// The action's payload. Usually a dictionary; a few send a bare value.
    public var payload: Any? { data["payload"] }
}
