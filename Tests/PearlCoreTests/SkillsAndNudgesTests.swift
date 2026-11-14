import XCTest
@testable import PearlCore

final class SkillsAndNudgesTests: XCTestCase {
    var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }
    
    // MARK: - SkillEngine Tests
    
    func testSkillEngineDefaultSkillSeeding() async throws {
        let skillsDir = tempDirectory.appendingPathComponent("skills", isDirectory: true)
        let engine = SkillEngine(skillsDirectory: skillsDir)
        
        let initialSkills = await engine.loadSkills()
        XCTAssertTrue(initialSkills.isEmpty, "Skills directory should initially be empty")
        
        try await engine.seedDefaultSkillsIfEmpty()
        
        let seededSkills = await engine.loadSkills()
        XCTAssertEqual(seededSkills.count, 2, "Seeding should produce 2 default skills")
        
        let startWorkday = seededSkills.first { $0.name == "start-workday" }
        XCTAssertNotNil(startWorkday)
        XCTAssertEqual(startWorkday?.trigger, "start my workday")
        XCTAssertEqual(startWorkday?.description, "Check system readiness, calendar events, and top pending tasks")
        XCTAssertEqual(startWorkday?.steps.count, 3)
        XCTAssertEqual(startWorkday?.steps[0].utterance, "check battery")
        XCTAssertEqual(startWorkday?.steps[1].utterance, "list tasks")
        XCTAssertEqual(startWorkday?.steps[2].utterance, "list calendar events")
        
        let meetingPrep = seededSkills.first { $0.name == "meeting-prep" }
        XCTAssertNotNil(meetingPrep)
        XCTAssertEqual(meetingPrep?.trigger, "prep for my meeting")
        XCTAssertEqual(meetingPrep?.description, "Prepare calendar context, urgent tasks, and clipboard preview")
        XCTAssertEqual(meetingPrep?.steps.count, 3)
        XCTAssertEqual(meetingPrep?.steps[0].utterance, "list calendar events")
        XCTAssertEqual(meetingPrep?.steps[1].utterance, "list tasks")
        XCTAssertEqual(meetingPrep?.steps[2].utterance, "read clipboard")
        
        // Calling seed again should be idempotent and not duplicate
        try await engine.seedDefaultSkillsIfEmpty()
        let secondLoad = await engine.loadSkills()
        XCTAssertEqual(secondLoad.count, 2)
    }
    
    func testSkillEngineMarkdownFrontmatterParsing() async throws {
        let skillsDir = tempDirectory.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        
        let customMD = """
        ---
        name: code-review
        trigger: review my pr
        description: Review git changes and execute test suite
        ---
        1. Review changes - git status
        2. Run test suite - swift test
        """
        let fileURL = skillsDir.appendingPathComponent("code-review.md")
        try customMD.write(to: fileURL, atomically: true, encoding: .utf8)
        
        let engine = SkillEngine(skillsDirectory: skillsDir)
        let loaded = await engine.loadSkills()
        XCTAssertEqual(loaded.count, 1)
        
        let skill = loaded[0]
        XCTAssertEqual(skill.name, "code-review")
        XCTAssertEqual(skill.trigger, "review my pr")
        XCTAssertEqual(skill.description, "Review git changes and execute test suite")
        XCTAssertEqual(skill.steps.count, 2)
        XCTAssertEqual(skill.steps[0].index, 1)
        XCTAssertEqual(skill.steps[0].description, "Review changes")
        XCTAssertEqual(skill.steps[0].utterance, "git status")
        XCTAssertEqual(skill.steps[1].index, 2)
        XCTAssertEqual(skill.steps[1].description, "Run test suite")
        XCTAssertEqual(skill.steps[1].utterance, "swift test")
    }
    
    func testSkillEngineSaveMatchAndDeleteSkill() async throws {
        let skillsDir = tempDirectory.appendingPathComponent("skills", isDirectory: true)
        let engine = SkillEngine(skillsDirectory: skillsDir)
        
        let skill = SkillDefinition(
            name: "deep-focus",
            trigger: "activate deep focus",
            description: "Silence audio and focus environment",
            steps: [
                SkillStepDefinition(index: 1, description: "Mute volume", utterance: "mute"),
                SkillStepDefinition(index: 2, description: "Check tasks", utterance: "list tasks")
            ]
        )
        
        let savedURL = try await engine.saveSkill(skill)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        
        // Match by exact trigger
        let matchTrigger = await engine.matchSkill(for: "activate deep focus")
        XCTAssertEqual(matchTrigger?.name, "deep-focus")
        
        // Match by "run skill <name>"
        let matchRunSkill = await engine.matchSkill(for: "run skill deep-focus")
        XCTAssertEqual(matchRunSkill?.name, "deep-focus")
        
        // Match by "run skill <name with spaces>"
        let matchRunSkillSpaces = await engine.matchSkill(for: "run skill deep focus")
        XCTAssertEqual(matchRunSkillSpaces?.name, "deep-focus")
        
        // Match by "run <name>"
        let matchRun = await engine.matchSkill(for: "run deep-focus")
        XCTAssertEqual(matchRun?.name, "deep-focus")
        
        // Unknown command does not match
        let matchUnknown = await engine.matchSkill(for: "completely random utterance")
        XCTAssertNil(matchUnknown)
        
        // Delete skill
        try await engine.deleteSkill(name: "deep-focus")
        let loadedAfterDelete = await engine.loadSkills()
        XCTAssertTrue(loadedAfterDelete.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path))
    }
    
    // MARK: - Quiet Hours Tests
    
    func testBriefingEngineIsQuietHoursAcrossMidnight() {
        let calendar = Calendar.current
        let base = Date()
        func dateAt(hour: Int, minute: Int) -> Date {
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
        }
        
        let engine = BriefingEngine.shared
        
        // Across midnight (quietStartHour: 22, quietEndHour: 8)
        // Active at 23:00, 03:00, 07:59
        XCTAssertTrue(engine.isQuietHours(at: dateAt(hour: 23, minute: 0), quietStartHour: 22, quietEndHour: 8))
        XCTAssertTrue(engine.isQuietHours(at: dateAt(hour: 3, minute: 0), quietStartHour: 22, quietEndHour: 8))
        XCTAssertTrue(engine.isQuietHours(at: dateAt(hour: 7, minute: 59), quietStartHour: 22, quietEndHour: 8))
        
        // Inactive at 08:00, 14:00, 21:59
        XCTAssertFalse(engine.isQuietHours(at: dateAt(hour: 8, minute: 0), quietStartHour: 22, quietEndHour: 8))
        XCTAssertFalse(engine.isQuietHours(at: dateAt(hour: 14, minute: 0), quietStartHour: 22, quietEndHour: 8))
        XCTAssertFalse(engine.isQuietHours(at: dateAt(hour: 21, minute: 59), quietStartHour: 22, quietEndHour: 8))
    }
    
    func testBriefingEngineIsQuietHoursDaytimeInterval() {
        let calendar = Calendar.current
        let base = Date()
        func dateAt(hour: Int, minute: Int) -> Date {
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
        }
        
        let engine = BriefingEngine.shared
        // Daytime quiet hours: 13:00 to 15:00
        XCTAssertTrue(engine.isQuietHours(at: dateAt(hour: 13, minute: 30), quietStartHour: 13, quietEndHour: 15))
        XCTAssertTrue(engine.isQuietHours(at: dateAt(hour: 14, minute: 59), quietStartHour: 13, quietEndHour: 15))
        XCTAssertFalse(engine.isQuietHours(at: dateAt(hour: 12, minute: 59), quietStartHour: 13, quietEndHour: 15))
        XCTAssertFalse(engine.isQuietHours(at: dateAt(hour: 15, minute: 0), quietStartHour: 13, quietEndHour: 15))
    }
    
    // MARK: - Proactive Nudges Evaluation Tests
    
    func testEvaluateNudgesDaytimeContext() async throws {
        let dbURL = tempDirectory.appendingPathComponent("tasks.sqlite")
        let taskStore = try TaskStore(databaseURL: dbURL)
        
        let calendar = Calendar.current
        let daytimeDate = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
        let overdueDate = daytimeDate.addingTimeInterval(-3600) // 1 hour prior to reference daytime (13:00)
        _ = try await taskStore.createTask(
            title: "Submit Quarterly Report",
            priority: .high,
            dueDate: overdueDate
        )
        
        let engine = BriefingEngine(taskStore: taskStore)
        
        let nudges = try await engine.evaluateNudges(
            referenceDate: daytimeDate,
            batteryPercent: 18,
            isCharging: false,
            nextEventTitle: "Team Standup",
            minutesToNextEvent: 10,
            quietStartHour: 22,
            quietEndHour: 8
        )
        
        XCTAssertEqual(nudges.count, 3)
        
        let meetingNudge = nudges.first { $0.category == "calendar" }
        XCTAssertNotNil(meetingNudge)
        XCTAssertEqual(meetingNudge?.priority, .high)
        XCTAssertTrue(meetingNudge?.message.contains("Team Standup") ?? false)
        
        let taskNudge = nudges.first { $0.category == "tasks" }
        XCTAssertNotNil(taskNudge)
        XCTAssertEqual(taskNudge?.priority, .high)
        XCTAssertTrue(taskNudge?.message.contains("Submit Quarterly Report") ?? false)
        
        let batteryNudge = nudges.first { $0.category == "battery" }
        XCTAssertNotNil(batteryNudge)
        XCTAssertEqual(batteryNudge?.priority, .high)
        XCTAssertEqual(batteryNudge?.title, "Low Battery")
    }
    
    func testEvaluateNudgesSuppressedDuringQuietHours() async throws {
        let dbURL = tempDirectory.appendingPathComponent("tasks.sqlite")
        let taskStore = try TaskStore(databaseURL: dbURL)
        
        let calendar = Calendar.current
        let nightDate = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: Date())!
        let overdueDate = nightDate.addingTimeInterval(-3600)
        _ = try await taskStore.createTask(
            title: "Overdue Night Item",
            priority: .urgent,
            dueDate: overdueDate
        )
        
        let engine = BriefingEngine(taskStore: taskStore)
        
        // During quiet hours with non-critical battery (18%), all routine nudges must be suppressed
        let nudges = try await engine.evaluateNudges(
            referenceDate: nightDate,
            batteryPercent: 18,
            isCharging: false,
            nextEventTitle: "Tomorrow Review",
            minutesToNextEvent: 10,
            quietStartHour: 22,
            quietEndHour: 8
        )
        
        XCTAssertTrue(nudges.isEmpty, "Routine nudges should be completely suppressed during quiet hours")
    }
    
    func testEvaluateNudgesSurfacesCriticalBatteryDuringQuietHours() async throws {
        let dbURL = tempDirectory.appendingPathComponent("tasks.sqlite")
        let taskStore = try TaskStore(databaseURL: dbURL)
        let engine = BriefingEngine(taskStore: taskStore)
        
        let calendar = Calendar.current
        let nightDate = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: Date())!
        
        // Critical battery (< 10%) should break through quiet hours
        let nudges = try await engine.evaluateNudges(
            referenceDate: nightDate,
            batteryPercent: 8,
            isCharging: false,
            nextEventTitle: "Early Morning Brief",
            minutesToNextEvent: 5,
            quietStartHour: 22,
            quietEndHour: 8
        )
        
        XCTAssertEqual(nudges.count, 1)
        let criticalNudge = nudges[0]
        XCTAssertEqual(criticalNudge.category, "battery")
        XCTAssertEqual(criticalNudge.priority, .urgent)
        XCTAssertEqual(criticalNudge.title, "Critical Battery")
        XCTAssertTrue(criticalNudge.message.contains("8%"))
    }
    
    func testEvaluateNudgesNoBatteryNudgeWhenCharging() async throws {
        let dbURL = tempDirectory.appendingPathComponent("tasks.sqlite")
        let taskStore = try TaskStore(databaseURL: dbURL)
        let engine = BriefingEngine(taskStore: taskStore)
        
        let calendar = Calendar.current
        let daytime = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!
        
        let nudges = try await engine.evaluateNudges(
            referenceDate: daytime,
            batteryPercent: 8,
            isCharging: true,
            quietStartHour: 22,
            quietEndHour: 8
        )
        
        let batteryNudge = nudges.first { $0.category == "battery" }
        XCTAssertNil(batteryNudge, "No battery warning should be emitted when device is charging")
    }
}
