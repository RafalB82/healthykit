import SwiftUI

struct BackfillView: View {
    @EnvironmentObject private var appState: AppState
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var dataMode: BackfillDataMode = .dailySummary

    private var isBackfilling: Bool { appState.foregroundSync == .historical }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Info Card
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(HealthSyncTheme.primaryBlue)
                        Text("Historical Sync")
                            .font(.headline)
                    }
                    
                    Text("Choose a date range to read selected metrics and workouts from Apple Health, then upload them to your configured storage destination.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
                .healthCardStyle(padding: 16)
                .padding(.top, 16)
                
                // Date Selectors Card
                VStack(spacing: 16) {
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundStyle(HealthSyncTheme.primaryPink)
                        Text("Select Date Range")
                            .font(.headline)
                        Spacer()
                    }
                    
                    Divider()
                    
                    Picker("Data detail", selection: $dataMode) {
                        ForEach(BackfillDataMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .disabled(appState.isBusy)

                    Text(dataMode == .rawSamples
                         ? "Uploads individual blood oxygen and HRV samples with original timestamps and sources. Other quantity metrics keep daily summaries to avoid overlapping-device totals. Blood oxygen readings are discrete, not continuous monitoring."
                         : "Uploads daily sums or averages for quantity metrics. Sleep stages, category samples, and workouts keep their existing detail.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        DatePicker("Start Date", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                            .font(.subheadline.weight(.medium))
                        
                        DatePicker("End Date", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                            .font(.subheadline.weight(.medium))
                    }
                    .disabled(isBackfilling)
                }
                .healthCardStyle(padding: 16)
                
                // Sync actions
                VStack(spacing: 16) {
                    let isInvalidRange = endDate <= startDate
                    
                    if appState.actionFeedback == .syncStopped && !appState.isBusy {
                        HealthActionFeedbackBanner(feedback: .syncStopped)
                    } else if let backfillError = appState.backfillError, !appState.isBusy {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(HealthSyncTheme.primaryRed.opacity(0.1))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(HealthSyncTheme.primaryRed)
                                    .font(.title3)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Historical Sync Failed")
                                    .font(.subheadline.weight(.bold))
                                Text(backfillError)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(HealthSyncTheme.primaryRed.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(HealthSyncTheme.primaryRed.opacity(0.2), lineWidth: 1)
                        )
                    } else if appState.backfillProgress == 1.0 && !appState.isBusy {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(HealthSyncTheme.successGreen.opacity(0.1))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(HealthSyncTheme.successGreen)
                                    .font(.title3)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Historical Sync Complete")
                                    .font(.subheadline.weight(.bold))
                                Text("Selected Apple Health data was uploaded.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(HealthSyncTheme.successGreen.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(HealthSyncTheme.successGreen.opacity(0.2), lineWidth: 1)
                        )
                    }
                    
                    if !isBackfilling {
                        Text("Keep HealthSync open while it syncs. Your screen will stay on until the sync finishes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            Task { await appState.backfill(start: startDate, end: endDate, mode: dataMode) }
                        } label: {
                            Label("Keep Screen On & Sync", systemImage: "tray.and.arrow.up.fill")
                        }
                        .buttonStyle(HealthSyncTheme.PrimaryButtonStyle(
                            isBusy: appState.isBusy,
                            gradient: isInvalidRange || appState.isBusy ? HealthSyncTheme.disabledGradient : HealthSyncTheme.heartGradient
                        ))
                        .disabled(isInvalidRange || appState.isBusy)
                    }

                    if appState.canStopSync && appState.foregroundSync == nil {
                        StopSyncButton()
                    }

                    if isInvalidRange {
                        Text("End date must be strictly after start date")
                            .font(.caption)
                            .foregroundStyle(HealthSyncTheme.primaryRed)
                    }
                }
                .healthCardStyle(padding: isBackfilling ? 0 : 16)
                
                Spacer()
            }
            .padding(16)
        }
        .background(HealthSyncTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Historical Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}
