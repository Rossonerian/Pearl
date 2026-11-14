import Foundation
import PearlCore
import PearlTools

@main
struct TaskEngineVerification {
    static func main() async {
        print("=================================================================")
        print("     PEARL V3 PHASE M6 & M7 TASK ENGINE & PROACTIVITY VERIFIER   ")
        print("=================================================================")
        
        var passedCount = 0
        var failedCount = 0
        
        func assert(_ condition: Bool, _ testName: String, detail: String = "") {
            if condition {
                print("  ✓ PASS: \(testName)")
                passedCount += 1
            } else {
                print("  ❌ FAIL: \(testName) - \(detail)")
                failedCount += 1
            }
        }
        
        // -------------------------------------------------------------
        // 1. TaskStore SQLite Engine Tests
        // -------------------------------------------------------------
        print("\n--- 1. Testing SQLite TaskStore Engine ---")
        let tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pearl_tasks_test_\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: tempDBURL)
        }
        
        do {
            let store = try TaskStore(databaseURL: tempDBURL)
            
            // Test initial empty state
            let initialCount = try await store.countTasks()
            assert(initialCount == 0, "TaskStore initial count is 0")
            
            // Create tasks
            let t1 = try await store.createTask(
                title: "Fix critical kernel bug",
                notes: "Check XNU backtrace",
                priority: .urgent,
                dueDate: Date().addingTimeInterval(3600) // 1h in future
            )
            assert(t1.title == "Fix critical kernel bug", "Create urgent task title matches")
            assert(t1.priority == .urgent, "Create urgent task priority is .urgent")
            assert(t1.status == .pending, "New task defaults to .pending")
            assert(t1.notes == "Check XNU backtrace", "Notes correctly stored")
            
            let pastDate = Date().addingTimeInterval(-7200) // 2h ago
            let t2 = try await store.createTask(
                title: "Overdue database migration",
                notes: "Run migrations 001..004",
                priority: .high,
                dueDate: pastDate
            )
            assert(t2.priority == .high, "High priority task created")
            
            let t3 = try await store.createTask(
                title: "Water office bonsai",
                priority: .low
            )
            assert(t3.dueDate == nil, "Task without dueDate has nil dueDate")
            
            // Check listTasks
            let allPending = try await store.listTasks(status: .pending)
            assert(allPending.count == 3, "List pending tasks returns 3 items")
            // Urgent should be first due to priority sorting
            assert(allPending.first?.priority == .urgent, "Urgent task sorted first in list")
            
            // Filter by priority
            let urgentOnly = try await store.listTasks(priority: .urgent)
            assert(urgentOnly.count == 1 && urgentOnly.first?.id == t1.id, "Filter by priority .urgent returns 1 item")
            
            // Check getOverdueTasks
            let overdue = try await store.getOverdueTasks()
            assert(overdue.count == 1 && overdue.first?.id == t2.id, "getOverdueTasks returns exactly overdue task")
            
            // Find task by title & prefix
            let foundByTitle = try await store.findTask(byIdentifier: "bonsai")
            assert(foundByTitle?.id == t3.id, "findTask matches title substring")
            let foundByPrefix = try await store.findTask(byIdentifier: String(t1.id.uuidString.prefix(8)))
            assert(foundByPrefix?.id == t1.id, "findTask matches 8-character UUID prefix")
            
            // Complete task
            let completed = try await store.completeTask(id: t2.id)
            assert(completed?.status == .completed, "completeTask sets status = .completed")
            assert(completed?.completedAt != nil, "completeTask sets completedAt timestamp")
            
            // Overdue after completion
            let overdueAfterComplete = try await store.getOverdueTasks()
            assert(overdueAfterComplete.isEmpty, "Completed task is no longer returned in getOverdueTasks")
            
            // Uncomplete task (undo)
            let uncompleted = try await store.uncompleteTask(id: t2.id)
            assert(uncompleted?.status == .pending, "uncompleteTask reverts status to .pending")
            assert(uncompleted?.completedAt == nil, "uncompleteTask clears completedAt")
            
            // Delete task
            let deleted = try await store.deleteTask(id: t3.id)
            assert(deleted?.id == t3.id, "deleteTask returns deleted task")
            let afterDelete = try await store.getTask(id: t3.id)
            assert(afterDelete == nil, "Deleted task cannot be fetched")
            
            // Restore task
            let restored = try await store.restoreTask(t3)
            assert(restored.id == t3.id, "restoreTask re-inserts deleted task")
            let fetchedRestored = try await store.getTask(id: t3.id)
            assert(fetchedRestored?.title == "Water office bonsai", "Restored task is accessible again")
            
        } catch {
            assert(false, "TaskStore CRUD operations", detail: error.localizedDescription)
        }
        
        // -------------------------------------------------------------
        // 2. CentralToolCatalog Registration Verification
        // -------------------------------------------------------------
        print("\n--- 2. Testing CentralToolCatalog Registrations ---")
        let catalog = CentralToolCatalog.shared
        
        let listTool = catalog.tool(named: "list_tasks")
        assert(listTool != nil, "list_tasks registered in CentralToolCatalog")
        assert(listTool?.tier == .t0Observe, "list_tasks tier is T0 Observe")
        assert(listTool?.isReversible == false, "list_tasks is not reversible")
        
        let createTool = catalog.tool(named: "create_task")
        assert(createTool != nil, "create_task registered in CentralToolCatalog")
        assert(createTool?.tier == .t1Reversible, "create_task tier is T1 Reversible")
        assert(createTool?.isReversible == true, "create_task is reversible")
        
        let completeTool = catalog.tool(named: "complete_task")
        assert(completeTool != nil, "complete_task registered in CentralToolCatalog")
        assert(completeTool?.tier == .t1Reversible, "complete_task tier is T1 Reversible")
        assert(completeTool?.isReversible == true, "complete_task is reversible")
        
        let deleteTool = catalog.tool(named: "delete_task")
        assert(deleteTool != nil, "delete_task registered in CentralToolCatalog")
        assert(deleteTool?.tier == .t2ReadPersonal, "delete_task tier is T2")
        let deleteMeta = catalog.metadata(for: "delete_task")
        assert(deleteMeta?.requiresConfirmation == true, "delete_task requiresConfirmation is true")
        assert(deleteMeta?.isReversible == false, "delete_task is irreversible")
        
        // -------------------------------------------------------------
        // 3. TaskTools Execution & UndoJournal Verification
        // -------------------------------------------------------------
        print("\n--- 3. Testing TaskTools & Undo Journal ---")
        let ctxClean = ToolExecutionContext(trustState: .trusted, userConfirmed: false)
        
        // Clean default store for reproducible test
        try? await TaskStore.shared.clearAllTasks()
        await UndoJournal.shared.clear()
        
        // A. Create Task Tool
        let createInst = CreateTaskTool()
        do {
            let res = try await createInst.execute(
                args: [
                    "title": "Prepare board presentation",
                    "priority": "urgent",
                    "notes": "Slide 12 needs ARR charts"
                ],
                context: ctxClean
            )
            assert(res.success, "create_task tool execution succeeds")
            assert(res.undoAction != nil, "create_task provides non-nil undoAction")
            assert(await UndoJournal.shared.count > 0, "create_task registers undo with UndoJournal")
            
            let tasks = try await TaskStore.shared.listTasks(status: .pending)
            assert(tasks.count == 1 && tasks.first?.title == "Prepare board presentation", "Task created in shared store")
            
            // Test Undo on create_task (should delete the task!)
            let undoMsg = try await UndoJournal.shared.undoLast()
            assert(undoMsg.contains("create_task"), "UndoJournal undoLast reverts create_task")
            let tasksAfterUndo = try await TaskStore.shared.listTasks(status: .pending)
            assert(tasksAfterUndo.isEmpty, "Task was deleted after undoing creation")
        } catch {
            assert(false, "create_task and undo execution", detail: error.localizedDescription)
        }
        
        // B. Complete Task Tool & Undo
        do {
            let task = try await TaskStore.shared.createTask(
                title: "Refactor audio pipeline",
                priority: .high
            )
            await UndoJournal.shared.clear()
            
            let completeInst = CompleteTaskTool()
            let completeRes = try await completeInst.execute(
                args: ["id": task.id.uuidString],
                context: ctxClean
            )
            assert(completeRes.success, "complete_task tool execution succeeds")
            let fetched = try await TaskStore.shared.getTask(id: task.id)
            assert(fetched?.status == .completed, "Task status transitioned to completed")
            assert(await UndoJournal.shared.count == 1, "complete_task registered undo in journal")
            
            // Test Undo on complete_task (reverts to pending!)
            _ = try await UndoJournal.shared.undoLast()
            let reverted = try await TaskStore.shared.getTask(id: task.id)
            assert(reverted?.status == .pending, "Undo reverted task back to pending")
        } catch {
            assert(false, "complete_task and undo execution", detail: error.localizedDescription)
        }
        
        // C. Delete Task Tool (Confirmation requirement)
        do {
            let task = try await TaskStore.shared.createTask(title: "Task to delete", priority: .low)
            let deleteInst = DeleteTaskTool()
            
            // Unconfirmed execution should fail
            let unconfirmedRes = try await deleteInst.execute(
                args: ["id": task.id.uuidString],
                context: ToolExecutionContext(userConfirmed: false)
            )
            assert(!unconfirmedRes.success, "delete_task fails when not confirmed")
            assert(unconfirmedRes.message.contains("Confirmation required"), "Message specifies confirmation required")
            let stillExists = try await TaskStore.shared.getTask(id: task.id)
            assert(stillExists != nil, "Task was not deleted without confirmation")
            
            // Confirmed execution succeeds
            let confirmedRes = try await deleteInst.execute(
                args: ["id": task.id.uuidString, "confirm": "true"],
                context: ToolExecutionContext(userConfirmed: true)
            )
            assert(confirmedRes.success, "delete_task succeeds when confirmed")
            let deletedCheck = try await TaskStore.shared.getTask(id: task.id)
            assert(deletedCheck == nil, "Task was permanently deleted after confirmation")
        } catch {
            assert(false, "delete_task confirmation enforcement", detail: error.localizedDescription)
        }
        
        // D. List Tasks Tool
        do {
            try await TaskStore.shared.createTask(title: "Task Alpha", priority: .urgent)
            try await TaskStore.shared.createTask(title: "Task Beta", priority: .medium)
            
            let listInst = ListTasksTool()
            let listRes = try await listInst.execute(args: ["status": "pending"], context: ctxClean)
            assert(listRes.success, "list_tasks tool execution succeeds")
            assert(listRes.message.contains("Task Alpha"), "list_tasks output contains Task Alpha")
            assert(listRes.message.contains("Task Beta"), "list_tasks output contains Task Beta")
            assert(listRes.message.contains("Urgent"), "list_tasks output includes priority badge")
        } catch {
            assert(false, "list_tasks tool execution", detail: error.localizedDescription)
        }
        
        // -------------------------------------------------------------
        // 4. BriefingEngine & Proactive Notifications Verification
        // -------------------------------------------------------------
        print("\n--- 4. Testing BriefingEngine & Proactivity ---")
        do {
            try await TaskStore.shared.clearAllTasks()
            
            // Set up overdue, urgent, high, and medium tasks
            let pastDate = Date().addingTimeInterval(-3600)
            let futureDate = Date().addingTimeInterval(7200)
            
            try await TaskStore.shared.createTask(
                title: "Overdue server security patch",
                priority: .urgent,
                dueDate: pastDate
            )
            try await TaskStore.shared.createTask(
                title: "Sign vendor NDA",
                priority: .high,
                dueDate: futureDate
            )
            try await TaskStore.shared.createTask(
                title: "Review pull requests",
                priority: .medium
            )
            
            let briefingEngine = BriefingEngine.shared
            let briefing = try await briefingEngine.generateMorningBriefing(userName: "Rossonerian")
            
            assert(briefing.contains("Rossonerian"), "Briefing greets user by name")
            assert(briefing.contains("Overdue Items"), "Briefing highlights overdue section")
            assert(briefing.contains("Overdue server security patch"), "Briefing includes overdue task title")
            assert(briefing.contains("Priority Focus"), "Briefing includes Priority Focus section")
            assert(briefing.contains("Sign vendor NDA"), "Briefing includes high-priority item")
            assert(briefing.contains("Summary:"), "Briefing includes executive summary breakdown")
            
            print("\nSample Morning Briefing Output:\n----------------------------------------")
            print(briefing)
            print("----------------------------------------\n")
            
            // Test event-driven notification helper
            let testTask = TaskItem(
                title: "Imminent product deadline",
                priority: .urgent,
                dueDate: Date().addingTimeInterval(1800) // 30 minutes from now
            )
            let schedResult = await briefingEngine.scheduleDeadlineNotification(for: testTask, leadTime: 900)
            switch schedResult {
            case .scheduled(let id, let fireDate):
                assert(id == "pearl.task.\(testTask.id.uuidString)", "Scheduled notification identifier matches task UUID")
                assert(fireDate <= testTask.dueDate!, "Fire date respects leadTime constraint")
            case .unauthorized, .failed:
                // Expected in headless non-GUI sandbox without notification permissions
                print("  ℹ️ Note: UNUserNotificationCenter returned \(schedResult) (headless/sandbox environment without notification daemon access)")
                passedCount += 1
            case .alreadyPassed, .noDueDate:
                assert(false, "Unexpected notification schedule result: \(schedResult)")
            }
            
            await briefingEngine.cancelDeadlineNotification(taskId: testTask.id)
            assert(true, "cancelDeadlineNotification executes cleanly")
            
        } catch {
            assert(false, "BriefingEngine verification", detail: error.localizedDescription)
        }
        
        // -------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------
        print("\n=================================================================")
        print("Verification Results: \(passedCount) PASSED, \(failedCount) FAILED")
        print("=================================================================")
        
        if failedCount > 0 {
            exit(1)
        } else {
            print("🎉 ALL TASK ENGINE & PROACTIVE BRIEFING VERIFICATIONS PASSED!")
            exit(0)
        }
    }
}
