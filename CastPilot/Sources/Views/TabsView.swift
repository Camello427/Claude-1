import SwiftUI

/// All open tabs, with previews.
struct TabsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(app.tabs.tabs) { tab in
                        TabCard(tab: tab, isCurrent: tab.id == app.tabs.currentID) {
                            app.tabs.select(tab)
                            dismiss()
                        } close: {
                            withAnimation { app.tabs.close(tab) }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(app.tabs.tabs.count) tab\(app.tabs.tabs.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { app.tabs.newTab(); dismiss() } label: { Label("New tab", systemImage: "plus") }
                        Button { app.tabs.newTab(isPrivate: true); dismiss() } label: { Label("New private tab", systemImage: "eyeglasses") }
                        if app.tabs.tabs.contains(where: \.isPrivate) {
                            Divider()
                            Button(role: .destructive) { app.tabs.closeAllPrivate() } label: {
                                Label("Close all private tabs", systemImage: "xmark")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New tab")
                }
            }
        }
    }
}

private struct TabCard: View {
    let tab: BrowserModel
    let isCurrent: Bool
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image = tab.snapshot {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            ZStack {
                                Color(.secondarySystemBackground)
                                Image(systemName: tab.isPrivate ? "eyeglasses" : "globe")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(height: 190)
                    .frame(maxWidth: .infinity)
                    .clipped()

                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Color.black.opacity(0.55), in: Circle())
                    }
                    .padding(6)
                    .accessibilityLabel("Close tab")
                }
                HStack(spacing: 6) {
                    if tab.isPrivate {
                        Image(systemName: "eyeglasses").foregroundStyle(.purple)
                    }
                    Text(tab.displayTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !tab.visibleMedia.isEmpty {
                        Image(systemName: "film").font(.caption2).foregroundStyle(Color.accentColor)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tab.isPrivate ? Color.purple.opacity(0.12) : Color(.systemBackground))
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}
