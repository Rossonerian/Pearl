import XCTest
@testable import PearlCore

final class DeterministicRouterTests: XCTestCase {
    var router: DeterministicRouter!
    
    override func setUp() {
        super.setUp()
        router = DeterministicRouter()
    }
    
    override func tearDown() {
        router = nil
        super.tearDown()
    }
    
    // MARK: - Politeness Prefix & Suffix Stripping
    
    func testPolitenessPrefixStripping() {
        XCTAssertEqual(router.cleanUtterance("hey pearl, open Safari"), "open Safari")
        XCTAssertEqual(router.cleanUtterance("hey pearl mute"), "mute")
        XCTAssertEqual(router.cleanUtterance("pearl, check battery"), "check battery")
        XCTAssertEqual(router.cleanUtterance("pearl take screenshot"), "take screenshot")
        XCTAssertEqual(router.cleanUtterance("please, silence"), "silence")
        XCTAssertEqual(router.cleanUtterance("please volume 50"), "volume 50")
        XCTAssertEqual(router.cleanUtterance("could you please open Notes"), "open Notes")
        XCTAssertEqual(router.cleanUtterance("could you check battery"), "check battery")
        XCTAssertEqual(router.cleanUtterance("can you please git status"), "git status")
        XCTAssertEqual(router.cleanUtterance("can you unmute"), "unmute")
    }
    
    func testPolitenessSuffixStripping() {
        XCTAssertEqual(router.cleanUtterance("open Safari please"), "open Safari")
        XCTAssertEqual(router.cleanUtterance("mute, please"), "mute")
    }
    
    func testNestedPolitenessStripping() {
        let cleaned = router.cleanUtterance("Hey Pearl, could you please open Safari, please")
        XCTAssertEqual(cleaned, "open Safari")
    }
    
    // MARK: - Exact Tool Selection & Golden Utterances
    
    func testBatteryIntentSelection() {
        let batteryUtterances = [
            "battery",
            "check battery",
            "what is the battery",
            "power level",
            "is it charging",
            "is macbook plugged into power"
        ]
        
        for utterance in batteryUtterances {
            guard let intent = router.resolve(utterance: utterance) else {
                XCTFail("Expected deterministic resolution for '\(utterance)'")
                continue
            }
            XCTAssertEqual(intent.toolName, "battery", "Failed on '\(utterance)'")
            XCTAssertEqual(intent.confidence, 1.0, accuracy: 0.01)
        }
    }
    
    func testVolumeIntentSelection() {
        // Mute
        let muteUtterances = ["mute", "silence", "turn sound off", "sound off", "please mute"]
        for u in muteUtterances {
            let intent = router.resolve(utterance: u)
            XCTAssertNotNil(intent, "Failed on '\(u)'")
            XCTAssertEqual(intent?.toolName, "volume")
            XCTAssertEqual(intent?.arguments["level"], "0")
        }
        
        // Unmute
        let unmuteIntent = router.resolve(utterance: "unmute")
        XCTAssertNotNil(unmuteIntent)
        XCTAssertEqual(unmuteIntent?.toolName, "volume")
        XCTAssertEqual(unmuteIntent?.arguments["level"], "30")
        
        // Explicit volume levels
        let volCases: [(String, String)] = [
            ("volume 50", "50"),
            ("set volume 80", "80"),
            ("volume to 25", "25"),
            ("hey pearl set volume 100", "100")
        ]
        for (query, expected) in volCases {
            let intent = router.resolve(utterance: query)
            XCTAssertNotNil(intent, "Failed on '\(query)'")
            XCTAssertEqual(intent?.toolName, "volume")
            XCTAssertEqual(intent?.arguments["level"], expected)
        }
    }
    
    func testScreenshotIntentSelection() {
        let captureUtterances = [
            "take screenshot",
            "capture screen",
            "capture display",
            "capture my screen",
            "grab screen"
        ]
        for u in captureUtterances {
            let intent = router.resolve(utterance: u)
            XCTAssertNotNil(intent, "Failed on '\(u)'")
            XCTAssertEqual(intent?.toolName, "screenshot")
        }
        
        let trashUtterances = [
            "clean up screenshots",
            "trash screenshots",
            "delete screenshots",
            "clean screenshot"
        ]
        for u in trashUtterances {
            let intent = router.resolve(utterance: u)
            XCTAssertNotNil(intent, "Failed on '\(u)'")
            XCTAssertEqual(intent?.toolName, "trash_screenshots")
        }
    }
    
    func testAppLaunchAndQuitSelection() {
        // Open / Launch
        let openIntent = router.resolve(utterance: "open Safari")
        XCTAssertNotNil(openIntent)
        XCTAssertEqual(openIntent?.toolName, "open_app")
        XCTAssertEqual(openIntent?.arguments["app"], "Safari")
        
        let launchIntent = router.resolve(utterance: "launch Visual Studio Code")
        XCTAssertNotNil(launchIntent)
        XCTAssertEqual(launchIntent?.toolName, "open_app")
        XCTAssertEqual(launchIntent?.arguments["app"], "Visual Studio Code")
        
        // Close / Quit
        let closeIntent = router.resolve(utterance: "close Safari")
        XCTAssertNotNil(closeIntent)
        XCTAssertEqual(closeIntent?.toolName, "close_app")
        XCTAssertEqual(closeIntent?.arguments["app"], "Safari")
        
        let quitIntent = router.resolve(utterance: "quit Slack")
        XCTAssertNotNil(quitIntent)
        XCTAssertEqual(quitIntent?.toolName, "close_app")
        XCTAssertEqual(quitIntent?.arguments["app"], "Slack")
    }
    
    func testGitIntentSelection() {
        let gitUtterances = [
            "git status",
            "git branch",
            "check working tree",
            "show repo status"
        ]
        for u in gitUtterances {
            let intent = router.resolve(utterance: u)
            XCTAssertNotNil(intent, "Failed on '\(u)'")
            XCTAssertEqual(intent?.toolName, "git")
            XCTAssertEqual(intent?.arguments["subcommand"], "status")
        }
    }
    
    func testReminderIntentSelection() {
        let r1 = router.resolve(utterance: "remind me to pick up dry cleaning")
        XCTAssertNotNil(r1)
        XCTAssertEqual(r1?.toolName, "reminder")
        XCTAssertEqual(r1?.arguments["title"], "pick up dry cleaning")
        
        let r2 = router.resolve(utterance: "create reminder submit quarterly taxes")
        XCTAssertNotNil(r2)
        XCTAssertEqual(r2?.toolName, "reminder")
        XCTAssertEqual(r2?.arguments["title"], "submit quarterly taxes")
        
        let r3 = router.resolve(utterance: "add reminder team standup at 10")
        XCTAssertNotNil(r3)
        XCTAssertEqual(r3?.toolName, "reminder")
        XCTAssertEqual(r3?.arguments["title"], "team standup at 10")
    }
    
    func testUndoIntentSelection() {
        let undoCases = ["undo", "undo that", "revert that", "please undo"]
        for u in undoCases {
            let intent = router.resolve(utterance: u)
            XCTAssertNotNil(intent, "Failed on '\(u)'")
            XCTAssertEqual(intent?.toolName, "undo")
        }
    }
    
    // MARK: - Negation Non-Execution
    
    func testNegationNonExecutionInResolve() {
        let negated = [
            "don't open Safari",
            "dont mute",
            "do not take screenshot",
            "never mind",
            "cancel that",
            "abort",
            "ignore that",
            "please don't quit Slack"
        ]
        
        for u in negated {
            let intent = router.resolve(utterance: u)
            XCTAssertNil(intent, "Expected nil intent for negated utterance: '\(u)'")
        }
    }
    
    func testNegationRouteReturnsCancelled() async {
        let negated = [
            "don't open Safari",
            "do not close Safari",
            "never mind",
            "cancel that",
            "abort"
        ]
        
        for u in negated {
            let result = await router.route(utterance: u)
            switch result {
            case .cancelled(let reason):
                XCTAssertTrue(reason.contains("Negation detected"), "Unexpected cancel reason: \(reason)")
            default:
                XCTFail("Expected .cancelled for negated utterance '\(u)', got \(result)")
            }
        }
    }
    
    func testEmptyUtteranceReturnsCancelled() async {
        let emptyResult = await router.route(utterance: "   ")
        guard case .cancelled(let reason) = emptyResult else {
            return XCTFail("Expected .cancelled for empty utterance")
        }
        XCTAssertTrue(reason.contains("Empty utterance"))
    }
    
    func testDeterministicRouteProducesBadge() async {
        let result = await router.route(utterance: "mute")
        guard case .deterministic(let intent, let badge) = result else {
            return XCTFail("Expected .deterministic for 'mute'")
        }
        XCTAssertEqual(intent.toolName, "volume")
        XCTAssertEqual(badge.provider, "Deterministic")
        XCTAssertTrue(badge.isLocal)
    }
    
    func testClosedVocabularyGeneration() {
        let vocab = router.generateClosedVocabulary()
        XCTAssertFalse(vocab.isEmpty)
        XCTAssertTrue(vocab.contains("mute volume"))
        XCTAssertTrue(vocab.contains("undo"))
        XCTAssertTrue(vocab.contains("git status"))
    }
}
