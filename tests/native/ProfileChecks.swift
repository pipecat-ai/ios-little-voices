import Foundation

@main
struct ProfileChecks {
    static func main() throws {
        precondition(UserProfile().preferredName.isEmpty)
        precondition(UserProfile.normalize(" \n\tJon\r ") == "Jon")
        precondition(UserProfile.normalize("  Jean\t\nLuc  ") == "Jean Luc")
        precondition(UserProfile.normalize("A\u{0000}\u{001B}B") == "A B")
        precondition(UserProfile.normalize("\u{00A0}José\u{2003}María\u{00A0}") == "José María")
        precondition(UserProfile.normalize("İpek 李 O’Connor") == "İpek 李 O’Connor")
        precondition(UserProfile.normalize("\u{0000}\n\t ").isEmpty)
        precondition(UserProfile.normalize(String(repeating: "🦊", count: 100)).unicodeScalars.count == 80)
        precondition(UserProfile.normalize(String(repeating: "a", count: 79) + " b") == String(repeating: "a", count: 79))
        precondition(UserProfile.normalize(String(repeating: "a", count: 78) + " b") == String(repeating: "a", count: 78) + " b")
        let decomposed = String(repeating: "e\u{0301}", count: 50)
        precondition(UserProfile.normalize(decomposed).unicodeScalars.count == 80)
        for value in ["", " Jon ", "Jean\nLuc", decomposed, String(repeating: "x", count: 200)] {
            let normalized = UserProfile.normalize(value)
            precondition(UserProfile.normalize(normalized) == normalized)
        }

        let suite = "dev.pipecat.profile-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(ProfileSettings.load(defaults: defaults) == UserProfile())
        defaults.set("preserve", forKey: "unrelated-setting")
        try ProfileSettings.save(UserProfile(preferredName: "  Jon  "), defaults: defaults)
        precondition(ProfileSettings.load(defaults: defaults).preferredName == "Jon")
        let persisted = defaults.persistentDomain(forName: suite)!
        precondition(Set(persisted.keys) == ["user-profile", "unrelated-setting"])
        let json = try JSONSerialization.jsonObject(with: defaults.data(forKey: "user-profile")!) as! [String: String]
        precondition(json == ["preferredName": "Jon"])

        var changed = UserProfile()
        changed.preferredName = "\n  José \t María  "
        try ProfileSettings.save(changed, defaults: defaults)
        precondition(ProfileSettings.load(defaults: defaults).preferredName == "José María")
        precondition(ProfileSettings.load(defaults: UserDefaults(suiteName: suite)!) == ProfileSettings.load(defaults: defaults))

        defaults.set(Data("{\"preferredName\":\"  李 \\n 华  \"}".utf8), forKey: "user-profile")
        precondition(ProfileSettings.load(defaults: defaults).preferredName == "李 华")
        for invalid in ["not json", "{\"preferredName\":4}"] {
            defaults.set(Data(invalid.utf8), forKey: "user-profile")
            precondition(ProfileSettings.load(defaults: defaults) == UserProfile())
        }
        defaults.set(Data("{}".utf8), forKey: "user-profile")
        precondition(ProfileSettings.load(defaults: defaults) == UserProfile())

        try ProfileSettings.save(UserProfile(preferredName: " \n "), defaults: defaults)
        precondition(defaults.object(forKey: "user-profile") == nil)
        precondition(defaults.string(forKey: "unrelated-setting") == "preserve")
        precondition(ProfileSettings.load(defaults: defaults) == UserProfile())
        // The angel and the devil are fixed: Python names them by these ids (mobile_app/duo.py).
        precondition(DuoCharacter.allCases.map(\.rawValue) == ["angel", "devil"])
        precondition(DuoCharacter.allCases.map(\.title) == ["Angel", "Devil"])

        print("PROFILE_CHECKS_PASSED: normalization, Unicode bounds, persistence, malformed data, clearing, characters")
    }
}
