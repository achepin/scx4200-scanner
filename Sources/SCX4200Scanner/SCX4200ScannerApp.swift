import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let scannerPaths = [
    "/opt/homebrew/bin/scanimage", // Homebrew on Apple Silicon
    "/usr/local/bin/scanimage",    // Homebrew on Intel Macs
    "/usr/bin/scanimage"           // A manually installed SANE backend
]

enum ScanMode: String, CaseIterable, Identifiable {
    case color = "Цвет"
    case gray = "Оттенки серого"

    var id: String { rawValue }
    var argument: String { self == .color ? "Color" : "Gray" }
}

enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case pdf = "PDF"
    case png = "PNG"
    case jpeg = "JPEG"

    var id: String { rawValue }
    var fileExtension: String { rawValue.lowercased() }
}

struct ScanReview: Identifiable, Sendable {
    let id = UUID()
    let originalURL: URL
    let whiteBackgroundURL: URL
    let destinationURL: URL
    let outputFormat: OutputFormat
    let temporaryDirectory: URL
}

@MainActor
final class ScannerViewModel: ObservableObject {
    @Published var mode: ScanMode = .color
    @Published var resolution = 300
    @Published var outputFormat: OutputFormat = .pdf
    @Published var reduceBanding = true
    @Published var suggestWhiteBackground = true
    @Published var isScanning = false
    @Published var message = "Готов к сканированию"
    @Published var errorMessage: String?
    @Published var review: ScanReview?

    func scan() {
        guard let scannerPath = Self.scannerPath() else {
            errorMessage = "Не найден компонент сканирования. Он должен быть установлен через Homebrew: sane-backends."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Сохранить скан"
        panel.nameFieldStringValue = "Скан \(Self.timestamp()).\(outputFormat.fileExtension)"
        panel.allowedContentTypes = switch outputFormat {
        case .pdf: [.pdf]
        case .png: [.png]
        case .jpeg: [.jpeg]
        }
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let requestedMode = mode
        let requestedResolution = resolution
        let requestedFormat = outputFormat
        let shouldReduceBanding = reduceBanding
        let shouldSuggestWhiteBackground = suggestWhiteBackground
        isScanning = true
        message = "Сканирование..."
        errorMessage = nil

        Task.detached {
            do {
                let scannerDevice = try await Self.waitForScanner(using: scannerPath)
                let temporaryDirectory = try FileManager.default.url(
                    for: .itemReplacementDirectory,
                    in: .userDomainMask,
                    appropriateFor: destination,
                    create: true
                )
                let intermediate = temporaryDirectory.appendingPathComponent("scan.png")
                let scanArguments = [
                    "-d", scannerDevice,
                    "--source", "Flatbed",
                    "--format=png",
                    "--mode", requestedMode.argument,
                    "--resolution", String(requestedResolution)
                ]
                let scanTimeout: TimeInterval = requestedResolution == 600 ? 240 : 90

                do {
                    try Self.run(scannerPath, arguments: scanArguments, output: intermediate, timeout: scanTimeout)
                } catch {
                    try? FileManager.default.removeItem(at: intermediate)
                    try await Task.sleep(for: .seconds(1))
                    try Self.run(scannerPath, arguments: scanArguments, output: intermediate, timeout: scanTimeout)
                }

                if shouldReduceBanding {
                    try StripeReducer.reduceVerticalBanding(in: intermediate)
                }

                let original = temporaryDirectory.appendingPathComponent("original.png")
                try FileManager.default.moveItem(at: intermediate, to: original)

                if shouldSuggestWhiteBackground {
                    let whiteBackground = temporaryDirectory.appendingPathComponent("white-background.png")
                    try FileManager.default.copyItem(at: original, to: whiteBackground)
                    try BackgroundWhitening.whitenOuterBackground(in: whiteBackground)
                    let scanReview = ScanReview(
                        originalURL: original,
                        whiteBackgroundURL: whiteBackground,
                        destinationURL: destination,
                        outputFormat: requestedFormat,
                        temporaryDirectory: temporaryDirectory
                    )
                    await MainActor.run {
                        self.isScanning = false
                        self.message = "Выберите вариант для сохранения"
                        self.review = scanReview
                    }
                } else {
                    try Self.export(original, format: requestedFormat, destination: destination)
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                    await MainActor.run {
                        self.isScanning = false
                        self.message = "Готово: \(destination.lastPathComponent)"
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                }
            } catch {
                await MainActor.run {
                    self.isScanning = false
                    self.message = "Сканирование не выполнено"
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func saveReview(_ review: ScanReview, withWhiteBackground: Bool) {
        self.review = nil
        isScanning = true
        message = "Сохранение..."

        Task.detached {
            do {
                let source = withWhiteBackground ? review.whiteBackgroundURL : review.originalURL
                try Self.export(source, format: review.outputFormat, destination: review.destinationURL)
                try? FileManager.default.removeItem(at: review.temporaryDirectory)
                await MainActor.run {
                    self.isScanning = false
                    self.message = "Готово: \(review.destinationURL.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([review.destinationURL])
                }
            } catch {
                try? FileManager.default.removeItem(at: review.temporaryDirectory)
                await MainActor.run {
                    self.isScanning = false
                    self.message = "Не удалось сохранить скан"
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelReview(_ review: ScanReview) {
        self.review = nil
        try? FileManager.default.removeItem(at: review.temporaryDirectory)
        message = "Скан не сохранён"
    }

    nonisolated private static func export(_ source: URL, format: OutputFormat, destination: URL) throws {
        if format == .pdf {
            try run("/usr/bin/sips", arguments: ["-s", "format", "pdf", source.path, "--out", destination.path])
        } else if format == .jpeg {
            try run("/usr/bin/sips", arguments: ["-s", "format", "jpeg", "-s", "formatOptions", "90", source.path, "--out", destination.path])
        } else {
            try FileManager.default.removeItemIfPresent(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    nonisolated private static func run(_ executable: String, arguments: [String], output: URL? = nil, timeout: TimeInterval = 90) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        var outputHandle: FileHandle?

        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            process.standardOutput = handle
            outputHandle = handle
        }
        defer { try? outputHandle?.close() }

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        guard completion.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = completion.wait(timeout: .now() + 2)
            throw ScanError.timedOut
        }
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Неизвестная ошибка сканера."
            throw ScanError.failed("\(detail.trimmingCharacters(in: .whitespacesAndNewlines))\n\nЕсли это повторится: выключите МФУ кнопкой питания на 10 секунд, включите его и запустите сканирование снова.")
        }
    }

    nonisolated private static func waitForScanner(using scannerPath: String) async throws -> String {
        for attempt in 0..<10 {
            if let scannerDevice = scannerDevice(using: scannerPath) { return scannerDevice }
            if attempt < 9 { try await Task.sleep(for: .seconds(2)) }
        }
        throw ScanError.scannerUnavailable
    }

    nonisolated private static func scannerPath() -> String? {
        scannerPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func scannerDevice(using scannerPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scannerPath)
        process.arguments = ["-L"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        guard completion.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return nil
        }
        let result = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { return nil }
        return result
            .split(separator: "`")
            .dropFirst()
            .first
            .flatMap { $0.split(separator: "'").first }
            .map(String.init)
            .flatMap { $0.hasPrefix("xerox_mfp:") ? $0 : nil }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }
}

private extension FileManager {
    func removeItemIfPresent(at url: URL) throws {
        if fileExists(atPath: url.path) { try removeItem(at: url) }
    }
}

private enum ScanError: LocalizedError {
    case failed(String)
    case timedOut
    case scannerUnavailable

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .timedOut:
            return "Сканер не завершил чтение вовремя. Выключите МФУ кнопкой питания на 10 секунд, включите его и попробуйте снова. Если ошибка возвращается, подключите МФУ напрямую к Mac другим USB-кабелем, без хаба или переходника."
        case .scannerUnavailable:
            return "Mac не увидел сканер в течение 20 секунд. Выключите МФУ кнопкой питания на 10 секунд, включите его, дождитесь полной загрузки и повторите попытку."
        }
    }
}

struct ContentView: View {
    @StateObject private var model = ScannerViewModel()

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "document.viewfinder")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.blue)

            VStack(spacing: 5) {
                Text("Samsung SCX-4200")
                    .font(.title2.weight(.semibold))
                Text("Сканирование с планшета")
                    .foregroundStyle(.secondary)
            }

            Form {
                Picker("Цвет", selection: $model.mode) {
                    ForEach(ScanMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Качество", selection: $model.resolution) {
                    Text("150 dpi — быстро").tag(150)
                    Text("300 dpi — максимум для цвета").tag(300)
                }
                Picker("Файл", selection: $model.outputFormat) {
                    ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Уменьшить вертикальные полосы", isOn: $model.reduceBanding)
                Toggle("Предлагать белый фон после сканирования", isOn: $model.suggestWhiteBackground)
            }
            .formStyle(.grouped)

            Text(model.message)
                .font(.callout)
                .foregroundStyle(model.isScanning ? .blue : .secondary)

            Button {
                model.scan()
            } label: {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Сканирование")
                } else {
                    Text("Сканировать")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isScanning)
        }
        .padding(28)
        .frame(width: 390)
        .sheet(item: $model.review) { review in
            ScanReviewView(
                review: review,
                keepOriginal: { model.saveReview(review, withWhiteBackground: false) },
                keepWhiteBackground: { model.saveReview(review, withWhiteBackground: true) },
                cancel: { model.cancelReview(review) }
            )
            .interactiveDismissDisabled()
        }
        .alert("Не удалось отсканировать", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("Закрыть", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct ScanReviewView: View {
    let review: ScanReview
    let keepOriginal: () -> Void
    let keepWhiteBackground: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 5) {
                Text("Как сохранить скан?")
                    .font(.title2.weight(.semibold))
                Text("Слева исходный скан, справа вариант с вырезанным объектом на белом фоне.")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 18) {
                preview(title: "Как есть", url: review.originalURL)
                preview(title: "Белый фон", url: review.whiteBackgroundURL)
            }

            HStack {
                Button("Отменить", role: .cancel, action: cancel)
                Spacer()
                Button("Оставить как есть", action: keepOriginal)
                Button("Сохранить с белым фоном", action: keepWhiteBackground)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 860, minHeight: 650)
    }

    @ViewBuilder
    private func preview(title: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Group {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ContentUnavailableView("Не удалось открыть превью", systemImage: "exclamationmark.triangle")
                }
            }
            .frame(width: 390, height: 500)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

@main
struct SCX4200ScannerApp: App {
    var body: some Scene {
        WindowGroup("Сканировать SCX-4200") {
            ContentView()
        }
        .defaultSize(width: 390, height: 450)
        .windowResizability(.contentSize)
    }
}
