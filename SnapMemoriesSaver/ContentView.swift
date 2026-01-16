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

struct SnapchatData: Codable, Sendable {
    let savedMedia: [Memory]
    
    enum CodingKeys: String, CodingKey {
        case savedMedia = "Saved Media"
    }
}

struct Memory: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let date: String
    let mediaType: String
    let downloadLink: String
    let mediaDownloadUrl: String?
    
    init(id: UUID = UUID(), date: String, mediaType: String, downloadLink: String, mediaDownloadUrl: String? = nil) {
        self.id = id
        self.date = date
        self.mediaType = mediaType
        self.downloadLink = downloadLink
        self.mediaDownloadUrl = mediaDownloadUrl
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case date = "Date"
        case mediaType = "Media Type"
        case downloadLink = "Download Link"
        case mediaDownloadUrl = "Media Download Url"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.date = try container.decode(String.self, forKey: .date)
        self.mediaType = try container.decode(String.self, forKey: .mediaType)
        self.downloadLink = try container.decode(String.self, forKey: .downloadLink)
        self.mediaDownloadUrl = try container.decodeIfPresent(String.self, forKey: .mediaDownloadUrl)
    }
    
    var isVideo: Bool {
        return mediaType.lowercased() == "video"
    }
    
    var year: String {
        return String(date.prefix(4))
    }
    
    var month: String {
        let start = date.index(date.startIndex, offsetBy: 5)
        let end = date.index(date.startIndex, offsetBy: 7)
        let monthNum = String(date[start..<end])
        return MonthNameHelper.name(for: monthNum)
    }
    
    var effectiveUrl: URL? {
        if let direct = mediaDownloadUrl, let url = URL(string: direct) {
            return url
        }
        return URL(string: downloadLink)
    }
}

struct MonthNameHelper {
    static func name(for number: String) -> String {
        switch number {
        case "01": return "January"; case "02": return "February"; case "03": return "March"
        case "04": return "April";   case "05": return "May";      case "06": return "June"
        case "07": return "July";    case "08": return "August";   case "09": return "September"
        case "10": return "October"; case "11": return "November"; case "12": return "December"
        default: return number
        }
    }
}

struct YearSection: Identifiable, Equatable, Sendable {
    var id: String { year }
    let year: String
    let months: [MonthSection]
}

struct MonthSection: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let memories: [Memory]
}

@MainActor
class ThumbnailLoader: ObservableObject {
    @Published var image: UIImage? = nil
    @Published var isLoading = false
    private var task: Task<Void, Never>?
    
    func load(for memory: Memory, fileURL: URL?) {
        guard image == nil else { return }
        
        let targetURL = fileURL ?? memory.effectiveUrl
        guard let url = targetURL else { return }
        
        task?.cancel()
        isLoading = true
        
        task = Task.detached(priority: .userInitiated) {
            var loadedImage: UIImage? = nil
            
            if memory.isVideo {
                let asset = AVURLAsset(url: url)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 200, height: 200)
                
                do {
                    if #available(iOS 16.0, *) {
                        let (cgImage, _) = try await gen.image(at: .zero)
                        loadedImage = UIImage(cgImage: cgImage)
                    } else {
                        let cgImage = try gen.copyCGImage(at: .zero, actualTime: nil)
                        loadedImage = UIImage(cgImage: cgImage)
                    }
                } catch { }
            } else {
                if let data = try? Data(contentsOf: url) {
                    loadedImage = UIImage(data: data)
                }
            }
            
            if !Task.isCancelled {
                let finalImage = loadedImage
                await MainActor.run {
                    self.image = finalImage
                    self.isLoading = false
                }
            }
        }
    }
}

@MainActor
class DownloadManager: ObservableObject {
    @Published var sections: [YearSection] = []
    @Published var allMemories: [Memory] = []
    @Published var downloadedFiles: [String: URL] = [:]
    @Published var isDownloading = false
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = "Import JSON to start"
    @Published var isProcessing = false
    
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
        let memoriesToSave = self.allMemories
        let file = self.persistenceFile
        Task.detached {
            do {
                let data = try JSONEncoder().encode(memoriesToSave)
                try data.write(to: file)
            } catch { }
        }
    }
    
    private func loadFromDisk() {
        if let data = try? Data(contentsOf: persistenceFile),
           let savedMemories = try? JSONDecoder().decode([Memory].self, from: data) {
            Task {
                let processedSections = await DownloadManager.processMemories(savedMemories)
                self.sections = processedSections
                self.allMemories = savedMemories
                self.refreshDownloadedFiles()
                self.statusMessage = "Loaded \(savedMemories.count) memories from storage."
            }
        }
    }
    
    private func refreshDownloadedFiles() {
        var tempMap: [String: URL] = [:]
        for memory in allMemories {
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
        isProcessing = true
        statusMessage = "Processing..."
        
        Task {
            do {
                var data: Data?
                if url.startAccessingSecurityScopedResource() {
                    data = try Data(contentsOf: url)
                    url.stopAccessingSecurityScopedResource()
                } else {
                    data = try Data(contentsOf: url)
                }
                
                guard let jsonData = data else {
                    self.statusMessage = "Failed to read file"
                    self.isProcessing = false
                    return
                }
                
                let result = try JSONDecoder().decode(SnapchatData.self, from: jsonData)
                let rawMemories = result.savedMedia
                
                let processedSections = await DownloadManager.processMemories(rawMemories)
                
                self.sections = processedSections
                self.allMemories = rawMemories
                self.saveToDisk()
                self.refreshDownloadedFiles()
                self.statusMessage = "Imported \(rawMemories.count) memories. Ready to download."
                self.isProcessing = false
                
            } catch {
                self.statusMessage = "Error: \(error.localizedDescription)"
                self.isProcessing = false
            }
        }
    }
    
    private static func processMemories(_ rawMemories: [Memory]) async -> [YearSection] {
        let groupedByYear = Dictionary(grouping: rawMemories, by: { $0.year })
        let sortedYears = groupedByYear.keys.sorted(by: >)
        
        var newSections: [YearSection] = []
        
        for year in sortedYears {
            let memoriesInYear = groupedByYear[year]!
            let groupedByMonth = Dictionary(grouping: memoriesInYear, by: { $0.month })
            
            let sortedMonthNames = groupedByMonth.keys.sorted { m1, m2 in
                let d1 = groupedByMonth[m1]?.first?.date ?? ""
                let d2 = groupedByMonth[m2]?.first?.date ?? ""
                return d1 > d2
            }
            
            var monthSections: [MonthSection] = []
            for month in sortedMonthNames {
                let items = groupedByMonth[month] ?? []
                monthSections.append(MonthSection(name: month, memories: items))
            }
            
            newSections.append(YearSection(year: year, months: monthSections))
        }
        return newSections
    }
    
    func startDownload() {
        guard !allMemories.isEmpty else { return }
        isDownloading = true
        progress = 0.0
        
        Task {
            let total = Double(allMemories.count)
            var currentProgress = 0.0
            let maxConcurrent = 5
            var iterator = allMemories.makeIterator()
            
            await withTaskGroup(of: URL?.self) { group in
                for _ in 0..<maxConcurrent {
                    if let next = iterator.next() {
                        group.addTask { await self.downloadSingleMemory(next) }
                    }
                }
                
                for await url in group {
                    currentProgress += 1
                    let prog = currentProgress / total
                    
                    await MainActor.run {
                        self.progress = prog
                        if let validUrl = url {
                            
                            if let mem = self.allMemories.first(where: { self.getLocalFileURL(for: $0) == validUrl }) {
                                self.downloadedFiles[mem.date] = validUrl
                            }
                        }
                    }
                    
                    if let next = iterator.next() {
                        group.addTask { await self.downloadSingleMemory(next) }
                    }
                }
            }
            
            self.isDownloading = false
            self.statusMessage = "Download Complete!"
            self.refreshDownloadedFiles()
        }
    }
    
    private func downloadSingleMemory(_ memory: Memory) async -> URL? {
        let fileURL = getLocalFileURL(for: memory)
        
        if fileManager.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        
        guard let urlStr = memory.effectiveUrl?.absoluteString, let url = URL(string: urlStr) else { return nil }
        
        var request = URLRequest(url: url)
        if memory.mediaDownloadUrl == nil {
            request.httpMethod = "POST"
        }
        
        do {
            let (downloadUrl, _) : (URL, URLResponse)
            
            if memory.mediaDownloadUrl != nil {
                downloadUrl = url
            } else {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let realLink = String(data: data, encoding: .utf8),
                      let realURL = URL(string: realLink) else { return nil }
                downloadUrl = realURL
            }
            
            let (mediaData, _) = try await URLSession.shared.data(from: downloadUrl)
            try mediaData.write(to: fileURL)
            return fileURL
            
        } catch {
            return nil
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
                    
                    if manager.isProcessing {
                        VStack {
                            Spacer()
                            ProgressView()
                            Text("Processing Data...").padding(.top)
                            Spacer()
                        }
                    } else if manager.sections.isEmpty {
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
        List {
            ForEach(manager.sections, id: \.id) { yearSection in
                Section(header: Text(yearSection.year).font(.headline)) {
                    ForEach(yearSection.months, id: \.id) { monthSection in
                        VStack(alignment: .leading) {
                            Text(monthSection.name)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.top, 5)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 10) {
                                    ForEach(monthSection.memories, id: \.id) { memory in
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
                
                if !manager.allMemories.isEmpty && !manager.isDownloading {
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
    @StateObject private var thumbLoader = ThumbnailLoader()
    
    var body: some View {
        ZStack {
            if let url = fileURL {
                if memory.isVideo {
                    if let thumb = thumbLoader.image {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.black.opacity(0.8)
                            if thumbLoader.isLoading {
                                ProgressView().tint(.white)
                            }
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
        .onAppear {
            thumbLoader.load(for: memory, fileURL: fileURL)
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
                Alert(title: Text("Saved"), message: Text("Saved Successfully."), dismissButton: .default(Text("OK")))
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
