import Foundation

/// Same 3 stages/thresholds as claude.ai, confirmed by reading the site's JS
/// bundle (see PanelView's usage bar) — shared here so the notification
/// monitor and the panel's progress-bar color never drift apart.
public enum UsageThresholds {
    public static let warning: Double = 75
    public static let critical: Double = 90
    /// Fully out of quota — claude.ai stops serving requests at this point.
    /// Distinct from `critical`: a "your quota is back" notification is only
    /// worth sending when the window was actually exhausted, not merely high
    /// — someone at 80% who never got blocked doesn't need to be told the
    /// window reset, they were never stopped by it.
    public static let exhausted: Double = 100
}
