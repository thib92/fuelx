import SwiftUI

/// Credits for the food data, as its licences require.
struct AboutView: View {
    var body: some View {
        List {
            Section("Food Data") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Contains data from Open Food Facts, available under the Open Database License.")
                    Link("Open Food Facts", destination: URL(string: "https://world.openfoodfacts.org")!)
                    Link("Open Database License", destination: URL(string: "https://opendatacommons.org/licenses/odbl/1-0/")!)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Food composition data from the ANSES-Ciqual table, available under Licence Ouverte.")
                    Link("ANSES-Ciqual", destination: URL(string: "https://ciqual.anses.fr")!)
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
