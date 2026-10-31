import Foundation

/// このアプリの名前と版。App・CLI・MCP が使う（依存は下向きだけなので、`Core` に置く）。
public enum AppInfo {
    /// `Resources/Info.plist` の版と同じ（テストで一致を確認する）。
    public static let version = "0.1.14"
    public static let name = "meeting-analyzer"
}
