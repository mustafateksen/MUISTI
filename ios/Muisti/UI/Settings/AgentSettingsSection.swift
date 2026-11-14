import SwiftUI

/// What Muisti may bring up by itself, how often, and what it may read to do so.
struct AgentSettingsSection: View {
    let controller: CaptureController
    @State private var calendarDenied = false

    var body: some View {
        @Bindable var settings = controller.agent.settings
        Section {
            NavigationLink(value: SettingsRoute.assistantNotes) {
                Label("Reminders, places and what Muisti said", systemImage: "list.bullet.rectangle")
            }
            Toggle("Bring things up by itself", isOn: $settings.enabled)
            if settings.enabled {
                Toggle("Notice things in what it sees", isOn: $settings.noticing)
                Toggle("Directions and parking", isOn: $settings.navigation)
                Toggle("Evening summary", isOn: $settings.eveningDigest)
                Stepper("Speak up at most \(settings.dailySpokenBudget) times a day", value: $settings.dailySpokenBudget, in: 0...200, step: 5)
                Stepper("At least \(settings.minGapMinutes) min apart", value: $settings.minGapMinutes, in: 0...60)
                Stepper("Quiet from \(settings.quietFromHour):00", value: $settings.quietFromHour, in: 0...23)
                Stepper("Quiet until \(settings.quietToHour):00", value: $settings.quietToHour, in: 0...23)
            }
        } header: {
            Text("Assistant")
        } footer: {
            Text("Reminders you ask for, and things Muisti notices on its own: a closing time, a warning sign, a wrong turn. Safety warnings are always spoken and don't count towards the daily limit. Spoken \(controller.agent.policy.spokenToday()) times today.")
        }

        if settings.enabled {
            Section {
                Toggle("Read my calendar", isOn: $settings.calendar)
                    .onChange(of: settings.calendar) { _, on in
                        guard on else { return }
                        Task {
                            if await controller.agent.calendar.requestRead() {
                                controller.agent.calendar.refresh(force: true)
                            } else {
                                settings.calendar = false
                                calendarDenied = true
                            }
                        }
                    }
                Toggle("Look up places with Apple Maps", isOn: $settings.mapSearch)
                if controller.agent.background.isAlways {
                    Label("Reminds you at places even when Muisti is closed", systemImage: "location.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Also work when Muisti is closed", systemImage: "location") {
                        controller.agent.background.requestAlways()
                    }
                }
                Toggle("Notes about people", isOn: $settings.people)
                if calendarDenied {
                    Text("Calendar access is off for Muisti. Turn it on in the Settings app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("What the assistant may use")
            } footer: {
                Text("Your reminders, what you tell Muisti about yourself and, if turned on, the titles, times and places of your next day's calendar events are sent to the AI model together with your question. Place names are sent to Apple Maps to find them. Notes about people only ever use text read from a badge or card; faces are never recognised.")
            }

            if !controller.agent.policy.mutes.isEmpty {
                Section {
                    ForEach(controller.agent.policy.mutes, id: \.topic) { mute in
                        Label(mute.topic.replacingOccurrences(of: "_", with: " "), systemImage: "speaker.slash")
                    }
                    .onDelete { offsets in
                        let topics = offsets.map { controller.agent.policy.mutes[$0].topic }
                        Task { for topic in topics { await controller.agent.policy.unmute(topic) } }
                    }
                } header: {
                    Text("Muted")
                } footer: {
                    Text("Things you told Muisti not to bring up again. Swipe left to allow one again.")
                }
            }
        }
    }
}
