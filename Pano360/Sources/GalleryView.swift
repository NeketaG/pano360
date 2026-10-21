import SwiftUI

private struct GalleryEntry: Identifiable {
    let id: URL
    let date: Date
    let hasPanorama: Bool
    let thumbnail: UIImage?
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
                if let thumbnail = entry.thumbnail {
                    Image(uiImage: thumbnail)
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
            // Панорама 8192×4096 — для превью декодируем только уменьшенную копию
            let thumbnail = hasPano
                ? PanoramaStitcher.downsampledImage(at: panoURL, maxPixelSize: 256).map { UIImage(cgImage: $0.image) }
                : nil
            return GalleryEntry(id: dir, date: date, hasPanorama: hasPano, thumbnail: thumbnail)
        }.sorted { $0.date > $1.date }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: entries[index].id)
        }
        entries.remove(atOffsets: offsets)
    }
}
