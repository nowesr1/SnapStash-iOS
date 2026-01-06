//
//  ContentView.swift
//  SnapMemoriesSaver
//
//  Created by Nasser Alsobeie on 02/01/2026.
//

import SwiftUI
import AVKit
import Photos
import UniformTypeIdentifiers
import MobileCoreServices

struct SnapchatData: Codable {
    let savedMedia: [Memory]
    
    enum CodingKeys: String, CodingKey {
        case savedMedia = "Saved Media"
    }
}

struct Memory: Codable, Identifiable, Equatable {
    let id: UUID
    let date: String
    let mediaType: String
    let downloadLink: String
    
    init(id: UUID = UUID(), date: String, mediaType: String, downloadLink: String) {
        self.id = id
        self.date = date
        self.mediaType = mediaType
        self.downloadLink = downloadLink
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case date = "Date"
        case mediaType = "Media Type"
        case downloadLink = "Download Link"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.date = try container.decode(String.self, forKey: .date)
        self.mediaType = try container.decode(String.self, forKey: .mediaType)
        self.downloadLink = try container.decode(String.self, forKey: .downloadLink)
    }
    
    var isVideo: Bool {
        return mediaType.lowercased() == "video"
    }
    
    var dateObject: Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: date) ?? Date.distantPast
    }
    
    var year: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: dateObject)
    }
    
    var month: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        return formatter.string(from: dateObject)
    }
}

@MainActor
class DownloadManager: ObservableObject {
    @Published var memories: [Memory] = []
    @Published var downloadedFiles: [String: URL] = [:]
    @Published var isDownloading = false
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = "Import JSON to start"
    
    private let fileManager = FileManager.default
    
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    private var persistenceFile: URL {
        documentsDirectory.appendingPathComponent("saved_memories.json")
    }
    
    init() {
        loadFromDisk()
    }
    
    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(memories)
            try data.write(to: persistenceFile)
        } catch {
            print("Failed to save memories list: \(error)")
        }
    }
    
    private func loadFromDisk() {
        if let data = try? Data(contentsOf: persistenceFile),
           let savedMemories = try? JSONDecoder().decode([Memory].self, from: data) {
            self.memories = savedMemories
            self.statusMessage = "Loaded \(savedMemories.count) memories from storage."
        }
        refreshDownloadedFiles()
    }
    
    private func refreshDownloadedFiles() {
        var tempMap: [String: URL] = [:]
        for memory in memories {
            let fileURL = getLocalFileURL(for: memory)
            if fileManager.fileExists(atPath: fileURL.path) {
                tempMap[memory.date] = fileURL
            }
        }
        self.downloadedFiles = tempMap
    }
    
    private func getLocalFileURL(for memory: Memory) -> URL {
        let safeDate = memory.date.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_")
        let ext = memory.isVideo ? "mp4" : "jpg"
        let filename = "\(safeDate).\(ext)"
        return documentsDirectory.appendingPathComponent(filename)
    }

    func loadJSON(url: URL) {
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            let data = try Data(contentsOf: url)
            if accessing { url.stopAccessingSecurityScopedResource() }
            
            let decoder = JSONDecoder()
            let result = try decoder.decode(SnapchatData.self, from: data)
            
            self.memories = result.savedMedia.sorted(by: { $0.dateObject > $1.dateObject })
            saveToDisk()
            refreshDownloadedFiles()
            
            self.statusMessage = "Imported \(memories.count) memories. Ready to download."
        } catch {
            self.statusMessage = "Error parsing JSON: \(error.localizedDescription)"
        }
    }
    
    func startDownload() {
        guard !memories.isEmpty else { return }
        isDownloading = true
        progress = 0.0
        
        Task {
            var completedCount = 0
            
            for memory in memories {
                await downloadSingleMemory(memory)
                completedCount += 1
                self.progress = Double(completedCount) / Double(memories.count)
            }
            
            self.isDownloading = false
            self.statusMessage = "Download Complete!"
            refreshDownloadedFiles()
        }
    }
    
    private func downloadSingleMemory(_ memory: Memory) async {
        let fileURL = getLocalFileURL(for: memory)
        
        if fileManager.fileExists(atPath: fileURL.path) {
            return
        }
        
        guard let postURL = URL(string: memory.downloadLink) else { return }
        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let realLink = String(data: data, encoding: .utf8),
                  let downloadURL = URL(string: realLink) else { return }
            
            let (mediaData, _) = try await URLSession.shared.data(from: downloadURL)
            try mediaData.write(to: fileURL)
            
            await MainActor.run {
                self.downloadedFiles[memory.date] = fileURL
            }
        } catch {
            print("Failed to download: \(error)")
        }
    }
}

struct LegacyDocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.json], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (URL) -> Void
        
        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

struct ContentView: View {
    @StateObject var manager = DownloadManager()
    @State private var showLegacyPicker = false
    @State private var selectedMemory: Memory?
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()
                
                VStack(spacing: 0) {
                    VStack(spacing: 12) {
                        Text(manager.statusMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        if manager.isDownloading {
                            VStack {
                                ProgressView(value: manager.progress)
                                    .tint(.blue)
                                Text("\(Int(manager.progress * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical, 20)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    
                    if manager.memories.isEmpty {
                        emptyStateView
                    } else {
                        memoryListView
                    }
                    
                    footerView
                }
            }
            .navigationTitle("SnapStash")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showLegacyPicker) {
                LegacyDocumentPicker { url in
                    manager.loadJSON(url: url)
                }
            }
            .sheet(item: $selectedMemory) { memory in
                MediaDetailView(memory: memory, fileURL: manager.downloadedFiles[memory.date])
            }
        }
    }
    
    var memoryListView: some View {
        let groupedByYear = Dictionary(grouping: manager.memories, by: { $0.year })
        let sortedYears = groupedByYear.keys.sorted(by: >)
        
        return List {
            ForEach(sortedYears, id: \.self) { year in
                Section(header: Text(year).font(.headline)) {
                    
                    let memoriesInYear = groupedByYear[year]!
                    let groupedByMonth = Dictionary(grouping: memoriesInYear, by: { $0.month })
                    let sortedMonths = groupedByMonth.keys.sorted { m1, m2 in
                        let d1 = memoriesInYear.first(where: { $0.month == m1 })?.dateObject ?? Date.distantPast
                        let d2 = memoriesInYear.first(where: { $0.month == m2 })?.dateObject ?? Date.distantPast
                        return d1 > d2
                    }
                    
                    ForEach(sortedMonths, id: \.self) { month in
                        VStack(alignment: .leading) {
                            Text(month)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.top, 5)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 10) {
                                    ForEach(groupedByMonth[month]!) { memory in
                                        MemoryThumbnail(memory: memory, fileURL: manager.downloadedFiles[memory.date])
                                            .onTapGesture {
                                                if manager.downloadedFiles[memory.date] != nil {
                                                    selectedMemory = memory
                                                }
                                            }
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 0))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.5))
            Text("Import JSON to start")
                .font(.headline)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
    
    var footerView: some View {
        VStack(spacing: 15) {
            Divider()
            HStack {
                Button(action: { showLegacyPicker = true }) {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text("Import JSON")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                if !manager.memories.isEmpty && !manager.isDownloading {
                    Button(action: { manager.startDownload() }) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Download All")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal)
            
            Link(destination: URL(string: "https://x.com/nowesr1")!) {
                Text("Developer Nasser | NoTimeToChill")
                    .font(.footnote)
                    .foregroundColor(.blue)
            }
            .padding(.bottom, 5)
        }
        .background(Color(UIColor.systemBackground))
    }
}

struct MemoryThumbnail: View {
    let memory: Memory
    let fileURL: URL?
    @State private var thumbnail: UIImage? = nil
    
    var body: some View {
        ZStack {
            if let url = fileURL {
                if memory.isVideo {
                    if let thumb = thumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.black.opacity(0.8)
                            ProgressView().tint(.white)
                        }
                    }
                    ZStack {
                        Color.black.opacity(0.2)
                        Image(systemName: "play.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                    }
                } else {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.gray.opacity(0.3)
                    }
                }
            } else {
                ZStack {
                    Color.gray.opacity(0.1)
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundColor(.blue)
                }
            }
        }
        .frame(width: 100, height: 150)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
        .task {
            if memory.isVideo, let url = fileURL, thumbnail == nil {
                self.thumbnail = await generateVideoThumbnail(url: url)
            }
        }
    }
    
    func generateVideoThumbnail(url: URL) async -> UIImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.5, preferredTimescale: 60)
        do {
            let imgRef = try generator.copyCGImage(at: time, actualTime: nil)
            return UIImage(cgImage: imgRef)
        } catch {
            return nil
        }
    }
}

struct MediaDetailView: View {
    let memory: Memory
    let fileURL: URL?
    @Environment(\.presentationMode) var presentationMode
    @State private var showSaveAlert = false
    @State private var showShareSheet = false
    @State private var player: AVPlayer?
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if let url = fileURL {
                    if memory.isVideo {
                        VideoPlayer(player: player)
                            .onAppear {
                                self.player = AVPlayer(url: url)
                                self.player?.play()
                            }
                            .onDisappear {
                                self.player?.pause()
                            }
                    } else {
                        AsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fit)
                        } placeholder: {
                            ProgressView()
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        self.player?.pause()
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 20) {
                        Button(action: { showShareSheet = true }) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        
                        Button(action: saveAsNew) {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                }
            }
            .alert(isPresented: $showSaveAlert) {
                Alert(title: Text("Saved"), message: Text("Saved as New to Recents."), dismissButton: .default(Text("OK")))
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = fileURL {
                    ShareSheet(activityItems: [url])
                }
            }
        }
    }
    
    func saveAsNew() {
        guard let url = fileURL else { return }
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }
            
            PHPhotoLibrary.shared().performChanges {
                let request: PHAssetChangeRequest
                if memory.isVideo {
                    request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)!
                } else {
                    request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)!
                }
                request.creationDate = Date()
            } completionHandler: { success, error in
                if success {
                    DispatchQueue.main.async { showSaveAlert = true }
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
