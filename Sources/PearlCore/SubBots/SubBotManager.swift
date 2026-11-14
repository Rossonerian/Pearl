import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

// MARK: - SubBot Types

public enum SubBotType: String, Codable, Sendable, CaseIterable {
    case search
    case scrape
    case crawl
    case map
    case monitor
}

public struct SubBotTask: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let botType: SubBotType
    public let targets: [String]
    public let query: String?
    public let maxDepth: Int
    public let limit: Int
    
    public init(
        id: String = UUID().uuidString,
        name: String = "",
        botType: SubBotType,
        targets: [String] = [],
        query: String? = nil,
        maxDepth: Int = 2,
        limit: Int = 10
    ) {
        self.id = id
        self.name = name.isEmpty ? "\(botType.rawValue)_\(id.prefix(8))" : name
        self.botType = botType
        self.targets = targets
        self.query = query
        // maxDepth clamped 1...3
        self.maxDepth = min(max(maxDepth, 1), 3)
        // limit clamped 1...25
        self.limit = min(max(limit, 1), 25)
    }
}

public struct SubBotResult: Codable, Sendable, Equatable {
    public let taskId: String
    public let taskName: String
    public let botType: SubBotType
    public let success: Bool
    public let urlsProcessed: Int
    public let durationMs: Double
    public let markdownContent: String
    public let discoveredURLs: [String]
    public let changed: Bool?
    public let diffSummary: String?
    public let error: String?
    public let trustLevel: TrustLevel
    
    public init(
        taskId: String = UUID().uuidString,
        taskName: String = "",
        botType: SubBotType,
        success: Bool,
        urlsProcessed: Int,
        durationMs: Double,
        markdownContent: String,
        discoveredURLs: [String] = [],
        changed: Bool? = nil,
        diffSummary: String? = nil,
        error: String? = nil,
        trustLevel: TrustLevel = .untrusted
    ) {
        self.taskId = taskId
        self.taskName = taskName
        self.botType = botType
        self.success = success
        self.urlsProcessed = urlsProcessed
        self.durationMs = durationMs
        self.markdownContent = markdownContent
        self.discoveredURLs = discoveredURLs
        self.changed = changed
        self.diffSummary = diffSummary
        self.error = error
        self.trustLevel = .untrusted
    }
}

// MARK: - HTMLMarkdownExtractor

public enum HTMLMarkdownExtractor {
    
    public static func extractMarkdown(from html: String, baseURL: URL? = nil) -> (markdown: String, links: [String]) {
        var text = html
        
        // 1. Strip script, style, nav, footer, noscript, and comments
        let blockPatterns = [
            "(?is)<script\\b[^>]*>.*?</script>",
            "(?is)<style\\b[^>]*>.*?</style>",
            "(?is)<nav\\b[^>]*>.*?</nav>",
            "(?is)<footer\\b[^>]*>.*?</footer>",
            "(?is)<noscript\\b[^>]*>.*?</noscript>",
            "(?is)<!--.*?-->"
        ]
        for pattern in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            }
        }
        
        // 2. Extract links and convert <a> tags to markdown
        var discoveredLinks: [String] = []
        var seenLinks = Set<String>()
        
        let aPattern = "(?is)<a\\b[^>]*href\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>(.*?)</a>"
        if let aRegex = try? NSRegularExpression(pattern: aPattern) {
            let nsString = text as NSString
            let matches = aRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
            
            for match in matches {
                guard match.numberOfRanges >= 2 else { continue }
                let rawHref = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let resolved = resolveURL(rawHref, baseURL: baseURL) {
                    if !seenLinks.contains(resolved) {
                        seenLinks.insert(resolved)
                        discoveredLinks.append(resolved)
                    }
                }
            }
            
            for match in matches.reversed() {
                let fullRange = match.range(at: 0)
                let rawHref = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let rawAnchorText = match.numberOfRanges >= 3 ? nsString.substring(with: match.range(at: 2)) : ""
                let cleanAnchorText = rawAnchorText.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                let targetURL = resolveURL(rawHref, baseURL: baseURL) ?? rawHref
                let anchorLabel = cleanAnchorText.isEmpty ? targetURL : cleanAnchorText
                let replacement = "[\(anchorLabel)](\(targetURL))"
                
                if let swiftRange = Range(fullRange, in: text) {
                    text.replaceSubrange(swiftRange, with: replacement)
                }
            }
        }
        
        // 3. Headings: <h1>...</h1> to <h6>...</h6>
        for level in (1...6).reversed() {
            let hashes = String(repeating: "#", count: level)
            let hPattern = "(?is)<h\(level)\\b[^>]*>(.*?)</h\(level)>"
            if let regex = try? NSRegularExpression(pattern: hPattern) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "\n\n\(hashes) $1\n\n")
            }
        }
        
        // 4. List items: <li>...</li>
        let liPattern = "(?is)<li\\b[^>]*>(.*?)</li>"
        if let regex = try? NSRegularExpression(pattern: liPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "\n* $1")
        }
        
        // 5. Paragraphs & block elements
        let blockReplacements: [(String, String)] = [
            ("(?is)<p\\b[^>]*>(.*?)</p>", "\n\n$1\n\n"),
            ("(?is)<br\\s*/?>", "\n"),
            ("(?is)<hr\\s*/?>", "\n\n---\n\n"),
            ("(?is)<blockquote\\b[^>]*>(.*?)</blockquote>", "\n\n> $1\n\n"),
            ("(?is)<strong\\b[^>]*>(.*?)</strong>", "**$1**"),
            ("(?is)<b\\b[^>]*>(.*?)</b>", "**$1**"),
            ("(?is)<em\\b[^>]*>(.*?)</em>", "*$1*"),
            ("(?is)<i\\b[^>]*>(.*?)</i>", "*$1*"),
            ("(?is)<code\\b[^>]*>(.*?)</code>", "`$1`"),
            ("(?is)<pre\\b[^>]*>(.*?)</pre>", "\n\n```\n$1\n```\n\n"),
            ("(?is)<div\\b[^>]*>", "\n"),
            ("(?is)</div>", "\n"),
            ("(?is)</?[ou]l\\b[^>]*>", "\n")
        ]
        
        for (pattern, template) in blockReplacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
            }
        }
        
        // 6. Strip remaining HTML tags
        if let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>") {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = tagRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }
        
        // 7. Decode HTML entities
        text = decodeHTMLEntities(text)
        
        // 8. Collapse whitespace
        text = collapseWhitespace(text)
        
        return (markdown: text, links: discoveredLinks)
    }
    
    private static func resolveURL(_ href: String, baseURL: URL?) -> String? {
        guard !href.isEmpty,
              !href.hasPrefix("javascript:"),
              !href.hasPrefix("mailto:"),
              !href.hasPrefix("tel:"),
              !href.hasPrefix("#") else {
            return nil
        }
        if href.hasPrefix("http://") || href.hasPrefix("https://") {
            return href
        }
        if href.hasPrefix("//") {
            let scheme = baseURL?.scheme ?? "https"
            return "\(scheme):\(href)"
        }
        if let base = baseURL, let resolved = URL(string: href, relativeTo: base)?.absoluteURL {
            let scheme = resolved.scheme?.lowercased()
            if scheme == "http" || scheme == "https" {
                return resolved.absoluteString
            }
        }
        return nil
    }
    
    private static func decodeHTMLEntities(_ input: String) -> String {
        var str = input
        let namedEntities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&hellip;", "…"),
            ("&rsquo;", "'"),
            ("&lsquo;", "'"),
            ("&rdquo;", "\""),
            ("&ldquo;", "\"")
        ]
        for (entity, replacement) in namedEntities {
            str = str.replacingOccurrences(of: entity, with: replacement)
        }
        
        // Numeric entities: &#123; and &#x1F;
        if let numRegex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let matches = numRegex.matches(in: str, options: [], range: NSRange(location: 0, length: (str as NSString).length))
            for match in matches.reversed() {
                let nsStr = str as NSString
                let numStr = nsStr.substring(with: match.range(at: 1))
                if let code = UInt32(numStr), let scalar = UnicodeScalar(code) {
                    let char = String(scalar)
                    if let swiftRange = Range(match.range(at: 0), in: str) {
                        str.replaceSubrange(swiftRange, with: char)
                    }
                }
            }
        }
        if let hexRegex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);") {
            let matches = hexRegex.matches(in: str, options: [], range: NSRange(location: 0, length: (str as NSString).length))
            for match in matches.reversed() {
                let nsStr = str as NSString
                let hexStr = nsStr.substring(with: match.range(at: 1))
                if let code = UInt32(hexStr, radix: 16), let scalar = UnicodeScalar(code) {
                    let char = String(scalar)
                    if let swiftRange = Range(match.range(at: 0), in: str) {
                        str.replaceSubrange(swiftRange, with: char)
                    }
                }
            }
        }
        return str
    }
    
    private static func collapseWhitespace(_ input: String) -> String {
        let lines = input.components(separatedBy: "\n")
        var cleanedLines: [String] = []
        var consecutiveEmpty = 0
        
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                consecutiveEmpty += 1
                if consecutiveEmpty <= 1 && !cleanedLines.isEmpty {
                    cleanedLines.append("")
                }
            } else {
                consecutiveEmpty = 0
                cleanedLines.append(trimmed)
            }
        }
        
        return cleanedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - SubBotManager

public final class SubBotManager: @unchecked Sendable {
    
    public static let shared = SubBotManager()
    
    public let maxWorkers: Int
    public let memoryCeilingMB: Double
    public let monitorsFileURL: URL
    public var firecrawlApiKey: String?
    
    public var onTaskStarted: (@Sendable (SubBotTask) -> Void)?
    public var onTaskCompleted: (@Sendable (SubBotTask, SubBotResult) -> Void)?
    public var onTaskFailed: (@Sendable (SubBotTask, SubBotResult) -> Void)?
    
    private let memoryReader: @Sendable () -> Double
    private let httpFetcher: @Sendable (URL) async throws -> (Data, URLResponse)
    private let monitorLock = NSLock()
    
    public init(
        maxWorkers: Int = 4,
        memoryCeilingMB: Double = 45.0,
        monitorsFileURL: URL? = nil,
        memoryReader: (@Sendable () -> Double)? = nil,
        httpFetcher: (@Sendable (URL) async throws -> (Data, URLResponse))? = nil,
        firecrawlApiKey: String? = nil
    ) {
        self.maxWorkers = maxWorkers
        self.memoryCeilingMB = memoryCeilingMB
        
        if let monitorsFileURL = monitorsFileURL {
            self.monitorsFileURL = monitorsFileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.monitorsFileURL = appSupport.appendingPathComponent("Pearl/subbots/monitors.json")
        }
        
        self.firecrawlApiKey = firecrawlApiKey
        
        self.memoryReader = memoryReader ?? {
            #if canImport(Darwin)
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            if kerr == KERN_SUCCESS {
                return Double(info.resident_size) / (1024.0 * 1024.0)
            }
            #endif
            return 0.0
        }
        
        self.httpFetcher = httpFetcher ?? { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 10.0
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Pearl/3.2 SubBot", forHTTPHeaderField: "User-Agent")
            return try await URLSession.shared.data(for: request)
        }
    }
    
    // MARK: - Batch Execution with Concurrency and Memory Guards
    
    public func runBatch(_ tasks: [SubBotTask]) async -> [SubBotResult] {
        let currentMem = memoryReader()
        if currentMem > memoryCeilingMB {
            return tasks.map { task in
                let res = SubBotResult(
                    taskId: task.id,
                    taskName: task.name,
                    botType: task.botType,
                    success: false,
                    urlsProcessed: 0,
                    durationMs: 0.0,
                    markdownContent: "",
                    error: "Memory ceiling exceeded: current usage \(String(format: "%.1f", currentMem)) MB exceeds ceiling \(String(format: "%.1f", memoryCeilingMB)) MB"
                )
                onTaskFailed?(task, res)
                return res
            }
        }
        
        guard !tasks.isEmpty else { return [] }
        
        let workerCap = max(1, maxWorkers)
        
        return await withTaskGroup(of: (Int, SubBotResult).self) { group in
            var results: [(Int, SubBotResult)] = []
            results.reserveCapacity(tasks.count)
            
            var taskIndex = 0
            while taskIndex < tasks.count && taskIndex < workerCap {
                let idx = taskIndex
                let task = tasks[idx]
                taskIndex += 1
                group.addTask {
                    let res = await self.executeSingleTask(task)
                    return (idx, res)
                }
            }
            
            for await (idx, result) in group {
                results.append((idx, result))
                if taskIndex < tasks.count {
                    let nextIdx = taskIndex
                    let nextTask = tasks[nextIdx]
                    taskIndex += 1
                    group.addTask {
                        let res = await self.executeSingleTask(nextTask)
                        return (nextIdx, res)
                    }
                }
            }
            
            return results.sorted(by: { $0.0 < $1.0 }).map { $0.1 }
        }
    }
    
    private func executeSingleTask(_ task: SubBotTask) async -> SubBotResult {
        onTaskStarted?(task)
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let mem = memoryReader()
        if mem > memoryCeilingMB {
            let res = SubBotResult(
                taskId: task.id,
                taskName: task.name,
                botType: task.botType,
                success: false,
                urlsProcessed: 0,
                durationMs: 0.0,
                markdownContent: "",
                error: "Memory ceiling exceeded: current usage \(String(format: "%.1f", mem)) MB exceeds ceiling \(String(format: "%.1f", memoryCeilingMB)) MB"
            )
            onTaskFailed?(task, res)
            return res
        }
        
        let result: SubBotResult
        do {
            switch task.botType {
            case .search:
                result = try await runSearch(task: task, startTime: startTime)
            case .scrape:
                result = try await runScrape(task: task, startTime: startTime)
            case .crawl:
                result = try await runCrawl(task: task, startTime: startTime)
            case .map:
                result = try await runMap(task: task, startTime: startTime)
            case .monitor:
                result = try await runMonitor(task: task, startTime: startTime)
            }
        } catch {
            let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            result = SubBotResult(
                taskId: task.id,
                taskName: task.name,
                botType: task.botType,
                success: false,
                urlsProcessed: 0,
                durationMs: duration,
                markdownContent: "",
                error: error.localizedDescription
            )
        }
        
        if result.success {
            onTaskCompleted?(task, result)
        } else {
            onTaskFailed?(task, result)
        }
        
        return result
    }
    
    // MARK: - Bot Implementations
    
    // 1. Search Bot (DuckDuckGo HTML/Lite Parser + Firecrawl enhancement)
    private func runSearch(task: SubBotTask, startTime: Double) async throws -> SubBotResult {
        let rawQuery = task.query ?? task.targets.first ?? ""
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw SubBotError.executionFailed("Search query is empty.")
        }
        
        // Optional Firecrawl API enhancement
        if let apiKey = firecrawlApiKey, !apiKey.isEmpty {
            if let firecrawlResult = try? await searchWithFirecrawl(query: trimmedQuery, limit: task.limit, apiKey: apiKey) {
                let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                return SubBotResult(
                    taskId: task.id,
                    taskName: task.name,
                    botType: .search,
                    success: true,
                    urlsProcessed: 1,
                    durationMs: duration,
                    markdownContent: firecrawlResult.markdown,
                    discoveredURLs: firecrawlResult.urls
                )
            }
        }
        
        // Zero-key native DuckDuckGo HTML search
        guard let encodedQuery = trimmedQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://html.duckduckgo.com/html/?q=\(encodedQuery)") else {
            throw SubBotError.invalidURL("https://html.duckduckgo.com/html/?q=\(trimmedQuery)")
        }
        
        let (data, _) = try await httpFetcher(searchURL)
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        
        let items = parseDuckDuckGoHTML(html: html, limit: task.limit)
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        
        if items.isEmpty {
            // Fallback: extract markdown and links using HTMLMarkdownExtractor
            let (extractedMD, links) = HTMLMarkdownExtractor.extractMarkdown(from: html, baseURL: URL(string: "https://duckduckgo.com"))
            let discovered = Array(links.prefix(task.limit))
            var markdown = "# Search Results for \"\(trimmedQuery)\"\n\n"
            if discovered.isEmpty {
                markdown += "No matching search results found.\n"
            } else {
                for (i, link) in discovered.enumerated() {
                    markdown += "\(i + 1). [\(link)](\(link))\n"
                }
            }
            if !extractedMD.isEmpty && discovered.isEmpty {
                markdown += "\n" + extractedMD
            }
            return SubBotResult(
                taskId: task.id,
                taskName: task.name,
                botType: .search,
                success: true,
                urlsProcessed: 1,
                durationMs: duration,
                markdownContent: markdown,
                discoveredURLs: discovered
            )
        }
        
        var markdown = "# Search Results for \"\(trimmedQuery)\"\n\n"
        var discoveredURLs: [String] = []
        for (index, item) in items.enumerated() {
            discoveredURLs.append(item.url)
            markdown += "\(index + 1). [\(item.title)](\(item.url))\n"
            if !item.snippet.isEmpty {
                markdown += "   \(item.snippet)\n"
            }
            markdown += "\n"
        }
        
        return SubBotResult(
            taskId: task.id,
            taskName: task.name,
            botType: .search,
            success: true,
            urlsProcessed: 1,
            durationMs: duration,
            markdownContent: markdown.trimmingCharacters(in: .whitespacesAndNewlines),
            discoveredURLs: discoveredURLs
        )
    }
    
    private struct DDGItem {
        let title: String
        let url: String
        let snippet: String
    }
    
    private func parseDuckDuckGoHTML(html: String, limit: Int) -> [DDGItem] {
        var items: [DDGItem] = []
        
        // Find blocks matching result__title and result__snippet
        let resultBlockPattern = "(?is)<h2\\b[^>]*class=\"[^\"]*result__title[^\"]*\"[^>]*>\\s*<a\\b[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>(?:.*?<a\\b[^>]*class=\"[^\"]*result__snippet[^\"]*\"[^>]*>(.*?)</a>)?"
        if let regex = try? NSRegularExpression(pattern: resultBlockPattern) {
            let nsHtml = html as NSString
            let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
            for match in matches {
                guard items.count < limit else { break }
                let rawHref = nsHtml.substring(with: match.range(at: 1))
                let rawTitle = match.numberOfRanges >= 3 ? nsHtml.substring(with: match.range(at: 2)) : ""
                let rawSnippet = (match.numberOfRanges >= 4 && match.range(at: 3).location != NSNotFound)
                    ? nsHtml.substring(with: match.range(at: 3)) : ""
                
                let resolvedURL = unwrapDuckDuckGoURL(rawHref)
                let cleanTitle = stripTagsAndDecode(rawTitle)
                let cleanSnippet = stripTagsAndDecode(rawSnippet)
                
                if !resolvedURL.isEmpty {
                    items.append(DDGItem(title: cleanTitle.isEmpty ? resolvedURL : cleanTitle, url: resolvedURL, snippet: cleanSnippet))
                }
            }
        }
        
        // Generic fallback if standard DDG structure wasn't matched
        if items.isEmpty {
            let genericPattern = "(?is)<a\\b[^>]*class=\"[^\"]*result__url[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"
            if let regex = try? NSRegularExpression(pattern: genericPattern) {
                let nsHtml = html as NSString
                let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
                for match in matches {
                    guard items.count < limit else { break }
                    let rawHref = nsHtml.substring(with: match.range(at: 1))
                    let rawTitle = match.numberOfRanges >= 3 ? nsHtml.substring(with: match.range(at: 2)) : ""
                    let resolved = unwrapDuckDuckGoURL(rawHref)
                    let cleanTitle = stripTagsAndDecode(rawTitle)
                    items.append(DDGItem(title: cleanTitle.isEmpty ? resolved : cleanTitle, url: resolved, snippet: ""))
                }
            }
        }
        
        return items
    }
    
    private func unwrapDuckDuckGoURL(_ rawHref: String) -> String {
        let fullHref = rawHref.hasPrefix("//") ? "https:\(rawHref)" : rawHref
        if let components = URLComponents(string: fullHref),
           let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return uddg
        }
        return fullHref
    }
    
    private func stripTagsAndDecode(_ input: String) -> String {
        let stripped = input.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let (decoded, _) = HTMLMarkdownExtractor.extractMarkdown(from: stripped)
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // 2. Scrape Bot (Parallel page scraping)
    private func runScrape(task: SubBotTask, startTime: Double) async throws -> SubBotResult {
        var targets = task.targets
        if targets.isEmpty, let q = task.query, !q.isEmpty {
            targets = [q]
        }
        guard !targets.isEmpty else {
            throw SubBotError.executionFailed("No target URLs provided for scrape.")
        }
        
        let cappedTargets = Array(targets.prefix(task.limit))
        
        struct ScrapeOutput: Sendable {
            let url: String
            let markdown: String
            let links: [String]
            let success: Bool
        }
        
        let outputs = await withTaskGroup(of: ScrapeOutput.self) { group in
            for target in cappedTargets {
                group.addTask {
                    guard let url = URL(string: target),
                          let scheme = url.scheme?.lowercased(),
                          scheme == "http" || scheme == "https" else {
                        return ScrapeOutput(url: target, markdown: "Invalid URL: \(target)", links: [], success: false)
                    }
                    do {
                        let (data, _) = try await self.httpFetcher(url)
                        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                        let (markdown, links) = HTMLMarkdownExtractor.extractMarkdown(from: html, baseURL: url)
                        return ScrapeOutput(url: target, markdown: markdown, links: links, success: true)
                    } catch {
                        return ScrapeOutput(url: target, markdown: "Fetch error: \(error.localizedDescription)", links: [], success: false)
                    }
                }
            }
            
            var collected: [ScrapeOutput] = []
            for await out in group {
                collected.append(out)
            }
            return collected
        }
        
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let successCount = outputs.filter { $0.success }.count
        
        var allDiscoveredURLs: [String] = []
        var seenLinks = Set<String>()
        for out in outputs {
            for link in out.links {
                if !seenLinks.contains(link) {
                    seenLinks.insert(link)
                    allDiscoveredURLs.append(link)
                }
            }
        }
        
        var combinedMarkdown = ""
        for out in outputs {
            if !combinedMarkdown.isEmpty {
                combinedMarkdown += "\n\n---\n\n"
            }
            combinedMarkdown += "# Content for \(out.url)\n\n\(out.markdown)"
        }
        
        return SubBotResult(
            taskId: task.id,
            taskName: task.name,
            botType: .scrape,
            success: successCount > 0,
            urlsProcessed: successCount,
            durationMs: duration,
            markdownContent: combinedMarkdown,
            discoveredURLs: allDiscoveredURLs,
            error: successCount == 0 ? "All target fetches failed." : nil
        )
    }
    
    // 3. Crawl Bot (BFS restricted to same-host, bounded by maxDepth and limit)
    private func runCrawl(task: SubBotTask, startTime: Double) async throws -> SubBotResult {
        let targetStr = task.targets.first ?? task.query ?? ""
        guard let startURL = URL(string: targetStr),
              let host = startURL.host?.lowercased(),
              let scheme = startURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw SubBotError.invalidURL(targetStr)
        }
        
        var visited = Set<String>()
        var queue: [(url: URL, depth: Int)] = [(startURL, 1)]
        var pages: [(url: String, markdown: String, links: [String])] = []
        var allDiscovered: [String] = []
        var seenDiscovered = Set<String>()
        
        while !queue.isEmpty && pages.count < task.limit {
            let (currentURL, depth) = queue.removeFirst()
            let normalizedKey = canonicalURLKey(currentURL)
            if visited.contains(normalizedKey) {
                continue
            }
            visited.insert(normalizedKey)
            
            do {
                let (data, _) = try await httpFetcher(currentURL)
                let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let (markdown, links) = HTMLMarkdownExtractor.extractMarkdown(from: html, baseURL: currentURL)
                pages.append((url: currentURL.absoluteString, markdown: markdown, links: links))
                
                for link in links {
                    if !seenDiscovered.contains(link) {
                        seenDiscovered.insert(link)
                        allDiscovered.append(link)
                    }
                    if depth < task.maxDepth {
                        if let linkURL = URL(string: link),
                           linkURL.host?.lowercased() == host {
                            let linkKey = canonicalURLKey(linkURL)
                            if !visited.contains(linkKey) && !queue.contains(where: { canonicalURLKey($0.url) == linkKey }) {
                                queue.append((url: linkURL, depth: depth + 1))
                            }
                        }
                    }
                }
            } catch {
                // Continue crawling other queued URLs on error
                continue
            }
        }
        
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        
        var markdown = "# Crawl Report for \(startURL.absoluteString)\n\n"
        markdown += "Crawled \(pages.count) pages (Depth: \(task.maxDepth), Limit: \(task.limit))\n\n"
        markdown += "## Crawled Pages Index\n"
        for p in pages {
            markdown += "- [\(p.url)](\(p.url))\n"
        }
        markdown += "\n"
        for p in pages {
            markdown += "\n---\n\n### \(p.url)\n\n\(p.markdown)\n"
        }
        
        return SubBotResult(
            taskId: task.id,
            taskName: task.name,
            botType: .crawl,
            success: !pages.isEmpty,
            urlsProcessed: pages.count,
            durationMs: duration,
            markdownContent: markdown.trimmingCharacters(in: .whitespacesAndNewlines),
            discoveredURLs: allDiscovered
        )
    }
    
    // 4. Map Bot (Extract all same-host links from target + /sitemap.xml)
    private func runMap(task: SubBotTask, startTime: Double) async throws -> SubBotResult {
        let targetStr = task.targets.first ?? task.query ?? ""
        guard let startURL = URL(string: targetStr),
              let host = startURL.host?.lowercased(),
              let scheme = startURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw SubBotError.invalidURL(targetStr)
        }
        
        var sameHostLinks: [String] = []
        var seenLinks = Set<String>()
        
        func addSameHostLink(_ link: String) {
            guard let url = URL(string: link),
                  url.host?.lowercased() == host else { return }
            let key = canonicalURLKey(url)
            if !seenLinks.contains(key) {
                seenLinks.insert(key)
                sameHostLinks.append(url.absoluteString)
            }
        }
        
        addSameHostLink(startURL.absoluteString)
        var urlsProcessed = 0
        
        // Fetch target page
        do {
            let (data, _) = try await httpFetcher(startURL)
            urlsProcessed += 1
            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let (_, links) = HTMLMarkdownExtractor.extractMarkdown(from: html, baseURL: startURL)
            for link in links {
                addSameHostLink(link)
            }
        } catch {
            // Target page failed, continue to sitemap check
        }
        
        // Fetch sitemap.xml if available
        if let sitemapURL = URL(string: "\(scheme)://\(host)/sitemap.xml") {
            if let (sitemapData, sitemapResponse) = try? await httpFetcher(sitemapURL) {
                if let httpRes = sitemapResponse as? HTTPURLResponse, httpRes.statusCode == 200 {
                    urlsProcessed += 1
                    let xml = String(data: sitemapData, encoding: .utf8) ?? String(decoding: sitemapData, as: UTF8.self)
                    let locPattern = "(?is)<loc>\\s*(https?://[^<\\s]+)\\s*</loc>"
                    if let regex = try? NSRegularExpression(pattern: locPattern) {
                        let nsXML = xml as NSString
                        let matches = regex.matches(in: xml, options: [], range: NSRange(location: 0, length: nsXML.length))
                        for match in matches {
                            if match.numberOfRanges >= 2 {
                                let loc = nsXML.substring(with: match.range(at: 1))
                                addSameHostLink(loc)
                            }
                        }
                    }
                }
            }
        }
        
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let sortedLinks = sameHostLinks.sorted()
        
        var markdown = "# Site Map for \(startURL.absoluteString)\n\n"
        markdown += "Discovered \(sortedLinks.count) unique pages on \(host):\n\n"
        for link in sortedLinks {
            markdown += "- \(link)\n"
        }
        
        return SubBotResult(
            taskId: task.id,
            taskName: task.name,
            botType: .map,
            success: !sortedLinks.isEmpty,
            urlsProcessed: urlsProcessed,
            durationMs: duration,
            markdownContent: markdown.trimmingCharacters(in: .whitespacesAndNewlines),
            discoveredURLs: sortedLinks
        )
    }
    
    // 5. Monitor Bot (Snapshot hash comparison & line diffing)
    private struct MonitorSnapshotRecord: Codable {
        let url: String
        let sha256: String
        let content: String
        let timestamp: Date
    }
    
    private func runMonitor(task: SubBotTask, startTime: Double) async throws -> SubBotResult {
        let targetStr = task.targets.first ?? task.query ?? ""
        guard let startURL = URL(string: targetStr),
              let scheme = startURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw SubBotError.invalidURL(targetStr)
        }
        
        let (data, _) = try await httpFetcher(startURL)
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let (markdown, _) = HTMLMarkdownExtractor.extractMarkdown(from: html, baseURL: startURL)
        
        let normalizedContent = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalizedContent.utf8))
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()
        
        let (changed, diffSummary) = updateMonitorSnapshot(
            targetKey: startURL.absoluteString,
            hashHex: hashHex,
            normalizedContent: normalizedContent
        )
        
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        
        return SubBotResult(
            taskId: task.id,
            taskName: task.name,
            botType: .monitor,
            success: true,
            urlsProcessed: 1,
            durationMs: duration,
            markdownContent: normalizedContent,
            discoveredURLs: [],
            changed: changed,
            diffSummary: diffSummary
        )
    }
    
    private func updateMonitorSnapshot(
        targetKey: String,
        hashHex: String,
        normalizedContent: String
    ) -> (changed: Bool, diffSummary: String) {
        monitorLock.lock()
        defer { monitorLock.unlock() }
        
        var snapshots = loadSnapshots()
        let changed: Bool
        let diffSummary: String
        
        if let previous = snapshots[targetKey] {
            if previous.sha256 == hashHex {
                changed = false
                diffSummary = "No changes detected. Hash matches previous snapshot (\(hashHex.prefix(8)))."
            } else {
                changed = true
                diffSummary = computeDiff(previous: previous.content, current: normalizedContent)
            }
        } else {
            changed = false
            diffSummary = "Baseline snapshot established (hash: \(hashHex.prefix(8)))."
        }
        
        snapshots[targetKey] = MonitorSnapshotRecord(
            url: targetKey,
            sha256: hashHex,
            content: normalizedContent,
            timestamp: Date()
        )
        saveSnapshots(snapshots)
        return (changed, diffSummary)
    }
    
    private func computeDiff(previous: String, current: String) -> String {
        let prevLines = previous.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let currLines = current.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        
        let prevSet = Set(prevLines)
        let currSet = Set(currLines)
        
        let added = currLines.filter { !prevSet.contains($0) }
        let removed = prevLines.filter { !currSet.contains($0) }
        
        var diffParts: [String] = []
        if !added.isEmpty {
            diffParts.append("Added (\(added.count) lines):\n" + added.prefix(8).map { "+ \($0)" }.joined(separator: "\n"))
        }
        if !removed.isEmpty {
            diffParts.append("Removed (\(removed.count) lines):\n" + removed.prefix(8).map { "- \($0)" }.joined(separator: "\n"))
        }
        if diffParts.isEmpty {
            return "Content modified (hash changed, lines reorganized)."
        }
        return diffParts.joined(separator: "\n\n")
    }
    
    private func loadSnapshots() -> [String: MonitorSnapshotRecord] {
        guard FileManager.default.fileExists(atPath: monitorsFileURL.path),
              let data = try? Data(contentsOf: monitorsFileURL),
              let decoded = try? JSONDecoder().decode([String: MonitorSnapshotRecord].self, from: data) else {
            return [:]
        }
        return decoded
    }
    
    private func saveSnapshots(_ snapshots: [String: MonitorSnapshotRecord]) {
        let dir = monitorsFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshots) {
            try? data.write(to: monitorsFileURL, options: .atomic)
        }
    }
    
    // MARK: - Workflows
    
    public func executeWorkflow(
        name: String,
        query: String? = nil,
        urls: [String] = [],
        topN: Int = 3
    ) async -> SubBotResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let wfTask = SubBotTask(name: name, botType: .search, targets: urls, query: query)
        onTaskStarted?(wfTask)
        
        let normalizedName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        if normalizedName == "search_and_scrape" || normalizedName == "market_research" {
            let searchTask = SubBotTask(name: "\(name)_search", botType: .search, targets: urls, query: query, limit: max(topN * 2, 5))
            let searchResults = await runBatch([searchTask])
            guard let searchRes = searchResults.first, searchRes.success else {
                let dur = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                let failRes = SubBotResult(
                    taskId: wfTask.id,
                    taskName: name,
                    botType: .search,
                    success: false,
                    urlsProcessed: 0,
                    durationMs: dur,
                    markdownContent: "",
                    error: searchResults.first?.error ?? "Search step failed."
                )
                onTaskFailed?(wfTask, failRes)
                return failRes
            }
            
            let targetsToScrape = Array(searchRes.discoveredURLs.prefix(topN))
            var scrapeRes: SubBotResult?
            if !targetsToScrape.isEmpty {
                let scrapeTask = SubBotTask(name: "\(name)_scrape", botType: .scrape, targets: targetsToScrape)
                let scrapeResults = await runBatch([scrapeTask])
                scrapeRes = scrapeResults.first
            }
            
            var combinedMD = "# Market Research Report: \(query ?? "Web Search")\n\n"
            combinedMD += "## Search Findings\n\(searchRes.markdownContent)\n\n"
            combinedMD += "## Deep Scraped Sources\n"
            combinedMD += scrapeRes?.markdownContent ?? "No deep sources scraped."
            
            let dur = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let processed = searchRes.urlsProcessed + (scrapeRes?.urlsProcessed ?? 0)
            let discovered = Array(Set(searchRes.discoveredURLs + (scrapeRes?.discoveredURLs ?? [])))
            
            let finalRes = SubBotResult(
                taskId: wfTask.id,
                taskName: name,
                botType: .search,
                success: true,
                urlsProcessed: processed,
                durationMs: dur,
                markdownContent: combinedMD,
                discoveredURLs: discovered
            )
            onTaskCompleted?(wfTask, finalRes)
            return finalRes
            
        } else if normalizedName == "competitive_analysis" {
            guard !urls.isEmpty else {
                let dur = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                let failRes = SubBotResult(
                    taskId: wfTask.id,
                    taskName: name,
                    botType: .scrape,
                    success: false,
                    urlsProcessed: 0,
                    durationMs: dur,
                    markdownContent: "",
                    error: "No target URLs provided for competitive analysis."
                )
                onTaskFailed?(wfTask, failRes)
                return failRes
            }
            
            let scrapeTask = SubBotTask(name: "\(name)_scrape", botType: .scrape, targets: urls)
            let scrapeResults = await runBatch([scrapeTask])
            let scrapeRes = scrapeResults.first
            
            var reportMD = "# Competitive Analysis Report\n\n"
            reportMD += "Analyzed \(urls.count) targets:\n"
            for u in urls {
                reportMD += "- \(u)\n"
            }
            reportMD += "\n## Synthesized Target Data\n\n"
            reportMD += scrapeRes?.markdownContent ?? "No data retrieved."
            
            let dur = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let finalRes = SubBotResult(
                taskId: wfTask.id,
                taskName: name,
                botType: .scrape,
                success: scrapeRes?.success ?? false,
                urlsProcessed: scrapeRes?.urlsProcessed ?? 0,
                durationMs: dur,
                markdownContent: reportMD,
                discoveredURLs: scrapeRes?.discoveredURLs ?? []
            )
            if finalRes.success {
                onTaskCompleted?(wfTask, finalRes)
            } else {
                onTaskFailed?(wfTask, finalRes)
            }
            return finalRes
        } else {
            let dur = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let failRes = SubBotResult(
                taskId: wfTask.id,
                taskName: name,
                botType: .search,
                success: false,
                urlsProcessed: 0,
                durationMs: dur,
                markdownContent: "",
                error: "Unknown workflow: \(name)"
            )
            onTaskFailed?(wfTask, failRes)
            return failRes
        }
    }
    
    // MARK: - Firecrawl API Optional Helper
    
    private func searchWithFirecrawl(query: String, limit: Int, apiKey: String) async throws -> (markdown: String, urls: [String])? {
        guard let url = URL(string: "https://api.firecrawl.dev/v1/search") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["query": query, "limit": limit]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await (httpFetcher(url))
        guard let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]] else {
            return nil
        }
        
        var markdown = "# Search Results for \"\(query)\"\n\n"
        var urls: [String] = []
        for (i, item) in dataArr.enumerated() {
            let itemURL = item["url"] as? String ?? ""
            let itemTitle = item["title"] as? String ?? itemURL
            let itemSnippet = item["description"] as? String ?? ""
            if !itemURL.isEmpty {
                urls.append(itemURL)
                markdown += "\(i + 1). [\(itemTitle)](\(itemURL))\n   \(itemSnippet)\n\n"
            }
        }
        return (markdown: markdown.trimmingCharacters(in: .whitespacesAndNewlines), urls: urls)
    }
    
    // MARK: - Utilities
    
    private func canonicalURLKey(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "https"
        let host = url.host?.lowercased() ?? ""
        var path = url.path
        if path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
        }
        return "\(scheme)://\(host)\(path)"
    }
}

// MARK: - SubBotError

public enum SubBotError: LocalizedError {
    case invalidURL(String)
    case fetchFailed(String)
    case memoryCeilingExceeded(Double, Double)
    case executionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid target URL: \(url)"
        case .fetchFailed(let reason):
            return "HTTP fetch failed: \(reason)"
        case .memoryCeilingExceeded(let current, let ceiling):
            return "Memory ceiling exceeded: current usage \(String(format: "%.1f", current)) MB exceeds ceiling \(String(format: "%.1f", ceiling)) MB"
        case .executionFailed(let msg):
            return msg
        }
    }
}
