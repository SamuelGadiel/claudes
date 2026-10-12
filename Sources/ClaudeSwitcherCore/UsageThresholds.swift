import Foundation

/// Same 3 stages/thresholds as claude.ai, confirmed by reading the site's JS
/// bundle (see PanelView's usage bar) — shared here so the notification
/// monitor and the panel's progress-bar color never drift apart.
public enum UsageThresholds {
    public static let warning: Double = 75
    public static let critical: Double = 90
}
