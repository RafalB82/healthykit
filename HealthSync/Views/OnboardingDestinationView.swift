import SwiftUI

enum OnboardingDestinationCopy {
    static let intro = "HealthSync uploads nothing until you confirm a destination. You can change it later in Settings, and data queued for one destination is never sent to another."
    static let ownBackend = "Uploads go only to the server you enter. HealthSync never copies them anywhere else."
    static let hosted = "Selected Apple Health data will be uploaded to HealthSync’s hosted storage (api.healthysync.app). HealthSync stores it in a private workspace on Cloudflare’s infrastructure in the United States."
}

struct OnboardingDestinationView: View {
    @EnvironmentObject private var appState: AppState
    @State private var choice: StorageMode?
    @State private var backendURL: String
    @State private var tokenDraft = ""
    @State private var testedBackendURL: String?
    @State private var confirmedHosted = false

    init(initialSettings: AppSettings) {
        _choice = State(initialValue: initialSettings.storageMode)
        _backendURL = State(initialValue: initialSettings.backendURL)
    }

    private var isBusy: Bool { appState.isBusy || appState.isSavingSettings }

    private var isConfirmed: Bool {
        guard let choice, appState.settings.storageMode == choice, appState.hasChosenStorageDestination else {
            return false
        }
        switch choice {
        case .customBackend:
            return testedBackendURL == backendURL && tokenDraft.isEmpty
        case .hostedHealthSync:
            return confirmedHosted
        }
    }

    var body: some View {
        ZStack {
            HealthSyncTheme.backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Where should your health data go?")
                            .font(.title2.weight(.bold))
                        Text(OnboardingDestinationCopy.intro)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 4)

                    DestinationOptionCard(
                        title: StorageMode.customBackend.label,
                        detail: OnboardingDestinationCopy.ownBackend,
                        icon: "server.rack",
                        color: HealthSyncTheme.primaryBlue,
                        isSelected: choice == .customBackend
                    ) { choice = .customBackend }
                    .disabled(isBusy)
                    .accessibilityIdentifier("onboarding-destination-own-backend")

                    if choice == .customBackend {
                        ownBackendForm
                    }

                    DestinationOptionCard(
                        title: StorageMode.hostedHealthSync.label,
                        detail: "Stored by HealthSync on api.healthysync.app.",
                        icon: "icloud.and.arrow.up",
                        color: .purple,
                        isSelected: choice == .hostedHealthSync
                    ) { choice = .hostedHealthSync }
                    .disabled(isBusy)
                    .accessibilityIdentifier("onboarding-destination-hosted")

                    if choice == .hostedHealthSync {
                        hostedExplanation
                    }
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom) {
            NavigationLink(value: OnboardingStep.healthData) {
                Text(isConfirmed ? "Continue" : "Confirm a destination to continue")
            }
            .buttonStyle(HealthSyncTheme.PrimaryButtonStyle(
                isBusy: isBusy,
                gradient: isConfirmed ? HealthSyncTheme.heartGradient : HealthSyncTheme.disabledGradient
            ))
            .disabled(!isConfirmed || isBusy)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .accessibilityIdentifier("onboarding-destination-continue")
        }
        .onChange(of: choice) { _, _ in appState.lastError = nil }
        .navigationTitle("Storage Destination")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isBusy)
    }

    private var ownBackendForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backend URL")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("https://api.example.com", text: $backendURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .disabled(isBusy)

            Text("Auth token")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            SecureField("Bearer token for your backend", text: $tokenDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .disabled(isBusy)

            Button {
                Task {
                    testedBackendURL = nil
                    if await appState.useOwnBackend(backendURL: backendURL, tokenDraft: tokenDraft) {
                        testedBackendURL = backendURL
                        tokenDraft = ""
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if isBusy {
                        ProgressView().tint(.white)
                    }
                    Text(isBusy ? "Testing…" : "Save and Test")
                }
            }
            .buttonStyle(HealthSyncTheme.PrimaryButtonStyle(isBusy: isBusy, gradient: HealthSyncTheme.stepsGradient))
            .disabled(isBusy)
            .accessibilityIdentifier("onboarding-own-backend-save-test")

            if isConfirmed, let destination = appState.settings.uploadDestination {
                confirmation("\(UploadConfiguration.host(of: destination)) accepted the test upload. Uploads will go only there.")
            } else {
                errorMessage
            }
        }
        .healthCardStyle(padding: 16)
    }

    private var hostedExplanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("What hosted storage means", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            Text(OnboardingDestinationCopy.hosted)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isConfirmed {
                confirmation("Hosted storage is ready. Uploads will go to \(UploadConfiguration.host(of: AppSettings.hostedBackendURL)).")
            } else {
                Button {
                    Task {
                        if appState.hasHostedIngestToken {
                            confirmedHosted = await appState.useHostedStorage()
                        } else {
                            confirmedHosted = await appState.createHostedStorage()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isBusy {
                            ProgressView().tint(.white)
                        }
                        Text(isBusy ? "Saving…" : appState.hasHostedIngestToken ? "Use Hosted Storage" : "Create Hosted Storage")
                    }
                }
                .buttonStyle(HealthSyncTheme.PrimaryButtonStyle(isBusy: isBusy, gradient: HealthSyncTheme.stepsGradient))
                .disabled(isBusy)
                .accessibilityIdentifier("onboarding-create-hosted-storage")
                errorMessage
            }
        }
        .healthCardStyle(padding: 16)
    }

    @ViewBuilder
    private var errorMessage: some View {
        if !isBusy, let error = appState.lastError {
            Label(error, systemImage: "exclamationmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(HealthSyncTheme.primaryRed)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confirmation(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(HealthSyncTheme.successGreen)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DestinationOptionCard: View {
    let title: String
    let detail: String
    let icon: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.12)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? color : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .healthCardStyle(padding: 12)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? color : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
