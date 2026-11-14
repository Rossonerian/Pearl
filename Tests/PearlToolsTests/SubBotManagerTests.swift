import XCTest
import Foundation
import PearlCore
@testable import PearlTools

final class SubBotManagerTests: XCTestCase {
    
    // MARK: - Test 1: HTMLMarkdownExtractor
    
    func testHTMLMarkdownExtractor() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Test Page</title>
            <style>
                body { font-family: sans-serif; color: #333; }
                .hidden { display: none; }
            </style>
            <script>
                console.log("malicious code");
                alert("exploit");
            </script>
        </head>
        <body>
            <nav>
                <a href="/ignored-nav-link">Navigation Home</a>
            </nav>
            <h1>Main Title &amp; Overview</h1>
            <p>Welcome to our platform. Here is the &quot;primary&quot; <a href="/docs/intro">documentation</a>.</p>
            <h3>Key Features</h3>
            <ul>
                <li>High speed &gt; low latency</li>
                <li>Zero-cost memory footprint</li>
            </ul>
            <p>Check our <a href="https://partner.org/api">External Partner API</a> for integrations.</p>
            <footer>
                <p>&copy; 2026 Pearl Inc. All rights reserved.</p>
            </footer>
        </body>
        </html>
        """
        
        let baseURL = URL(string: "https://example.com/app/index.html")!
        let (markdown, links) = HTMLMarkdownExtractor.extractMarkdown(from: html, baseURL: baseURL)
        
        // Assert non-content tags stripped
        XCTAssertFalse(markdown.contains("malicious code"), "Scripts must be stripped")
        XCTAssertFalse(markdown.contains("font-family"), "Styles must be stripped")
        XCTAssertFalse(markdown.contains("Navigation Home"), "Nav content must be stripped")
        XCTAssertFalse(markdown.contains("All rights reserved"), "Footer content must be stripped")
        
        // Assert headings and list conversion
        XCTAssertTrue(markdown.contains("# Main Title & Overview"), "Heading 1 converted with decoded &")
        XCTAssertTrue(markdown.contains("### Key Features"), "Heading 3 converted")
        XCTAssertTrue(markdown.contains("* High speed > low latency"), "List item converted with decoded >")
        
        // Assert links conversion and resolution
        XCTAssertTrue(markdown.contains("[documentation](https://example.com/docs/intro)"), "Relative link resolved against baseURL")
        XCTAssertTrue(markdown.contains("[External Partner API](https://partner.org/api)"), "Absolute external link preserved")
        
        // Assert discovered links
        XCTAssertTrue(links.contains("https://example.com/docs/intro"))
        XCTAssertTrue(links.contains("https://partner.org/api"))
        XCTAssertFalse(links.contains("https://example.com/ignored-nav-link"), "Nav links should be stripped")
        
        // Assert HTML entity decoding
        XCTAssertFalse(markdown.contains("&quot;"))
        XCTAssertFalse(markdown.contains("&amp;"))
        XCTAssertTrue(markdown.contains("\"primary\""))
    }
    
    // MARK: - Test 2: Parallel ScrapeBot Batching & Concurrency Cap
    
    final class ConcurrencyTracker: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var currentWorkers = 0
        private(set) var maxObservedWorkers = 0
        
        func enter() {
            lock.lock(); defer { lock.unlock() }
            currentWorkers += 1
            if currentWorkers > maxObservedWorkers {
                maxObservedWorkers = currentWorkers
            }
        }
        
        func exit() {
            lock.lock(); defer { lock.unlock() }
            currentWorkers -= 1
        }
    }
    
    func testParallelScrapeBotBatching() async throws {
        let tracker = ConcurrencyTracker()
        
        let mockFetcher: @Sendable (URL) async throws -> (Data, URLResponse) = { url in
            tracker.enter()
            
            // Artificial delay to observe concurrency
            try await Task.sleep(nanoseconds: 20_000_000)
            
            tracker.exit()
            
            let html = """
            <html>
            <body>
                <h1>Title for \(url.lastPathComponent)</h1>
                <p>Scraped content from \(url.absoluteString)</p>
                <a href="\(url.absoluteString)/sub">Next Link</a>
            </body>
            </html>
            """
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(html.utf8), response)
        }
        
        let manager = SubBotManager(
            maxWorkers: 2,
            memoryCeilingMB: 100.0,
            memoryReader: { 10.0 },
            httpFetcher: mockFetcher
        )
        
        let targets = [
            "https://test.site/page1",
            "https://test.site/page2",
            "https://test.site/page3",
            "https://test.site/page4"
        ]
        
        let task = SubBotTask(name: "batch_scrape", botType: .scrape, targets: targets, limit: 10)
        let results = await manager.runBatch([task])
        
        XCTAssertEqual(results.count, 1)
        guard let result = results.first else {
            XCTFail("Missing scrape result")
            return
        }
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.trustLevel, .untrusted)
        XCTAssertEqual(result.urlsProcessed, 4)
        XCTAssertTrue(result.markdownContent.contains("Title for page1"))
        XCTAssertTrue(result.markdownContent.contains("Title for page4"))
        XCTAssertEqual(result.discoveredURLs.count, 4)
    }
    
    // MARK: - Test 3: SearchBot HTML Parsing
    
    func testSearchBotHTMLParsing() async throws {
        let mockDDGHTML = """
        <!DOCTYPE html>
        <html>
        <body>
            <div class="result results_links results_links_deep web-result ">
                <div class="links_main links_deep result__body">
                    <h2 class="result__title">
                        <a class="result__url" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2Fabout%2F&amp;rut=1">Swift Programming Language</a>
                    </h2>
                    <a class="result__snippet">Swift is a fast, modern and safe type-safe language by Apple and contributors.</a>
                </div>
            </div>
            <div class="result results_links results_links_deep web-result ">
                <div class="links_main links_deep result__body">
                    <h2 class="result__title">
                        <a class="result__url" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fgithub.com%2Fapple%2Fswift&amp;rut=1">apple/swift: The Swift Programming Language</a>
                    </h2>
                    <a class="result__snippet">Open source repository for Swift compiler and standard library.</a>
                </div>
            </div>
        </body>
        </html>
        """
        
        let mockFetcher: @Sendable (URL) async throws -> (Data, URLResponse) = { url in
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(mockDDGHTML.utf8), response)
        }
        
        let manager = SubBotManager(
            memoryReader: { 15.0 },
            httpFetcher: mockFetcher
        )
        
        let task = SubBotTask(name: "search_swift", botType: .search, query: "swift programming")
        let results = await manager.runBatch([task])
        
        guard let result = results.first else {
            XCTFail("Missing search result")
            return
        }
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.trustLevel, .untrusted)
        XCTAssertEqual(result.urlsProcessed, 1)
        XCTAssertTrue(result.discoveredURLs.contains("https://swift.org/about/"))
        XCTAssertTrue(result.discoveredURLs.contains("https://github.com/apple/swift"))
        XCTAssertTrue(result.markdownContent.contains("[Swift Programming Language](https://swift.org/about/)"))
        XCTAssertTrue(result.markdownContent.contains("Swift is a fast, modern and safe"))
    }
    
    // MARK: - Test 4: CrawlBot Same-Host and Depth Limits
    
    final class SafeURLList: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        
        func append(_ url: String) {
            lock.lock(); defer { lock.unlock() }
            list.append(url)
        }
        
        func contains(_ url: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return list.contains(url)
        }
    }
    
    func testCrawlBotSameHostAndDepthLimits() async throws {
        let fetchedURLs = SafeURLList()
        
        let mockFetcher: @Sendable (URL) async throws -> (Data, URLResponse) = { url in
            fetchedURLs.append(url.absoluteString)
            
            let path = url.path
            let body: String
            switch path {
            case "", "/":
                body = """
                <html><body>
                    <h1>Root</h1>
                    <a href="/section-a">Section A</a>
                    <a href="/section-b">Section B</a>
                    <a href="https://external-domain.com/unwanted">External Leak</a>
                </body></html>
                """
            case "/section-a":
                body = """
                <html><body>
                    <h1>Section A</h1>
                    <a href="/section-a/item1">Depth 3 Item</a>
                </body></html>
                """
            case "/section-b":
                body = """
                <html><body>
                    <h1>Section B</h1>
                </body></html>
                """
            case "/section-a/item1":
                body = """
                <html><body>
                    <h1>Depth 3</h1>
                    <a href="/section-a/item1/deep">Depth 4 Item</a>
                </body></html>
                """
            default:
                body = "<html><body><h1>Default</h1></body></html>"
            }
            
            let res = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), res)
        }
        
        let manager = SubBotManager(
            memoryReader: { 15.0 },
            httpFetcher: mockFetcher
        )
        
        // maxDepth = 2 -> Should crawl / (depth 1), /section-a & /section-b (depth 2), but NOT /section-a/item1 (depth 3)
        let task = SubBotTask(
            name: "crawl_test",
            botType: .crawl,
            targets: ["https://myservice.local/"],
            maxDepth: 2,
            limit: 10
        )
        
        let results = await manager.runBatch([task])
        guard let result = results.first else {
            XCTFail("Missing crawl result")
            return
        }
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.trustLevel, .untrusted)
        
        // Assert same-host enforcement: external-domain.com was discovered as link but never fetched
        XCTAssertFalse(fetchedURLs.contains("https://external-domain.com/unwanted"))
        
        // Assert depth enforcement: Depth 3 (/section-a/item1) was not fetched
        XCTAssertFalse(fetchedURLs.contains("https://myservice.local/section-a/item1"))
        
        // Root and depth 2 fetched
        XCTAssertTrue(fetchedURLs.contains("https://myservice.local/"))
        XCTAssertTrue(fetchedURLs.contains("https://myservice.local/section-a"))
        XCTAssertTrue(fetchedURLs.contains("https://myservice.local/section-b"))
        XCTAssertEqual(result.urlsProcessed, 3)
    }
    
    // MARK: - Test 5: MapBot Link + Sitemap Discovery
    
    func testMapBotLinkAndSitemapDiscovery() async throws {
        let mockFetcher: @Sendable (URL) async throws -> (Data, URLResponse) = { url in
            if url.path == "/sitemap.xml" {
                let xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
                  <url><loc>https://acme.org/sitemap-page1</loc></url>
                  <url><loc>https://acme.org/sitemap-page2</loc></url>
                  <url><loc>https://unrelated.com/ignore-me</loc></url>
                </urlset>
                """
                let res = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(xml.utf8), res)
            } else {
                let html = """
                <html><body>
                    <h1>Home Page</h1>
                    <a href="/about">About Us</a>
                    <a href="/pricing">Pricing</a>
                    <a href="https://other.com/ext">Other</a>
                </body></html>
                """
                let res = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(html.utf8), res)
            }
        }
        
        let manager = SubBotManager(
            memoryReader: { 12.0 },
            httpFetcher: mockFetcher
        )
        
        let task = SubBotTask(name: "map_acme", botType: .map, targets: ["https://acme.org"])
        let results = await manager.runBatch([task])
        
        guard let result = results.first else {
            XCTFail("Missing map result")
            return
        }
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.trustLevel, .untrusted)
        XCTAssertEqual(result.urlsProcessed, 2) // Home page + sitemap.xml
        
        XCTAssertTrue(result.discoveredURLs.contains("https://acme.org/about"))
        XCTAssertTrue(result.discoveredURLs.contains("https://acme.org/pricing"))
        XCTAssertTrue(result.discoveredURLs.contains("https://acme.org/sitemap-page1"))
        XCTAssertTrue(result.discoveredURLs.contains("https://acme.org/sitemap-page2"))
        XCTAssertFalse(result.discoveredURLs.contains("https://unrelated.com/ignore-me"))
        XCTAssertFalse(result.discoveredURLs.contains("https://other.com/ext"))
    }
    
    // MARK: - Test 6: MonitorBot Baseline, Unchanged, and Mutated Diff
    
    func testMonitorBotDiffing() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let monitorsFile = tempDir.appendingPathComponent("monitors.json")
        
        final class ContentHolder: @unchecked Sendable {
            var bodyText = "Version 1.0\nStatus: Operational\nAll systems running smoothly."
        }
        let holder = ContentHolder()
        
        let mockFetcher: @Sendable (URL) async throws -> (Data, URLResponse) = { url in
            let html = "<html><body><h1>System Monitor</h1><p>\(holder.bodyText)</p></body></html>"
            let res = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(html.utf8), res)
        }
        
        let manager = SubBotManager(
            monitorsFileURL: monitorsFile,
            memoryReader: { 10.0 },
            httpFetcher: mockFetcher
        )
        
        let task = SubBotTask(name: "monitor_status", botType: .monitor, targets: ["https://status.app/feed"])
        
        // Pass 1: Baseline run
        let results1 = await manager.runBatch([task])
        guard let res1 = results1.first else { XCTFail("Pass 1 failed"); return }
        XCTAssertTrue(res1.success)
        XCTAssertEqual(res1.changed, false, "Initial baseline should report changed == false")
        XCTAssertTrue(res1.diffSummary?.contains("Baseline snapshot established") == true)
        
        // Pass 2: Unchanged content repeat
        let results2 = await manager.runBatch([task])
        guard let res2 = results2.first else { XCTFail("Pass 2 failed"); return }
        XCTAssertTrue(res2.success)
        XCTAssertEqual(res2.changed, false, "Unchanged content must report changed == false")
        XCTAssertTrue(res2.diffSummary?.contains("No changes detected") == true)
        
        // Pass 3: Mutated content
        holder.bodyText = "Version 1.1\nStatus: Degraded Performance\nMinor outage in us-west."
        let results3 = await manager.runBatch([task])
        guard let res3 = results3.first else { XCTFail("Pass 3 failed"); return }
        XCTAssertTrue(res3.success)
        XCTAssertEqual(res3.changed, true, "Mutated content must report changed == true")
        XCTAssertNotNil(res3.diffSummary)
        XCTAssertTrue(res3.diffSummary!.contains("Added") || res3.diffSummary!.contains("+"))
        XCTAssertTrue(res3.diffSummary!.contains("Removed") || res3.diffSummary!.contains("-"))
        
        // Cleanup temp file
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // MARK: - Test 7: Memory Ceiling Guard
    
    func testMemoryCeilingGuard() async {
        let manager = SubBotManager(
            maxWorkers: 2,
            memoryCeilingMB: 45.0,
            memoryReader: { 60.0 } // Exceeds 45.0 MB ceiling
        )
        
        let task = SubBotTask(name: "mem_check", botType: .scrape, targets: ["https://example.com"])
        let results = await manager.runBatch([task])
        
        guard let result = results.first else {
            XCTFail("Missing memory rejection result")
            return
        }
        
        XCTAssertFalse(result.success, "Task must fail when memory ceiling is exceeded")
        XCTAssertEqual(result.urlsProcessed, 0)
        XCTAssertTrue(result.error?.contains("Memory ceiling exceeded") == true)
    }
    
    // MARK: - Test 8: executeWorkflow DAG Chaining & Lifecycle Callbacks
    
    func testWorkflowSearchAndScrapeDAGAndLifecycle() async throws {
        let mockFetcher: @Sendable (URL) async throws -> (Data, URLResponse) = { url in
            if url.host == "html.duckduckgo.com" {
                let ddgHTML = """
                <html><body>
                    <h2 class="result__title">
                        <a class="result__url" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fblog.ai%2Ftrend1&amp;rut=1">AI Trend 1</a>
                    </h2>
                    <a class="result__snippet">Breakthroughs in edge models.</a>
                    <h2 class="result__title">
                        <a class="result__url" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fblog.ai%2Ftrend2&amp;rut=1">AI Trend 2</a>
                    </h2>
                    <a class="result__snippet">Autonomous agent architectures.</a>
                </body></html>
                """
                let res = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(ddgHTML.utf8), res)
            } else {
                let pageHTML = """
                <html><body>
                    <h1>Article: \(url.lastPathComponent)</h1>
                    <p>In-depth analysis of \(url.lastPathComponent) for market report.</p>
                </body></html>
                """
                let res = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(pageHTML.utf8), res)
            }
        }
        
        let manager = SubBotManager(
            memoryReader: { 15.0 },
            httpFetcher: mockFetcher
        )
        
        final class CallbackTracker: @unchecked Sendable {
            var startedTasks: [String] = []
            var completedTasks: [String] = []
            var failedTasks: [String] = []
            let lock = NSLock()
            
            func addStarted(_ name: String) {
                lock.lock(); defer { lock.unlock() }
                startedTasks.append(name)
            }
            func addCompleted(_ name: String) {
                lock.lock(); defer { lock.unlock() }
                completedTasks.append(name)
            }
            func addFailed(_ name: String) {
                lock.lock(); defer { lock.unlock() }
                failedTasks.append(name)
            }
        }
        
        let tracker = CallbackTracker()
        manager.onTaskStarted = { task in tracker.addStarted(task.name) }
        manager.onTaskCompleted = { task, _ in tracker.addCompleted(task.name) }
        manager.onTaskFailed = { task, _ in tracker.addFailed(task.name) }
        
        let workflowResult = await manager.executeWorkflow(
            name: "market_research",
            query: "AI Trends 2026",
            topN: 2
        )
        
        XCTAssertTrue(workflowResult.success)
        XCTAssertEqual(workflowResult.trustLevel, .untrusted)
        XCTAssertTrue(workflowResult.markdownContent.contains("Market Research Report: AI Trends 2026"))
        XCTAssertTrue(workflowResult.markdownContent.contains("Search Findings"))
        XCTAssertTrue(workflowResult.markdownContent.contains("Deep Scraped Sources"))
        XCTAssertTrue(workflowResult.markdownContent.contains("Article: trend1"))
        XCTAssertTrue(workflowResult.markdownContent.contains("Article: trend2"))
        
        // Assert DAG lifecycle callbacks
        XCTAssertTrue(tracker.startedTasks.contains("market_research"))
        XCTAssertTrue(tracker.startedTasks.contains("market_research_search"))
        XCTAssertTrue(tracker.startedTasks.contains("market_research_scrape"))
        XCTAssertTrue(tracker.completedTasks.contains("market_research"))
        XCTAssertEqual(tracker.failedTasks.count, 0)
    }
    
    // MARK: - Test 9: SubBotRunTool & SubBotWorkflowTool Metadata and Prefix
    
    func testToolsMetadataAndUntrustedPrefix() async throws {
        let mockFetcher: @Sendable (URL) async throws -> (Data, URLResponse) = { url in
            let html = "<html><body><h1>Sample Article</h1><p>Clean sample paragraph.</p></body></html>"
            let res = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(html.utf8), res)
        }
        
        let manager = SubBotManager(
            memoryReader: { 10.0 },
            httpFetcher: mockFetcher
        )
        
        let runTool = SubBotRunTool(manager: manager)
        let workflowTool = SubBotWorkflowTool(manager: manager)
        
        // 1. Tool metadata validation
        XCTAssertEqual(runTool.name, "subbot_run")
        XCTAssertEqual(runTool.tier, .t2ReadPersonal)
        XCTAssertTrue(runTool.requiredTCC.isEmpty)
        XCTAssertFalse(runTool.isReversible)
        
        XCTAssertEqual(workflowTool.name, "subbot_workflow")
        XCTAssertEqual(workflowTool.tier, .t2ReadPersonal)
        XCTAssertTrue(workflowTool.requiredTCC.isEmpty)
        XCTAssertFalse(workflowTool.isReversible)
        
        // 2. SubBotRunTool execution
        let runArgs = [
            "bot_type": "scrape",
            "target": "https://example.com/clean-article"
        ]
        let runResult = try await runTool.execute(args: runArgs, context: ToolExecutionContext())
        XCTAssertTrue(runResult.success)
        XCTAssertEqual(runResult.trust, .untrusted)
        XCTAssertTrue(runResult.message.hasPrefix("[UNTRUSTED WEB CONTENT]\n"))
        XCTAssertTrue(runResult.message.contains("# Content for https://example.com/clean-article"))
        XCTAssertTrue(runResult.message.contains("Clean sample paragraph."))
        
        // 3. SubBotWorkflowTool execution
        let wfArgs = [
            "workflow": "competitive_analysis",
            "urls": "https://example.com/compA,https://example.com/compB"
        ]
        let wfResult = try await workflowTool.execute(args: wfArgs, context: ToolExecutionContext())
        XCTAssertTrue(wfResult.success)
        XCTAssertEqual(wfResult.trust, .untrusted)
        XCTAssertTrue(wfResult.message.hasPrefix("[UNTRUSTED WEB CONTENT]\n"))
        XCTAssertTrue(wfResult.message.contains("Competitive Analysis Report"))
        XCTAssertTrue(wfResult.message.contains("- https://example.com/compA"))
        XCTAssertTrue(wfResult.message.contains("- https://example.com/compB"))
    }
}
