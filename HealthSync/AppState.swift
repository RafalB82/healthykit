import Foundation
import BackgroundTasks
import SwiftUI

struct BackgroundSyncScheduler {
    static let taskIdentifier = "com.megabyte0x.HealthSync.background-sync"

    func reschedule(for frequency: SyncFrequency, now: Date = Date()) throws {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        guard let earliestBeginDate = BackgroundSyncSchedule.earliestBeginDate(for: frequency, now: now) else {
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = earliestBeginDate
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }
}

enum HealthSyncUserMessages {
    static let noNewSamplesFound = "No new Apple Health samples found."
    static let noSamplesFoundForDateRange = "No Apple Health samples found for this date range."

    static func displayLogMessage(_ message: String) -> String {
        message
            .replacingOccurrences(of: "No new HealthKit samples found.", with: noNewSamplesFound)
            .replacingOccurrences(of: "No HealthKit samples found for this date range.", with: noSamplesFoundForDateRange)
    }
}

struct HealthActionFeedback: Equatable {
    enum Kind: Equatable {
        case success
        case info
        case error
    }

    let kind: Kind
    let message: String

    static let permissionRequested = HealthActionFeedback(
        kind: .success,
        message: "Health access request completed. You can change access at any time in iPhone Settings."
    )
    static let noSamples = HealthActionFeedback(
        kind: .info,
        message: "No health samples were found for the last 24 hours."
    )
    static let syncCompleted = HealthActionFeedback(
        kind: .success,
        message: "The last 24 hours were synced successfully."
    )

    static func failure(_ message: String) -> HealthActionFeedback {
        HealthActionFeedback(kind: .error, message: message)
    }
}

enum DevelopmentKeychainBypass {
    static var isEnabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func hasStoredToken(readProductionTokenState: () throws -> Bool) throws -> Bool {
        guard !isEnabled else { return true }
        return try readProductionTokenState()
    }

    static func hostedAgentToken(readProductionToken: () throws -> String?) throws -> String {
        guard !isEnabled else { return "" }
        return try readProductionToken() ?? ""
    }
}

enum BusyOperation {
    static func canStart(isBusy: Bool) -> Bool {
        !isBusy
    }
}

enum UploadDestinationPreparation: Equatable {
    case ready
    case provisionHostedStorage

    static func resolve(
        storageMode: StorageMode,
        hasAgentEndpoint: Bool,
        hasAgentToken: Bool,
        hasIngestToken: Bool
    ) -> UploadDestinationPreparation {
        guard storageMode == .hostedHealthSync else { return .ready }
        return hasAgentEndpoint && hasAgentToken && hasIngestToken
            ? .ready
            : .provisionHostedStorage
    }
}

enum BackfillSyncError: LocalizedError, Equatable {
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .uploadFailed(message):
            message
        }
    }
}

enum BackfillSync {
    private static let chunkLength: TimeInterval = 30 * 24 * 60 * 60
    private static let maxRecordsPerUpload = 100

    static func chunks(start: Date, end: Date) -> [SyncDateRange] {
        guard end > start else { return [] }

        var ranges: [SyncDateRange] = []
        var cursor = start
        while cursor < end {
            let next = min(cursor.addingTimeInterval(chunkLength), end)
            ranges.append(SyncDateRange(start: cursor, end: next))
            cursor = next
        }
        return ranges
    }

    static func validateUpload(_ result: SyncRunResult) throws {
        guard result.failedCount == 0 else {
            throw BackfillSyncError.uploadFailed(result.messages.last ?? "Backfill upload failed.")
        }
        guard result.uploadedCount > 0 else {
            throw BackfillSyncError.uploadFailed("Upload is still queued. Retry after the current sync finishes.")
        }
    }

    static func shouldUpload(_ payload: SyncPayload) -> Bool {
        !payload.isEmpty
    }

    static func uploadPayloads(for payload: SyncPayload) -> [SyncPayload] {
        payload.chunked(maxRecords: maxRecordsPerUpload)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var shouldShowOnboarding = true
    @Published var settings = AppSettings.default
    @Published var status = SyncStatus.empty
    @Published var logs: [SyncLogEntry] = []
    @Published var permissionSummary = "Not requested"
    @Published var authTokenDraft = ""
    @Published var hostedAgentToken = ""
    @Published var hasStoredToken = false
    @Published var isBusy = false
    @Published var backfillProgress = 0.0
    @Published var backfillError: String?
    @Published var lastError: String?
    @Published var actionFeedback: HealthActionFeedback?
    /// True while a sync or backfill runs, so the UI offers Stop sync.
    @Published private(set) var canStopSync = false
    @Published private(set) var isStoppingSync = false

    private var store: SQLiteLocalStore?
    private var syncEngine: SyncEngine?
    private var incrementalSyncRunner: IncrementalSyncRunner?
    private let healthKit = HealthKitManager()
    private let normalizer = HealthNormalizer()
    private let keychain = KeychainStore()
    private let backgroundSyncScheduler = BackgroundSyncScheduler()
    private var periodicSyncTask: Task<Void, Never>?
    /// The one handle for the current busy operation; `stopSync()` cancels it.
    private var busyOperation: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var pendingIncrementalSync = false
    private var pendingIncrementalWaiters: [CheckedContinuation<Bool, Never>] = []

    func bootstrap() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performBootstrap()
        }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        do {
            let localStore = try SQLiteLocalStore()
            store = localStore
            syncEngine = SyncEngine(store: localStore)
            incrementalSyncRunner = IncrementalSyncRunner(store: localStore, reader: healthKit)
            settings = try await localStore.loadSettings()
            hasStoredToken = try DevelopmentKeychainBypass.hasStoredToken {
                try hasTokenForCurrentStorageMode()
            }
            hostedAgentToken = try DevelopmentKeychainBypass.hostedAgentToken {
                try keychain.readHostedAgentToken()
            }
            shouldShowOnboarding = !settings.hasRequestedHealthPermissions
            permissionSummary = healthKit.isHealthDataAvailable
                ? (settings.hasRequestedHealthPermissions ? "Requested" : "Not requested")
                : "Unavailable"
            try await localStore.pruneUploaded(olderThan: Date().addingTimeInterval(-7 * 24 * 60 * 60))
            await refresh()
            await startObserversIfPossible()
            restartPeriodicSync()
        } catch {
            lastError = userMessage(from: error)
        }
    }

    func refresh() async {
        guard let store else { return }
        do {
            status = try await store.syncStatus()
            logs = try await store.recentLogs()
        } catch {
            lastError = userMessage(from: error)
        }
    }

    func connectAppleHealth() async {
        await runBusy { [self] in
            try await prepareHostedStorageIfNeeded()
            try await healthKit.requestReadPermissions(for: settings.selectedTypes)
            settings.hasRequestedHealthPermissions = true
            shouldShowOnboarding = false
            permissionSummary = "Requested"
            actionFeedback = .permissionRequested
            try await saveSettingsOnly()
            await startObserversIfPossible()
            restartPeriodicSync()
        }
    }

    func set(type: HealthDataType, enabled: Bool) {
        if enabled {
            settings.selectedTypes.insert(type)
        } else {
            settings.selectedTypes.remove(type)
        }
    }

    func saveSettingsAndToken() async {
        await runBusy { [self] in
            try await saveSettingsOnly()
            if !authTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try keychain.saveToken(authTokenDraft)
                authTokenDraft = ""
                hasStoredToken = true
            }
            await startObserversIfPossible()
            restartPeriodicSync()
        }
    }

    func createHostedStorage() async {
        await runBusy { [self] in
            try await prepareHostedStorageIfNeeded()
            restartPeriodicSync()
        }
    }

    func resetHostedStorage() async {
        await runBusy { [self] in
            let client = APIClient(maxAttempts: 1)
            let label = "Personal Health"
            let ingestToken = (try keychain.readHostedIngestToken() ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let response: HostedWorkspaceProvisioningResponse

            if ingestToken.isEmpty {
                response = try await client.provisionHostedWorkspace(
                    baseURL: AppSettings.hostedBackendURL,
                    label: label
                )
            } else {
                do {
                    response = try await client.resetHostedWorkspace(
                        baseURL: AppSettings.hostedBackendURL,
                        token: ingestToken,
                        label: label
                    )
                } catch APIClientError.authRejected {
                    response = try await client.provisionHostedWorkspace(
                        baseURL: AppSettings.hostedBackendURL,
                        label: label
                    )
                }
            }

            try await applyHostedWorkspace(response)
            restartPeriodicSync()
        }
    }

    func refreshHostedAgentToken() async {
        await runBusy { [self] in
            let ingestToken = (try keychain.readHostedIngestToken() ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ingestToken.isEmpty else { throw APIClientError.missingToken }

            let response = try await APIClient(maxAttempts: 1).refreshHostedAgentToken(
                baseURL: AppSettings.hostedBackendURL,
                token: ingestToken
            )
            settings.storageMode = .hostedHealthSync
            settings.hostedWorkspaceID = response.workspaceID
            settings.hostedAgentEndpoint = response.agentEndpoint
            try keychain.saveHostedAgentToken(response.agentToken)
            hostedAgentToken = response.agentToken
            hasStoredToken = true
            try await saveSettingsOnly()
        }
    }

    private func applyHostedWorkspace(_ response: HostedWorkspaceProvisioningResponse) async throws {
        settings.storageMode = .hostedHealthSync
        settings.backendURL = response.backendURL
        settings.hostedWorkspaceID = response.workspaceID
        settings.hostedAgentEndpoint = response.agentEndpoint
        try keychain.saveHostedIngestToken(response.ingestToken)
        try keychain.saveHostedAgentToken(response.agentToken)
        hostedAgentToken = response.agentToken
        hasStoredToken = true
        try await saveSettingsOnly()
    }

    private func prepareHostedStorageIfNeeded() async throws {
        guard settings.storageMode == .hostedHealthSync else { return }

        let existingAgentEndpoint = settings.hostedAgentEndpoint?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let existingAgentToken = hostedAgentToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingIngestToken = (try keychain.readHostedIngestToken() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch UploadDestinationPreparation.resolve(
            storageMode: settings.storageMode,
            hasAgentEndpoint: !existingAgentEndpoint.isEmpty,
            hasAgentToken: !existingAgentToken.isEmpty,
            hasIngestToken: !existingIngestToken.isEmpty
        ) {
        case .ready:
            if settings.storageMode == .hostedHealthSync {
                hasStoredToken = true
                try await saveSettingsOnly()
            }
        case .provisionHostedStorage:
            let response = try await APIClient(maxAttempts: 1).provisionHostedWorkspace(
                baseURL: AppSettings.hostedBackendURL,
                label: "Personal Health"
            )
            try await applyHostedWorkspace(response)
        }
    }

    func testConnection() async {
        await runBusy { [self] in
            guard let store else { throw APIClientError.invalidResponse }
            let configuration = try await uploadConfiguration()
            let now = Date()
            let payload = SyncPayload.empty(
                deviceID: try await store.deviceID(),
                dateRange: SyncDateRange(start: now, end: now),
                timezone: TimeZone.current.identifier
            )
            let result = try await APIClient(maxAttempts: 1).upload(batch: SyncBatch(payload: payload), configuration: configuration)
            try await store.appendLog(
                SyncLogEntry(level: .success, message: "Connection accepted (\(result.received) received, \(result.duplicates) duplicates).")
            )
            await refresh()
        }
    }

    func syncLast24Hours() async {
        let end = Date()
        let start = end.addingTimeInterval(-24 * 60 * 60)
        await runBusy(stoppable: true) { [self] in
            try await prepareHostedStorageIfNeeded()
            let uploaded = try await syncDateRangeThrowing(start: start, end: end)
            actionFeedback = uploaded ? .syncCompleted : .noSamples
        }
    }

    func backfill(start: Date, end: Date, mode: BackfillDataMode = .dailySummary) async {
        guard end > start else { return }
        backfillProgress = 0
        backfillError = nil
        await runBusy(stoppable: true) { [self] in
            try await prepareHostedStorageIfNeeded()
            let chunks = BackfillSync.chunks(start: start, end: end)
            let total = Double(chunks.count)
            var uploadedAny = false
            for (index, chunk) in chunks.enumerated() {
                do {
                    guard let store else { throw APIClientError.invalidResponse }
                    try await ensureHealthPermissionsRequested()
                    let configuration = try await uploadConfiguration()
                    let deviceID = try await store.deviceID()
                    try await healthKit.forEachBackfillBatch(
                        types: settings.selectedTypes, start: chunk.start, end: chunk.end, mode: mode
                    ) { fetchResult in
                        let uploaded = try await self.uploadFetchResult(
                            fetchResult, deviceID: deviceID, start: chunk.start, end: chunk.end,
                            configuration: configuration
                        )
                        uploadedAny = uploadedAny || uploaded
                    }
                } catch {
                    if !Task.isCancelled {
                        backfillError = userMessage(from: error)
                    }
                    throw error
                }
                backfillProgress = min(1, Double(index + 1) / total)
            }
            if !uploadedAny {
                try await store?.appendLog(SyncLogEntry(level: .info, message: HealthSyncUserMessages.noSamplesFoundForDateRange))
            }
            backfillProgress = 1
            await refresh()
        }
    }

    @discardableResult
    func syncIncremental() async -> Bool {
        guard BusyOperation.canStart(isBusy: isBusy) else {
            pendingIncrementalSync = true
            return await withCheckedContinuation { continuation in
                pendingIncrementalWaiters.append(continuation)
            }
        }

        var succeeded = false
        await runBusy(stoppable: true) { [self] in
            try await syncIncrementalThrowing()
            succeeded = true
        }
        return succeeded
    }

    /// Cancels the current busy operation (sync, backfill, or any other `runBusy` work) and
    /// returns once it has ended and `isBusy` is false. Batches already queued stay in the
    /// pending queue, and syncs requested while it ran are dropped. Call it before starting
    /// new busy work, not from inside a `runBusy` operation, which would wait on itself.
    func stopSync() async {
        guard let busyOperation else { return }
        isStoppingSync = true
        busyOperation.cancel()
        await busyOperation.value
    }

    /// Discards queued batches that have not been uploaded, for example after
    /// changing destination or narrowing the selected data types.
    func clearPendingQueue() async {
        await runBusy { [self] in
            guard let store else { throw APIClientError.invalidResponse }
            let cleared = try await store.clearPendingBatches()
            let message = "Cleared pending queue: discarded \(PendingQueueLabel.records(cleared.records)) in \(PendingQueueLabel.batches(cleared.batches))."
            try await store.appendLog(SyncLogEntry(level: .info, message: message))
            actionFeedback = HealthActionFeedback(kind: .info, message: message)
        }
    }

    /// Manual only pauses automatic sync at once; other cadences apply with "Apply frequency".
    func setSyncFrequency(_ frequency: SyncFrequency) async {
        settings.syncFrequency = frequency
        guard frequency == .manualOnly else { return }
        periodicSyncTask?.cancel()
        periodicSyncTask = nil
        backgroundSyncScheduler.cancel()
        await healthKit.stopObserverQueries(disabling: Set(HealthDataType.allCases))
        guard let store else { return }
        do {
            // Persist only the cadence so unsaved edits to other settings stay drafts.
            var saved = try await store.loadSettings()
            saved.syncFrequency = .manualOnly
            try await store.saveSettings(saved)
        } catch {
            lastError = userMessage(from: error)
        }
    }

    func performBackgroundSync() async {
        await bootstrap()
        restartPeriodicSync()
        guard canRunAutomaticSync else { return }
        _ = await syncIncremental()
    }

    func sceneDidBecomeActive() async {
        await bootstrap()
        restartPeriodicSync()
        guard canRunAutomaticSync else { return }
        _ = await syncIncremental()
    }

    func sceneDidEnterBackground() {
        restartPeriodicSync()
    }

    private func syncIncrementalThrowing() async throws {
        guard let incrementalSyncRunner else { throw APIClientError.invalidResponse }
        try Task.checkCancellation()
        try await ensureHealthPermissionsRequested()
        let configuration = try await uploadConfiguration()
        try await incrementalSyncRunner.run(types: settings.selectedTypes, configuration: configuration)
        await refresh()
    }

    private func syncDateRangeThrowing(
        start: Date,
        end: Date
    ) async throws -> Bool {
        guard let store else { throw APIClientError.invalidResponse }
        try await ensureHealthPermissionsRequested()
        let configuration = try await uploadConfiguration()
        let fetchResult = try await healthKit.fetchSamples(types: settings.selectedTypes, start: start, end: end)
        let uploaded = try await uploadFetchResult(
            fetchResult, deviceID: try await store.deviceID(), start: start, end: end,
            configuration: configuration
        )
        if !uploaded {
            try await store.appendLog(SyncLogEntry(level: .info, message: HealthSyncUserMessages.noSamplesFoundForDateRange))
        }
        await refresh()
        return uploaded
    }

    // Shared by recent exports and streaming history; each page is queued and
    // acknowledged before the next HealthKit page is requested.
    private func uploadFetchResult(
        _ fetchResult: HealthKitFetchResult, deviceID: String, start: Date, end: Date,
        configuration: UploadConfiguration
    ) async throws -> Bool {
        guard let syncEngine else { throw APIClientError.invalidResponse }
        let payload = try normalizer.payload(
            deviceID: deviceID,
            dateRange: SyncDateRange(start: start, end: end),
            timezone: TimeZone.current.identifier,
            quantitySamples: fetchResult.quantitySamples,
            sleepSamples: fetchResult.sleepSamples,
            categorySamples: fetchResult.categorySamples,
            workoutSamples: fetchResult.workoutSamples
        )
        guard BackfillSync.shouldUpload(payload) else { return false }
        for uploadPayload in BackfillSync.uploadPayloads(for: payload) {
            try Task.checkCancellation()
            let batch = try await syncEngine.queue(payload: uploadPayload)
            let result = await syncEngine.uploadQueuedBatch(batch, configuration: configuration)
            try BackfillSync.validateUpload(result)
        }
        return true
    }

    private func saveSettingsOnly() async throws {
        guard let store else { throw APIClientError.invalidResponse }
        settings.migrateHostedEndpoints()
        try await store.saveSettings(settings)
    }

    private func ensureHealthPermissionsRequested() async throws {
        guard !settings.hasRequestedHealthPermissions else { return }
        try await healthKit.requestReadPermissions(for: settings.selectedTypes)
        settings.hasRequestedHealthPermissions = true
        shouldShowOnboarding = false
        permissionSummary = "Requested"
        try await saveSettingsOnly()
        await startObserversIfPossible()
        restartPeriodicSync()
    }

    private func uploadConfiguration() async throws -> UploadConfiguration {
        guard let store else { throw APIClientError.invalidResponse }
        let baseURL = settings.effectiveBackendURL
        _ = try APIClient.validatedRootURL(from: baseURL)
        guard let token = try readUploadToken(), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIClientError.missingToken
        }
        return UploadConfiguration(
            baseURL: baseURL,
            token: token,
            deviceID: try await store.deviceID(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        )
    }

    private func readUploadToken() throws -> String? {
        switch settings.storageMode {
        case .customBackend:
            try keychain.readToken()
        case .hostedHealthSync:
            try keychain.readHostedIngestToken()
        }
    }

    private func hasTokenForCurrentStorageMode() throws -> Bool {
        let token = try readUploadToken()
        return !(token ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startObserversIfPossible() async {
        guard settings.hasRequestedHealthPermissions else {
            await healthKit.stopObserverQueries()
            return
        }
        guard settings.syncFrequency != .manualOnly, hasUsableUploadConfiguration() else {
            await healthKit.stopObserverQueries(disabling: Set(HealthDataType.allCases))
            return
        }
        do {
            try await healthKit.startObserverQueries(
                types: settings.selectedTypes,
                frequency: settings.syncFrequency
            ) { [weak self] _ in
                await self?.syncIncremental()
            }
        } catch {
            lastError = userMessage(from: error)
        }
    }

    private func restartPeriodicSync() {
        periodicSyncTask?.cancel()
        backgroundSyncScheduler.cancel()
        guard settings.hasRequestedHealthPermissions, hasUsableUploadConfiguration() else { return }
        guard let interval = settings.syncFrequency.intervalSeconds else { return }
        do {
            try backgroundSyncScheduler.reschedule(for: settings.syncFrequency)
        } catch {
            let message = "iOS could not schedule the next background sync: \(error.localizedDescription)"
            Task { [weak self] in
                try? await self?.store?.appendLog(SyncLogEntry(level: .error, message: message))
            }
        }
        periodicSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.syncIncremental()
            }
        }
    }

    private func hasUsableUploadConfiguration() -> Bool {
        guard (try? APIClient.validatedRootURL(from: settings.effectiveBackendURL)) != nil else {
            return false
        }
        return (try? hasTokenForCurrentStorageMode()) == true
    }

    private var canRunAutomaticSync: Bool {
        settings.hasRequestedHealthPermissions
            && settings.syncFrequency != .manualOnly
            && hasUsableUploadConfiguration()
    }

    /// Runs `operation` as the busy operation in a stored task so `stopSync()` can cancel it.
    /// Cancelling the calling task, such as the periodic sync loop, cancels it too.
    /// `stoppable` marks a sync or backfill, which shows Stop sync and logs "Sync stopped.".
    private func runBusy(stoppable: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) async {
        guard BusyOperation.canStart(isBusy: isBusy) else { return }
        isBusy = true
        canStopSync = stoppable
        lastError = nil
        actionFeedback = nil
        let task = Task { @MainActor in
            await self.performBusyOperation(stoppable: stoppable, operation)
        }
        busyOperation = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performBusyOperation(stoppable: Bool, _ operation: () async throws -> Void) async {
        var cancelled = false
        defer {
            // A stop requested after the work stopped checking for cancellation still counts.
            let stopped = cancelled || isStoppingSync
            isBusy = false
            busyOperation = nil
            canStopSync = false
            isStoppingSync = false
            if pendingIncrementalSync {
                // Each waiter is taken off the list here and resumed exactly once below.
                pendingIncrementalSync = false
                let waiters = pendingIncrementalWaiters
                pendingIncrementalWaiters.removeAll()
                if stopped {
                    // A stop also drops syncs that observers requested while this one ran.
                    waiters.forEach { $0.resume(returning: false) }
                } else {
                    Task { @MainActor [weak self] in
                        let succeeded = await self?.syncIncremental() ?? false
                        waiters.forEach { $0.resume(returning: succeeded) }
                    }
                }
            }
        }
        do {
            try await operation()
            await refresh()
        } catch {
            if Task.isCancelled || error is CancellationError {
                cancelled = true
                if stoppable {
                    actionFeedback = HealthActionFeedback(kind: .info, message: "Sync stopped. Unsent records stay in the pending queue. To pause automatic sync, set Background Sync to Manual only in Settings.")
                    try? await store?.appendLog(SyncLogEntry(level: .info, message: "Sync stopped."))
                }
                await refresh()
                return
            }
            let message = userMessage(from: error)
            lastError = message
            actionFeedback = .failure(message)
            if let store {
                try? await store.appendLog(SyncLogEntry(level: .error, message: message))
                await refresh()
            }
        }
    }

    private func userMessage(from error: Error) -> String {
        if let apiError = error as? APIClientError {
            return apiError.userMessage
        }
        return error.localizedDescription
    }
}
