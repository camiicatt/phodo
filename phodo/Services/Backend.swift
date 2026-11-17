import Supabase
import SwiftUI

/// Connection to Supabase. Values come from Config/Secrets.xcconfig → Info.plist.
/// If they're missing, `client` is nil and the app runs on the in-memory mocks.
enum Backend {
    static let client: SupabaseClient? = {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "SupabaseHost") as? String, !host.isEmpty,
              let key = Bundle.main.object(forInfoDictionaryKey: "SupabaseKey") as? String, !key.isEmpty,
              let url = URL(string: "https://\(host)") else { return nil }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }()

    static var isLive: Bool { client != nil }
}

/// Postgres error code for "unique constraint violated".
let uniqueViolation = "23505"

func isUniqueViolation(_ error: Error) -> Bool {
    (error as? PostgrestError)?.code == uniqueViolation
}

extension UUID {
    /// Supabase's auth.uid()::text is lowercase; Swift's uuidString is uppercase.
    /// Storage paths must match exactly, so always use this for paths.
    var lower: String { uuidString.lowercased() }
}

extension UIColor {
    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

extension Color {
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
