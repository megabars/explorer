import SwiftUI

struct SettingsView: View {
    private let preferences = LanguagePreferences()
    @State private var selection = LanguagePreferences().selection

    var body: some View {
        Form {
            Picker(L10n.text("Language"), selection: $selection) {
                Text(L10n.text("Same as System"))
                    .tag(nil as InterfaceLanguage?)
                ForEach(InterfaceLanguage.allCases, id: \.self) { language in
                    Text(language.nativeName)
                        .tag(Optional(language))
                }
            }

            Text(L10n.text("Language changes take effect the next time you open Explorer."))
                .foregroundStyle(.secondary)
            if selection != L10n.launchSelection {
                Text(L10n.text("Restart Explorer to apply the selected language."))
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: selection) { _, newValue in
            preferences.selection = newValue
        }
    }
}
