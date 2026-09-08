import os
import re

filepath = "/Users/mohammadshayani/Vibe/ios/ChatModule/AgentBridgeProfileView.swift"
with open(filepath, 'r') as f:
    content = f.read()

# We need to replace the `body`, `connectionCard`, and `transportCard` of AgentBridgeConnectionSheet.

new_body = """  var body: some View {
    NavigationStack {
      List {
        Section {
          if model.status.connected, let device = model.status.devices.first {
            statusRow(
              icon: "laptopcomputer",
              title: device.label,
              subtitle: "Connected",
              subtitleColor: .green,
              showsDot: true
            )
          } else if model.status.paired {
            statusRow(
              icon: "laptopcomputer.slash",
              title: model.status.devices.first?.label ?? "Your computer",
              subtitle: "Paired — bridge offline",
              subtitleColor: palette.secondaryText
            )
          } else {
            statusRow(
              icon: "laptopcomputer.slash",
              title: "No computer connected",
              subtitle: "Pair one to start",
              subtitleColor: palette.secondaryText
            )
          }
        } header: {
          Text("Computer")
        } footer: {
          Text("\\(model.displayName) runs on your own computer with your own subscription. Pair once, then keep using the same Mac from your phone.")
        }
        .listRowBackground(palette.card)

        Section {
          Picker("Connection", selection: $transportPreference) {
            Text("Auto").tag(AgentBridgeTransportPreference.auto)
            Text("Local").tag(AgentBridgeTransportPreference.local)
            Text("Cloud").tag(AgentBridgeTransportPreference.cloud)
          }
          .pickerStyle(.segmented)
          .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
          .onChange(of: transportPreference) { newValue in
            AgentBridgeTransport.preference = newValue
            LanBridgeService.shared.applyPreference(newValue)
          }

          HStack(spacing: 9) {
            lanStatusIndicator
            Text(lanStatusText)
              .font(.system(size: 13.5, weight: .medium))
              .foregroundStyle(palette.text)
              .lineLimit(1)
            Spacer(minLength: 0)
          }
          .padding(.vertical, 2)
        } header: {
          Text("Connection")
        }
        .listRowBackground(palette.card)

        Section {
          infoRow(
            icon: "lock.shield",
            title: "Private by default",
            body: "Pairing is revocable and only your account can authorize a computer."
          )
          infoRow(
            icon: "qrcode.viewfinder",
            title: "Scan the bridge QR",
            body: "On your Mac, run the bridge command. It prints a QR code; scanning it here opens the camera view."
          )
          infoRow(
            icon: "arrow.triangle.2.circlepath",
            title: model.status.paired || model.status.connected ? "Reconnect anytime" : "Connect once",
            body: model.status.paired || model.status.connected
              ? "Reconnect scans a fresh QR without changing your chat history or selected repository."
              : "After pairing, the app waits for the bridge daemon to come online."
          )
        } header: {
          Text("Information")
        }
        .listRowBackground(palette.card)

        if let errorMessage {
          Section {
            Text(errorMessage)
              .font(.system(size: 13))
              .foregroundStyle(palette.danger)
              .fixedSize(horizontal: false, vertical: true)
          }
          .listRowBackground(palette.card)
        }

        Section {
          Button {
            model.beginScan()
          } label: {
            HStack(spacing: 10) {
              if model.isAuthorizing || isWorking {
                ProgressView()
                  .tint(palette.accent)
              } else {
                Image(systemName: "qrcode.viewfinder")
                  .font(.system(size: 17, weight: .semibold))
              }
              Text(model.status.paired || model.status.connected ? "Scan QR to reconnect" : "Scan QR to connect")
                .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .center)
          }
          .disabled(isWorking || model.isAuthorizing)
          .foregroundColor(palette.accent)

          if model.status.paired || model.status.connected {
            Button(role: .destructive) {
              disconnect()
            } label: {
              HStack(spacing: 10) {
                Image(systemName: "xmark.circle")
                  .font(.system(size: 17, weight: .semibold))
                Text("Disconnect current computer")
                  .font(.system(size: 16, weight: .semibold))
              }
              .frame(maxWidth: .infinity, alignment: .center)
            }
            .disabled(isWorking)
            .foregroundColor(palette.danger)
          }
        }
        .listRowBackground(palette.card)
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(palette.background.ignoresSafeArea())
      .navigationTitle("\\(model.displayName) computer")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }"""

start_idx = content.find("  var body: some View {")
end_idx = content.find("  /// A quiet spinner")

body_end_idx = content.find("    .onAppear {", start_idx)

if start_idx != -1 and end_idx != -1 and body_end_idx != -1:
    old_body_and_cards = content[start_idx:end_idx]
    
    cards_start_idx = content.find("  @ViewBuilder\n  private var connectionCard: some View {", body_end_idx)
    
    navigation_modifiers = content[body_end_idx:cards_start_idx]
    
    new_content = content[:start_idx] + new_body + "\n" + navigation_modifiers + content[end_idx:]
    
    with open(filepath, 'w') as f:
        f.write(new_content)
    print("Success")
else:
    print("Failed to find indices")
