import Foundation

enum BackfillDataMode: String, CaseIterable, Identifiable {
    case dailySummary
    case rawSamples

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dailySummary: "Daily summaries"
        case .rawSamples: "Original blood oxygen & HRV"
        }
    }
}

enum SyncFrequency: String, CaseIterable, Codable, Identifiable {
    case manualOnly
    case hourlyBestEffort
    case dailyBestEffort

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manualOnly: "Manual only"
        case .hourlyBestEffort: "Hourly best-effort"
        case .dailyBestEffort: "Daily best-effort"
        }
    }

    var intervalSeconds: UInt64? {
        switch self {
        case .manualOnly: nil
        case .hourlyBestEffort: 60 * 60
        case .dailyBestEffort: 24 * 60 * 60
        }
    }
}

enum BackgroundSyncSchedule {
    static func earliestBeginDate(for frequency: SyncFrequency, now: Date = Date()) -> Date? {
        guard let interval = frequency.intervalSeconds else { return nil }
        return now.addingTimeInterval(TimeInterval(interval))
    }
}

enum StorageMode: String, CaseIterable, Codable, Identifiable {
    case customBackend
    case hostedHealthSync

    var id: String { rawValue }

    var label: String {
        switch self {
        case .customBackend: "My own backend"
        case .hostedHealthSync: "Hosted HealthSync storage"
        }
    }

    var showsManualBackendSettings: Bool {
        switch self {
        case .customBackend: true
        case .hostedHealthSync: false
        }
    }
}

/// Quick Health data selections offered in onboarding and Settings.
/// Fresh installs start with `core`; saved selections are never replaced by a preset.
enum HealthDataPreset: String, CaseIterable, Identifiable {
    /// Everyday metrics: steps, walking/running distance, workouts, sleep, weight, heart rate, active energy.
    case core
    /// Core plus every Activity type, heart fitness metrics, and body composition.
    case fitness
    /// Every supported Health data type.
    case everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .core: "Core"
        case .fitness: "Fitness"
        case .everything: "Everything"
        }
    }

    var summary: String {
        switch self {
        case .core: "Steps, distance, workouts, sleep, weight, heart rate, active energy"
        case .fitness: "Core plus training, heart fitness, and body composition"
        case .everything: "All supported Apple Health data"
        }
    }

    var types: Set<HealthDataType> {
        switch self {
        case .core:
            [.stepCount, .distanceWalkingRunning, .workouts, .sleepAnalysis, .bodyMass, .heartRate, .activeEnergy]
        case .fitness:
            Self.core.types
                .union(HealthMetricCategory.activity.types)
                .union([
                    .restingHeartRate, .hrvSDNN, .vo2Max, .walkingHeartRateAverage,
                    .heartRateRecoveryOneMinute, .bodyFatPercentage, .leanBodyMass
                ])
        case .everything:
            Set(HealthDataType.allCases)
        }
    }

    static func matching(_ selectedTypes: Set<HealthDataType>) -> HealthDataPreset? {
        allCases.first { $0.types == selectedTypes }
    }
}

struct AppSettings: Codable, Equatable {
    static let hostedBackendURL = "https://api.healthysync.app"

    var backendURL: String
    var selectedTypes: Set<HealthDataType>
    var syncFrequency: SyncFrequency
    var hasRequestedHealthPermissions: Bool
    /// Where health data uploads go. `nil` until the user explicitly picks a destination.
    var storageMode: StorageMode?
    var hostedWorkspaceID: String?
    var hostedAgentEndpoint: String?
    var customTokenID: UUID?
    var hostedIngestTokenID: UUID?

    private enum CodingKeys: String, CodingKey {
        case backendURL
        case selectedTypes
        case syncFrequency
        case hasRequestedHealthPermissions
        case storageMode
        case hostedWorkspaceID
        case hostedAgentEndpoint
        case customTokenID
        case hostedIngestTokenID
    }

    static let `default` = AppSettings(
        backendURL: "",
        selectedTypes: HealthDataPreset.core.types,
        syncFrequency: .hourlyBestEffort,
        hasRequestedHealthPermissions: false,
        storageMode: nil,
        hostedWorkspaceID: nil,
        hostedAgentEndpoint: nil
    )

    var effectiveBackendURL: String {
        switch storageMode {
        case .customBackend:
            Self.migratedHostedURL(backendURL, agent: false) ?? backendURL
        case .hostedHealthSync:
            Self.hostedBackendURL
        case nil:
            ""
        }
    }

    /// The destination new batches are queued for, or `nil` while no destination is chosen.
    var uploadDestination: String? {
        guard storageMode != nil else { return nil }
        return UploadConfiguration.destinationKey(for: effectiveBackendURL)
    }

    @discardableResult
    mutating func migrateHostedEndpoints() -> Bool {
        var changed = false
        if let migrated = Self.migratedHostedURL(backendURL, agent: false) {
            backendURL = migrated
            changed = true
        }
        if let endpoint = hostedAgentEndpoint,
           let migrated = Self.migratedHostedURL(endpoint, agent: true) {
            hostedAgentEndpoint = migrated
            changed = true
        }
        return changed
    }

    private static func migratedHostedURL(_ value: String, agent: Bool) -> String? {
        guard let source = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              source.scheme?.lowercased() == "https",
              source.host?.lowercased() == "dtzydnjnqkruxaacgkio.supabase.co",
              source.port == nil || source.port == 443,
              source.user == nil, source.password == nil,
              var target = URLComponents(string: hostedBackendURL) else { return nil }

        let prefix = "/functions/v1/healthsync"
        let path = source.percentEncodedPath.hasSuffix("/")
            ? String(source.percentEncodedPath.dropLast()) : source.percentEncodedPath
        let targetPath: String
        if agent {
            let paths = ["health-data", "metrics", "workouts", "syncs"].map { "/api/agent/" + $0 }
            guard let suffix = paths.first(where: { path == prefix + $0 }) else { return nil }
            targetPath = suffix
        } else {
            guard path == prefix else { return nil }
            targetPath = ""
        }
        target.percentEncodedPath = targetPath
        target.percentEncodedQuery = source.percentEncodedQuery
        target.percentEncodedFragment = source.percentEncodedFragment
        return target.string
    }

    init(
        backendURL: String,
        selectedTypes: Set<HealthDataType>,
        syncFrequency: SyncFrequency,
        hasRequestedHealthPermissions: Bool,
        storageMode: StorageMode?,
        hostedWorkspaceID: String?,
        hostedAgentEndpoint: String?
    ) {
        self.backendURL = backendURL
        self.selectedTypes = selectedTypes
        self.syncFrequency = syncFrequency
        self.hasRequestedHealthPermissions = hasRequestedHealthPermissions
        self.storageMode = storageMode
        self.hostedWorkspaceID = hostedWorkspaceID
        self.hostedAgentEndpoint = hostedAgentEndpoint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backendURL = try container.decode(String.self, forKey: .backendURL)
        selectedTypes = try container.decode(Set<HealthDataType>.self, forKey: .selectedTypes)
        syncFrequency = try container.decode(SyncFrequency.self, forKey: .syncFrequency)
        hasRequestedHealthPermissions = try container.decode(Bool.self, forKey: .hasRequestedHealthPermissions)
        // Settings saved before hosted storage existed have no storageMode key and always used a custom backend.
        // Newer settings always write the key, as null until the user chooses a destination.
        storageMode = container.contains(.storageMode)
            ? try container.decodeIfPresent(StorageMode.self, forKey: .storageMode)
            : .customBackend
        hostedWorkspaceID = try container.decodeIfPresent(String.self, forKey: .hostedWorkspaceID)
        hostedAgentEndpoint = try container.decodeIfPresent(String.self, forKey: .hostedAgentEndpoint)
        customTokenID = try container.decodeIfPresent(UUID.self, forKey: .customTokenID)
        hostedIngestTokenID = try container.decodeIfPresent(UUID.self, forKey: .hostedIngestTokenID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(backendURL, forKey: .backendURL)
        try container.encode(selectedTypes, forKey: .selectedTypes)
        try container.encode(syncFrequency, forKey: .syncFrequency)
        try container.encode(hasRequestedHealthPermissions, forKey: .hasRequestedHealthPermissions)
        try container.encode(storageMode, forKey: .storageMode)
        try container.encodeIfPresent(hostedWorkspaceID, forKey: .hostedWorkspaceID)
        try container.encodeIfPresent(hostedAgentEndpoint, forKey: .hostedAgentEndpoint)
        try container.encodeIfPresent(customTokenID, forKey: .customTokenID)
        try container.encodeIfPresent(hostedIngestTokenID, forKey: .hostedIngestTokenID)
    }
}

struct SyncStatus: Equatable {
    var lastSuccessfulSyncAt: Date?
    var lastAttemptedSyncAt: Date?
    /// Number of queued upload batches (each holds up to 100 records).
    var pendingUploadCount: Int
    var pendingRecordCount: Int = 0
    var lastError: String?

    static let empty = SyncStatus(
        lastSuccessfulSyncAt: nil,
        lastAttemptedSyncAt: nil,
        pendingUploadCount: 0,
        lastError: nil
    )
}
