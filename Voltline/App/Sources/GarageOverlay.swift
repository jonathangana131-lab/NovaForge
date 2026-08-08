import SwiftUI

struct GarageOverlay: View {
    @ObservedObject var session: GameSession
    @State private var tab: GarageTab = .rides

    enum GarageTab: String, CaseIterable, Identifiable {
        case rides = "RIDES"
        case parts = "PARTS"
        case orders = "ORDERS"
        case setup = "SETUP"

        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.64)
                .ignoresSafeArea()
                .onTapGesture { session.toggleGarage() }

            VStack(spacing: 0) {
                header
                Divider().overlay(.white.opacity(0.10))
                HStack(spacing: 0) {
                    sidebar
                    Divider().overlay(.white.opacity(0.10))
                    content
                }
            }
            .frame(maxWidth: 920, maxHeight: 540)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.035, green: 0.05, blue: 0.075), Color.black.opacity(0.96)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 30, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.82), radius: 38, y: 18)
            .padding(24)
            .accessibilityIdentifier("garageOverlay")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.cyan.opacity(0.14))
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.cyan)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text("VOLTLINE GARAGE")
                    .font(.system(size: 19, weight: .black, design: .rounded))
                Text("Every installed part changes the same hardware simulation used while riding.")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(session.bankDisplay)
                    .font(.system(size: 18, weight: .black, design: .rounded))
                Text("BANK BALANCE")
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .foregroundStyle(.cyan)
            }
            Button {
                session.toggleGarage()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .black))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("closeGarageButton")
        }
        .padding(.horizontal, 20)
        .frame(height: 72)
    }

    private var sidebar: some View {
        VStack(spacing: 7) {
            ForEach(GarageTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: symbol(for: item))
                            .frame(width: 22)
                        Text(item.rawValue)
                        Spacer()
                    }
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 13)
                    .frame(height: 43)
                    .background(tab == item ? Color.cyan.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 13))
                    .foregroundStyle(tab == item ? .cyan : .white.opacity(0.66))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("garageTab-\(item.rawValue)")
            }
            Spacer()
            VStack(alignment: .leading, spacing: 5) {
                Label("\(session.controllerName ?? "Touch controls")", systemImage: "gamecontroller.fill")
                Label("\(Int(session.simulationState.batteryStateOfCharge * 100))% battery", systemImage: "battery.75percent")
                Label(String(format: "%.1f mi odometer", session.odometerMiles), systemImage: "gauge.with.dots.needle.50percent")
            }
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.42))
            .padding(12)
        }
        .padding(12)
        .frame(width: 176)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .rides:
            rides
        case .parts:
            parts
        case .orders:
            orders
        case .setup:
            setup
        }
    }

    private var rides: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(ScooterCatalogItem.all) { scooter in
                    ScooterGarageCard(
                        scooter: scooter,
                        selected: session.selectedScooterID == scooter.id,
                        owned: session.ownedScooterIDs.contains(scooter.id),
                        bankBalance: session.bankBalance
                    ) {
                        if session.ownedScooterIDs.contains(scooter.id) {
                            session.selectScooter(scooter.id)
                        } else {
                            session.buyScooter(scooter)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var parts: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 15) {
                sectionTitle("INSTALLED", detail: "Active hardware")
                if session.installedItemIDs.isEmpty {
                    emptyRow("No upgraded parts installed", symbol: "wrench.adjustable")
                } else {
                    ForEach(StoreItem.catalog.filter { session.installedItemIDs.contains($0.id) }) { item in
                        PartGarageRow(item: item, status: "INSTALLED", actionTitle: nil, action: nil)
                    }
                }

                sectionTitle("READY TO INSTALL", detail: "Delivered inventory")
                if session.inventoryItemIDs.isEmpty {
                    emptyRow("Delivered parts appear here", symbol: "shippingbox")
                } else {
                    ForEach(StoreItem.catalog.filter { session.inventoryItemIDs.contains($0.id) }) { item in
                        PartGarageRow(item: item, status: "IN GARAGE", actionTitle: "INSTALL") {
                            session.installItem(item.id)
                        }
                    }
                }

                sectionTitle("COMPATIBLE MARKET", detail: session.selectedScooter.name)
                ForEach(StoreItem.catalog.filter { $0.compatibleScooterIDs.contains(session.selectedScooterID) }) { item in
                    let alreadyOwned = session.installedItemIDs.contains(item.id)
                        || session.inventoryItemIDs.contains(item.id)
                        || session.orders.contains(where: { $0.itemID == item.id })
                    PartGarageRow(
                        item: item,
                        status: alreadyOwned ? "OWNED / ORDERED" : item.price.formatted(.currency(code: "USD").precision(.fractionLength(0))),
                        actionTitle: alreadyOwned ? nil : "ORDER"
                    ) {
                        session.purchase(item)
                    }
                }
            }
            .padding(16)
        }
    }

    private var orders: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("DELIVERY PROGRESS", detail: "Packages move only when you drive")
                if session.orders.isEmpty {
                    emptyRow("No active or completed orders", symbol: "shippingbox")
                } else {
                    ForEach(session.orders.reversed()) { order in
                        if let item = StoreItem.catalog.first(where: { $0.id == order.itemID }) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                                        Text(order.delivered ? "Delivered to your garage" : "Drive distance advances this delivery")
                                            .font(.system(size: 9, weight: .medium, design: .rounded))
                                            .foregroundStyle(.white.opacity(0.46))
                                    }
                                    Spacer()
                                    Text(order.delivered ? "DELIVERED" : "\(Int(order.progress(currentOdometerMeters: session.odometerMeters) * 100))%")
                                        .font(.system(size: 10, weight: .black, design: .rounded))
                                        .foregroundStyle(order.delivered ? .green : .cyan)
                                }
                                ProgressView(value: order.progress(currentOdometerMeters: session.odometerMeters))
                                    .tint(order.delivered ? .green : .cyan)
                            }
                            .padding(13)
                            .background(.white.opacity(0.052), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var setup: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 15) {
                sectionTitle("RIDE CALIBRATION", detail: "Permanent simulation settings")

                VStack(alignment: .leading, spacing: 8) {
                    Text("DRIVE MODE")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.44))
                    Picker("Drive mode", selection: $session.driveMode) {
                        ForEach(DriveMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .garagePanel()

                VStack(alignment: .leading, spacing: 8) {
                    Text("ROAD SURFACE")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.44))
                    Picker("Surface", selection: $session.surface) {
                        ForEach(RideSurface.allCases) { surface in
                            Text(surface.rawValue).tag(surface)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Grip coefficient: \(session.surface.frictionCoefficient.formatted(.number.precision(.fractionLength(2)))) · this directly changes the physical slide/fall threshold.")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.50))
                }
                .garagePanel()

                VStack(alignment: .leading, spacing: 9) {
                    Text("HARDWARE ACCURACY")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(.cyan)
                    Text(session.selectedScooter.calibrationNote)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                    Divider().overlay(.white.opacity(0.08))
                    HStack {
                        metric("PACK", "\(session.selectedScooter.hardware.battery.seriesCells)S \(session.selectedScooter.hardware.battery.capacityAmpHours.formatted())Ah")
                        metric("CONTROLLER", "\(session.selectedScooter.hardware.controller.batteryCurrentLimitAmps.formatted())A")
                        metric("DRIVE", session.selectedScooter.hardware.drivenWheel.rawValue.uppercased())
                        metric("STEP", "120 Hz")
                    }
                }
                .garagePanel()

                HStack(spacing: 10) {
                    Button("RESET TRIP") { session.resetTrip() }
                        .buttonStyle(.bordered)
                    Button("RESET UPRIGHT") {
                        session.resetRide()
                        session.toggleGarage()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                }
                .font(.system(size: 10, weight: .black, design: .rounded))
            }
            .padding(16)
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .black, design: .rounded))
            Spacer()
            Text(detail)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
        }
    }

    private func emptyRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(.white.opacity(0.34))
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
        }
        .padding(14)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 7, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.36))
            Text(value)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func symbol(for tab: GarageTab) -> String {
        switch tab {
        case .rides: return "scooter"
        case .parts: return "wrench.and.screwdriver.fill"
        case .orders: return "shippingbox.fill"
        case .setup: return "slider.horizontal.3"
        }
    }
}

private struct ScooterGarageCard: View {
    let scooter: ScooterCatalogItem
    let selected: Bool
    let owned: Bool
    let bankBalance: Double
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.cyan.opacity(selected ? 0.28 : 0.12), .indigo.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "scooter")
                    .font(.system(size: 46, weight: .thin))
                    .foregroundStyle(selected ? .cyan : .white.opacity(0.66))
            }
            .frame(width: 118, height: 92)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(scooter.name)
                        .font(.system(size: 14, weight: .black, design: .rounded))
                    if selected {
                        Text("ACTIVE")
                            .font(.system(size: 7, weight: .black, design: .rounded))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.cyan.opacity(0.18), in: Capsule())
                            .foregroundStyle(.cyan)
                    }
                }
                Text(scooter.subtitle)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
                HStack(spacing: 13) {
                    Label("\(scooter.hardware.battery.seriesCells)S", systemImage: "battery.75percent")
                    Label("\(Int(scooter.hardware.controller.batteryCurrentLimitAmps)) A", systemImage: "bolt.fill")
                    Label(scooter.hardware.drivenWheel.rawValue.uppercased(), systemImage: "circle.circle")
                }
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
            }
            Spacer()
            Button(action: action) {
                Text(selected ? "SELECTED" : owned ? "RIDE" : scooter.price.formatted(.currency(code: "USD").precision(.fractionLength(0))))
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .frame(minWidth: 78)
            }
            .buttonStyle(.borderedProminent)
            .tint(selected ? .gray : bankBalance >= scooter.price ? .cyan : .red)
            .disabled(selected)
        }
        .padding(13)
        .background(selected ? Color.cyan.opacity(0.075) : Color.white.opacity(0.042), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(selected ? Color.cyan.opacity(0.42) : Color.white.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct PartGarageRow: View {
    let item: StoreItem
    let status: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.cyan)
                .frame(width: 42, height: 42)
                .background(.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                Text(item.detail)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(status)
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .foregroundStyle(.cyan)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.042), in: RoundedRectangle(cornerRadius: 16))
    }

    private var symbol: String {
        switch item.category {
        case .controllers: return "cpu.fill"
        case .batteries: return "battery.100percent"
        case .motors: return "gearshape.2.fill"
        case .tires: return "circle.circle.fill"
        case .scooters: return "scooter"
        }
    }
}

private extension View {
    func garagePanel() -> some View {
        padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }
}
