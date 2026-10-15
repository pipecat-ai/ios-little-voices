import Foundation

struct UserProfile: Codable, Equatable, Sendable {
    var preferredName: String

    init(preferredName: String = "") {
        self.preferredName = Self.normalize(preferredName)
    }

    /// Keep a short, single-line name while preserving Unicode spelling.
    static func normalize(_ value: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in value.unicodeScalars {
            if separators.contains(scalar) {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if pendingSpace {
                // A separator is useful only when another name scalar fits too.
                guard scalars.count < 79 else { break }
                scalars.append(" ")
                pendingSpace = false
            }
            guard scalars.count < 80 else { break }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private enum CodingKeys: String, CodingKey { case preferredName }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preferredName = Self.normalize(try values.decodeIfPresent(String.self, forKey: .preferredName) ?? "")
    }
}

enum ProfileSettings {
    private static let profileKey = "user-profile"

    static func load(defaults: UserDefaults = .standard) -> UserProfile {
        guard let data = defaults.data(forKey: profileKey),
              let profile = try? JSONDecoder().decode(UserProfile.self, from: data) else {
            return UserProfile()
        }
        return profile
    }

    static func save(_ profile: UserProfile, defaults: UserDefaults = .standard) throws {
        let normalized = UserProfile(preferredName: profile.preferredName)
        if normalized.preferredName.isEmpty {
            defaults.removeObject(forKey: profileKey)
        } else {
            defaults.set(try JSONEncoder().encode(normalized), forKey: profileKey)
        }
    }
}
