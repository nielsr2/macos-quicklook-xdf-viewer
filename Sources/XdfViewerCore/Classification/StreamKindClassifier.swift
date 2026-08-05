import Foundation

/// Maps a stream's raw XDF `type` string (e.g. "EEG", "Markers", "Accelerometer")
/// to a display icon (SF Symbol) and a short human-readable label.
///
/// This pass is SF-Symbols-only: no Material-Design-Icon ports yet (deferred to
/// a later polish stage). Unrecognized
/// or missing types fall back to a generic icon/label rather than failing.
public enum StreamKindClassifier {

    /// Result of classifying a stream's `type` string.
    public struct Classification: Sendable, Equatable {
        public var iconSystemName: String
        public var label: String

        public init(iconSystemName: String, label: String) {
            self.iconSystemName = iconSystemName
            self.label = label
        }

        /// Generic fallback for unrecognized or empty stream types.
        public static func fallback(rawType: String) -> Classification {
            let trimmed = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
            return Classification(iconSystemName: "questionmark.circle",
                                   label: trimmed.isEmpty ? "Unknown" : trimmed)
        }
    }

    /// Known stream kinds, matched case-insensitively against the raw `type`
    /// string. Ordered roughly by how common each kind is in LSL/LabRecorder
    /// recordings.
    private static let table: [(matches: Set<String>, classification: Classification)] = [
        (["eeg"], Classification(iconSystemName: "brain.head.profile", label: "EEG")),
        (["ecg", "ekg"], Classification(iconSystemName: "heart.text.square", label: "ECG")),
        (["emg"], Classification(iconSystemName: "waveform.path", label: "EMG")),
        (["eog"], Classification(iconSystemName: "eye", label: "EOG")),
        (["gsr", "eda"], Classification(iconSystemName: "drop.halffull", label: "GSR")),
        (["accelerometer", "acc", "imu"], Classification(iconSystemName: "gyroscope", label: "Accelerometer")),
        (["gaze", "eyetracking", "eye-tracking"], Classification(iconSystemName: "scope", label: "Gaze")),
        (["markers", "marker", "events", "event"], Classification(iconSystemName: "flag.fill", label: "Markers")),
        (["audio"], Classification(iconSystemName: "waveform", label: "Audio")),
        (["video"], Classification(iconSystemName: "video.fill", label: "Video")),
        (["mocap", "motioncapture"], Classification(iconSystemName: "figure.walk.motion", label: "Motion Capture")),
    ]

    /// Classify a stream's raw `type` string into an icon + display label.
    public static func classify(type: String) -> Classification {
        let normalized = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .fallback(rawType: type) }
        for entry in table where entry.matches.contains(normalized) {
            return entry.classification
        }
        return .fallback(rawType: type)
    }
}
