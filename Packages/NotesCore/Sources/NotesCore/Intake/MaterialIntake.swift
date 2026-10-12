import Foundation

/// Quick Add 里加入、还没保存的 Material（ARCHITECTURE §5）。只有 File 和 Web Page；Source 在保存时才生成。
public struct StagedMaterial: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: MaterialKind
    public var displayName: String
    /// File：`staging/<sessionID>/` 下的副本。
    public var fileURL: URL?
    /// Web Page：原始链接。
    public var url: URL?

    public init(id: UUID = UUID(), kind: MaterialKind, displayName: String, fileURL: URL? = nil, url: URL? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.fileURL = fileURL
        self.url = url
    }
}

public enum MaterialIntakeError: Error, Equatable, Sendable {
    /// 复制进 staging 失败（源文件不存在、读不了、磁盘满）。
    case cannotStage(name: String)
}

/// 把文件、剪贴板图片、链接变成 `StagedMaterial`，并准备 Readable Text（SPEC §3.2）。
///
/// 流程：`stage(…)` 同步复制进 staging 并返回 `StagedMaterial`（立刻显示在 Material 条里，状态 pending），
/// 然后对每个 Material 调一次 `prepare(_:)`（`async`，可取消）拿到 Readable Text。
public struct MaterialIntake: Sendable {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp"]

    private let files: MaterialFiles
    private let session: StagingSession
    private let fetcher: (any WebPageFetching)?

    public init(files: MaterialFiles, session: StagingSession, fetcher: (any WebPageFetching)? = nil) {
        self.files = files
        self.session = session
        self.fetcher = fetcher
    }

    // MARK: staging

    /// 「+」、拖入、Finder 里复制后粘贴。任何类型都收，bundle 目录（.pages）也整个复制。
    public func stage(fileAt source: URL) throws -> StagedMaterial {
        let name = source.lastPathComponent
        do {
            let copy = try files.stage(copying: source, in: session)
            return StagedMaterial(kind: .file, displayName: copy.lastPathComponent, fileURL: copy)
        } catch {
            throw MaterialIntakeError.cannotStage(name: name)
        }
    }

    /// 剪贴板里的图片数据，存成 `Pasted Image <时间>.png`。
    public func stage(imageData: Data, now: Date = Date()) throws -> StagedMaterial {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Pasted Image \(formatter.string(from: now)).png"
        do {
            let url = try files.stage(data: imageData, name: name, in: session)
            return StagedMaterial(kind: .file, displayName: url.lastPathComponent, fileURL: url)
        } catch {
            throw MaterialIntakeError.cannotStage(name: name)
        }
    }

    /// 链接不落盘，抓取在 `prepare` 里做。
    public func stage(url: URL) -> StagedMaterial {
        StagedMaterial(kind: .webPage, displayName: url.absoluteString, url: url)
    }

    // MARK: Readable Text

    /// 准备一个 Material 的 Readable Text。每个 Material 调一次；任务被取消时返回 `.unavailable(.cancelled)`。
    /// 阻塞的工作（读文件、PDFKit、Vision）都在调用者的 Task 里同步完成，不占主线程。
    public func prepare(_ material: StagedMaterial) async -> PreparedText {
        if Task.isCancelled { return PreparedText(state: .unavailable(.cancelled)) }
        let prepared: PreparedText
        switch material.kind {
        case .webPage:
            prepared = await prepareWebPage(material)
        case .file:
            guard let url = material.fileURL else { return PreparedText(state: .unavailable(.unreadableFile)) }
            prepared = PreparedText(state: readableText(ofFileAt: url))
        case .source:
            // Source 不经过 Intake
            prepared = PreparedText(state: .unavailable(.notReadable))
        }
        return Task.isCancelled ? PreparedText(state: .unavailable(.cancelled)) : prepared
    }

    private func prepareWebPage(_ material: StagedMaterial) async -> PreparedText {
        guard let url = material.url, let fetcher else { return PreparedText(state: .unavailable(.pageLoadFailed)) }
        do {
            let page = try await fetcher.fetch(url)
            let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return PreparedText(
                state: text.isEmpty ? .unavailable(.pageHasNoText) : .ready(text),
                title: title.isEmpty ? nil : title,
                snapshotPDF: page.pdfData
            )
        } catch is CancellationError {
            return PreparedText(state: .unavailable(.cancelled))
        } catch {
            return PreparedText(state: .unavailable(.pageLoadFailed))
        }
    }

    private func readableText(ofFileAt url: URL) -> ReadableTextState {
        // .pages、.key 这类 bundle 在 Finder 里像一个文件，其实是目录
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .unavailable(.unreadableFile) }
        if isDirectory.boolValue { return .unavailable(.notReadable) }

        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return readablePDF(at: url) }
        if Self.imageExtensions.contains(ext) { return readableImage(at: url) }
        return readableTextFile(at: url)
    }

    private func readableTextFile(at url: URL) -> ReadableTextState {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: TextDecoder.byteLimit + 1) ?? Data()
        } catch {
            return .unavailable(.unreadableFile)
        }
        let truncated = data.count > TextDecoder.byteLimit
        guard let text = TextDecoder.decode(truncated ? data.prefix(TextDecoder.byteLimit) : data, truncated: truncated) else {
            return .unavailable(.notReadable)
        }
        return .ready(text)
    }

    private func readablePDF(at url: URL) -> ReadableTextState {
        #if canImport(PDFKit)
        do {
            if let text = try PDFTextExtractor.text(from: url) { return .ready(text) }
        } catch PDFTextError.locked {
            return .unavailable(.passwordProtected)
        } catch {
            return .unavailable(.unreadableFile)
        }
        // 抽不出文字，多半是扫描版：逐页 OCR
        #if canImport(Vision)
        guard let text = try? ImageOCR.recognizeText(inPDFAt: url) else { return .unavailable(.unreadableFile) }
        return text.isEmpty ? .unavailable(.noTextRecognized) : .ready(text)
        #else
        return .unavailable(.noTextRecognized)
        #endif
        #else
        return .unavailable(.notReadable)
        #endif
    }

    private func readableImage(at url: URL) -> ReadableTextState {
        #if canImport(Vision)
        guard let text = try? ImageOCR.recognizeText(imageAt: url) else { return .unavailable(.unreadableFile) }
        return text.isEmpty ? .unavailable(.noTextRecognized) : .ready(text)
        #else
        return .unavailable(.notReadable)
        #endif
    }
}
