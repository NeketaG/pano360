import SwiftUI

private struct GalleryEntry: Identifiable {
    let id: URL
    let date: Date
    let thumbnailURL: URL?
    var hasPanorama: Bool { thumbnailURL != nil }
}

struct GalleryView: View {
    let onClose: () -> Void
    let onOpen: (URL) -> Void

    @State private var entries: [GalleryEntry] = []

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    Text("Пока нет снятых панорам")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(entries) { entry in
                            Button {
                                onOpen(entry.id)
                            } label: {
                                row(for: entry)
                            }
                            .foregroundStyle(.primary)
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Мои панорамы")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Готово") { onClose() }
                }
                if !entries.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        EditButton()
                    }
                }
            }
            .onAppear { loadEntries() }
        }
    }

    private func row(for entry: GalleryEntry) -> some View {
        HStack(spacing: 12) {
            Group {
                if let thumbURL = entry.thumbnailURL, let image = UIImage(contentsOfFile: thumbURL.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date, style: .date)
                Text(entry.date, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !entry.hasPanorama {
                    Text("Не собрана")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func loadEntries() {
        let capturesDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures")
        guard let sessionDirs = try? FileManager.default.contentsOfDirectory(
            at: capturesDir, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else {
            entries = []
            return
        }

        entries = sessionDirs.compactMap { dir -> GalleryEntry? in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let panoURL = dir.appendingPathComponent("panorama.jpg")
            let hasPano = FileManager.default.fileExists(atPath: panoURL.path)
            return GalleryEntry(id: dir, date: date, thumbnailURL: hasPano ? panoURL : nil)
        }.sorted { $0.date > $1.date }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: entries[index].id)
        }
        entries.remove(atOffsets: offsets)
    }
}
