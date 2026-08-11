from pathlib import Path

models_path = Path("AgentPad/Models/Models.swift")
tests_path = Path("AgentPadTests/AgentRuntimeLifecycleTests.swift")
models = models_path.read_text()
tests = tests_path.read_text()

old_purge = '''    func purge(_ conversationID: UUID, defaults: UserDefaults = .standard) {
        guard let raw = defaults.string(forKey: Self.storageKey),
              let data = raw.data(using: .utf8),
              var drafts = try? JSONDecoder().decode([String: String].self, from: data),
              drafts.removeValue(forKey: conversationID.uuidString) != nil,
              let encoded = try? JSONEncoder().encode(drafts),
              let updated = String(data: encoded, encoding: .utf8) else { return }
        defaults.set(updated, forKey: Self.storageKey)
    }
'''
new_purge = '''    func purge(_ conversationID: UUID, defaults: UserDefaults = .standard) {
        guard let storedValue = defaults.object(forKey: Self.storageKey) else { return }
        guard let raw = storedValue as? String,
              let data = raw.data(using: .utf8),
              var drafts = try? JSONDecoder().decode([String: String].self, from: data) else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        guard drafts.removeValue(forKey: conversationID.uuidString) != nil,
              let encoded = try? JSONEncoder().encode(drafts),
              let updated = String(data: encoded, encoding: .utf8) else { return }
        defaults.set(updated, forKey: Self.storageKey)
    }
'''
if models.count(old_purge) != 1:
    raise SystemExit(f"expected one exact purge implementation, found {models.count(old_purge)}")
models = models.replace(old_purge, new_purge, 1)

existing_test = '''    func testDeletedConversationDraftPurgesOnlyTargetAndInstallsTombstone() throws {
        let suiteName = "NovaForge.ChatDeleteDraft.\\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let deletedConversationID = UUID()
        let preservedConversationID = UUID()
        let encoded = try JSONEncoder().encode([
            deletedConversationID.uuidString: "discarded unsent text",
            preservedConversationID.uuidString: "preserved unsent text",
        ])
        defaults.set(
            try XCTUnwrap(String(data: encoded, encoding: .utf8)),
            forKey: ConversationDraftPersistence.storageKey
        )

        ConversationDraftPersistence.shared.markDeletedAndPurge(
            deletedConversationID,
            defaults: defaults
        )

        let raw = try XCTUnwrap(
            defaults.string(forKey: ConversationDraftPersistence.storageKey)
        )
        let data = try XCTUnwrap(raw.data(using: .utf8))
        let drafts = try JSONDecoder().decode([String: String].self, from: data)

        XCTAssertNil(drafts[deletedConversationID.uuidString])
        XCTAssertEqual(
            drafts[preservedConversationID.uuidString],
            "preserved unsent text"
        )
        XCTAssertFalse(
            ConversationDraftPersistence.shared.shouldPersist(deletedConversationID)
        )
        XCTAssertTrue(
            ConversationDraftPersistence.shared.shouldPersist(preservedConversationID)
        )
    }
'''
new_test = existing_test + '''
    func testDeletedConversationDraftClearsMalformedStorageAndInstallsTombstone() throws {
        let suiteName = "NovaForge.ChatDeleteDraft.Corrupt.\\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let deletedConversationID = UUID()
        defaults.set(
            "{malformed-draft-json",
            forKey: ConversationDraftPersistence.storageKey
        )

        ConversationDraftPersistence.shared.markDeletedAndPurge(
            deletedConversationID,
            defaults: defaults
        )

        XCTAssertNil(
            defaults.object(forKey: ConversationDraftPersistence.storageKey),
            "Successful deletion must not leave undecodable user-authored draft bytes behind."
        )
        XCTAssertFalse(
            ConversationDraftPersistence.shared.shouldPersist(deletedConversationID)
        )
    }
'''
if tests.count(existing_test) != 1:
    raise SystemExit(f"expected one exact existing draft persistence test, found {tests.count(existing_test)}")
if "testDeletedConversationDraftClearsMalformedStorageAndInstallsTombstone" in tests:
    raise SystemExit("malformed draft regression already exists")
tests = tests.replace(existing_test, new_test, 1)

models_path.write_text(models)
tests_path.write_text(tests)
