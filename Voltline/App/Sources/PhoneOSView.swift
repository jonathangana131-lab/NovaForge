import SwiftUI

struct PhoneOSView: View {
    @ObservedObject var session: GameSession
    @State private var dragOrigin: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)

                phone
                    .position(x: proxy.size.width - 172, y: proxy.size.height * 0.51)
                    .offset(session.phoneOffset)
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                session.setPhoneOffset(CGSize(
                                    width: dragOrigin.width + value.translation.width,
                                    height: dragOrigin.height + value.translation.height
                                ))
                            }
                            .onEnded { _ in dragOrigin = session.phoneOffset }
                    )
            }
        }
        .onAppear { dragOrigin = session.phoneOffset }
    }

    private var phone: some View {
        VStack(spacing: 0) {
            phoneStatusBar
            Divider().overlay(.white.opacity(0.08))
            PhoneAppRouter(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            phoneDock
        }
        .frame(width: 304, height: 366)
        .background(
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.045, blue: 0.07), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 42, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .stroke(.white.opacity(0.26), lineWidth: 2)
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(.black)
                .frame(width: 82, height: 20)
                .padding(.top, 6)
        }
        .shadow(color: .black.opacity(0.72), radius: 28, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phoneOS")
    }

    private var phoneStatusBar: some View {
        HStack {
            Text(phoneTime)
                .font(.system(size: 10, weight: .bold, design: .rounded))
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
            }
            .font(.system(size: 9, weight: .bold))
            Button {
                session.togglePhone()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("closePhoneButton")
        }
        .padding(.horizontal, 15)
        .padding(.top, 11)
        .frame(height: 35)
    }

    private var phoneDock: some View {
        HStack(spacing: 31) {
            Button {
                session.selectedPhoneApp = .home
            } label: {
                Image(systemName: "square.grid.3x3.fill")
            }
            Button {
                session.selectedPhoneApp = .messages
            } label: {
                Image(systemName: "message.fill")
            }
            Button {
                session.selectedPhoneApp = .scooter
            } label: {
                Image(systemName: "scooter")
            }
            Button {
                session.selectedPhoneApp = .market
            } label: {
                Image(systemName: "bag.fill")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 16, weight: .semibold))
        .frame(height: 39)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private var phoneTime: String {
        let totalMinutes = Int(session.gameSeconds / 4).quotientAndRemainder(dividingBy: 24 * 60).remainder
        let hour = totalMinutes / 60
        let minute = totalMinutes % 60
        return String(format: "%d:%02d", hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour), minute)
    }
}

private struct PhoneAppRouter: View {
    @ObservedObject var session: GameSession

    var body: some View {
        Group {
            switch session.selectedPhoneApp {
            case .home: PhoneHomeView(session: session)
            case .messages: MessagesPhoneView(session: session)
            case .maps: MapsPhoneView(session: session)
            case .camera: CameraPhoneView(session: session)
            case .photos: PhotosPhoneView(session: session)
            case .weather: WeatherPhoneView(session: session)
            case .bank: BankPhoneView(session: session)
            case .market: MarketPhoneView(session: session)
            case .scooter: ScooterPhoneView(session: session)
            case .vesc: VESCPhoneView(session: session)
            }
        }
    }
}

private struct PhoneHomeView: View {
    @ObservedObject var session: GameSession

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.cyan.opacity(0.34), Color.indigo.opacity(0.26), Color.black.opacity(0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 15) {
                    ForEach(PhoneApp.allCases.filter { $0 != .home }) { app in
                        Button {
                            session.selectedPhoneApp = app
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: app.symbol)
                                    .font(.system(size: 19, weight: .semibold))
                                    .frame(width: 43, height: 43)
                                    .background(appColor(app), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .shadow(color: .black.opacity(0.25), radius: 5, y: 3)
                                Text(app.rawValue)
                                    .font(.system(size: 7, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("phoneApp-\(app.rawValue)")
                    }
                }
                .padding(15)
            }
        }
    }

    private func appColor(_ app: PhoneApp) -> Color {
        switch app {
        case .messages: return .green
        case .maps: return .blue
        case .camera: return .gray
        case .photos: return .pink
        case .weather: return .cyan
        case .bank: return .mint
        case .market: return .orange
        case .scooter: return .indigo
        case .vesc: return .purple
        case .home: return .gray
        }
    }
}

private struct PhoneHeader: View {
    let title: String
    let subtitle: String?
    @ObservedObject var session: GameSession

    var body: some View {
        HStack(spacing: 9) {
            Button {
                session.selectedPhoneApp = .home
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(.black.opacity(0.22))
    }
}

private struct MessagesPhoneView: View {
    @ObservedObject var session: GameSession
    @State private var messageText = ""

    var body: some View {
        VStack(spacing: 0) {
            PhoneHeader(title: "Messages", subtitle: "Offline simulated contacts", session: session)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 7) {
                        ForEach(session.messages) { line in
                            HStack {
                                if line.sender == .player { Spacer(minLength: 34) }
                                VStack(alignment: .leading, spacing: 2) {
                                    if line.sender != .player {
                                        Text(senderName(line.sender))
                                            .font(.system(size: 7, weight: .black, design: .rounded))
                                            .foregroundStyle(.cyan)
                                    }
                                    Text(line.text)
                                        .font(.system(size: 9, weight: .medium, design: .rounded))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(line.sender == .player ? Color.blue : Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                                if line.sender != .player { Spacer(minLength: 34) }
                            }
                            .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: session.messages.count) { _, _ in
                    if let last = session.messages.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            HStack(spacing: 7) {
                TextField("Message", text: $messageText)
                    .font(.system(size: 10, design: .rounded))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(.white.opacity(0.09), in: Capsule())
                Button {
                    session.sendMessage(messageText)
                    messageText = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 25))
                }
                .buttonStyle(.plain)
            }
            .padding(8)
        }
    }

    private func senderName(_ sender: ChatLine.Sender) -> String {
        switch sender {
        case .player: return "You"
        case .max: return "Max"
        case .partsBot: return "Parts Bot"
        case .ridingCrew: return "Riding Crew"
        }
    }
}

private struct MapsPhoneView: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 0) {
            PhoneHeader(title: "Maps", subtitle: "Voltline District", session: session)
            GeometryReader { proxy in
                ZStack {
                    Color(red: 0.08, green: 0.10, blue: 0.12)
                    Rectangle()
                        .fill(.gray.opacity(0.36))
                        .frame(width: 58)
                    Rectangle()
                        .fill(.white.opacity(0.3))
                        .frame(width: 2)
                    ForEach(session.renderSnapshot.traffic) { car in
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
                            .position(
                                x: proxy.size.width * 0.5 + CGFloat(car.laneX) * 2.5,
                                y: proxy.size.height * 0.5 - CGFloat(car.z - session.renderSnapshot.playerZ) * 0.45
                            )
                    }
                    Image(systemName: "location.north.fill")
                        .foregroundStyle(.cyan)
                        .rotationEffect(.radians(session.renderSnapshot.yawRadians))
                        .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)
                    VStack {
                        HStack {
                            Text("TUNNEL")
                                .font(.system(size: 7, weight: .black, design: .rounded))
                                .padding(5)
                                .background(.black.opacity(0.55), in: Capsule())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(10)
            }
        }
    }
}

private struct CameraPhoneView: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 0) {
            PhoneHeader(title: "Camera", subtitle: session.camera.rawValue, session: session)
            ZStack {
                LinearGradient(colors: [.indigo.opacity(0.65), .black], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 8) {
                    Image(systemName: "scooter")
                        .font(.system(size: 74, weight: .thin))
                        .foregroundStyle(.cyan)
                    Text("\(Int(session.speedMPH.rounded())) MPH")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                    Text("Live in-game camera simulation")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                }
            }
            .overlay(alignment: .bottom) {
                Button {
                    session.capturePhoto()
                } label: {
                    Circle()
                        .fill(.white)
                        .frame(width: 42, height: 42)
                        .overlay { Circle().stroke(.black, lineWidth: 3).padding(3) }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)
                .accessibilityIdentifier("capturePhotoButton")
            }
        }
    }
}

private struct PhotosPhoneView: View {
    @ObservedObject var session: GameSession
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            PhoneHeader(title: "Photos", subtitle: "\(session.photos.count) in-game captures", session: session)
            ScrollView(showsIndicators: false) {
                if session.photos.isEmpty {
                    ContentUnavailableView("No Photos", systemImage: "photo", description: Text("Use the Camera app during a ride."))
                        .scaleEffect(0.72)
                        .frame(height: 200)
                } else {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(session.photos) { photo in
                            ZStack(alignment: .bottomLeading) {
                                LinearGradient(colors: [.cyan.opacity(0.7), .indigo.opacity(0.48), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                                Image(systemName: "scooter")
                                    .font(.system(size: 25, weight: .thin))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                Text("\(Int(photo.speedMPH)) mph")
                                    .font(.system(size: 7, weight: .black, design: .rounded))
                                    .padding(5)
                            }
                            .frame(height: 67)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    .padding(9)
                }
            }
        }
    }
}

private struct WeatherPhoneView: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 0) {
            PhoneHeader(title: "Weather", subtitle: "Voltline District", session: session)
            VStack(spacing: 11) {
                Image(systemName: session.surface == .wetAsphalt ? "cloud.rain.fill" : "moon.stars.fill")
                    .font(.system(size: 48, weight: .light))
                    .symbolRenderingMode(.multicolor)
                Text(session.surface == .wetAsphalt ? "61°" : "68°")
                    .font(.system(size: 42, weight: .thin, design: .rounded))
                Text(session.surface.rawValue)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                Text("Grip estimate: \(Int(session.surface.frictionCoefficient * 100))% · Road choice directly changes the crash threshold.")
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
                    .multilineTextAlignment(.center)
                Picker("Surface", selection: $session.surface) {
                    ForEach(RideSurface.allCases) { surface in
                        Text(surface.rawValue).tag(surface)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 9, weight: .bold))
            }
            .padding(16)
            Spacer()
        }
    }
}

private struct BankPhoneView: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 0) {
            PhoneHeader(title: "Volt Bank", subtitle: "Drive-to-earn account", session: session)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 11) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AVAILABLE")
                            .font(.system(size: 7, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.42))
                        Text(session.bankDisplay)
                            .font(.system(size: 34, weight: .black, design: .rounded))
                        Text("\(session.pendingDisplay) collecting toward the next $100 deposit")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.cyan)
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.mint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))

                    Text("RECENT DEPOSITS")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                    ForEach(session.deposits.prefix(8)) { deposit in
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading) {
                                Text("Drive earnings")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                Text(String(format: "At %.1f miles", deposit.odometerMeters / 1_609.344))
                                    .font(.system(size: 7, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            Spacer()
                            Text("+$\(Int(deposit.amount))")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(.green)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(11)
            }
        }
        .accessibilityIdentifier("bankPhoneApp")
    }
}

private struct MarketPhoneView: View {
    @ObservedObject var session: GameSession
    @State private var category: StoreCategory = .controllers

    var body: some View {
        VStack(spacing: 0) {
            PhoneHeader(title: "Volt Market", subtitle: session.bankDisplay, session: session)
            Picker("Category", selection: $category) {
                ForEach(StoreCategory.allCases) { category in
                    Text(category.rawValue).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .scaleEffect(0.78)
            .frame(height: 30)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    if category == .scooters {
                        ForEach(ScooterCatalogItem.all) { scooter in
                            marketScooter(scooter)
                        }
                    } else {
                        ForEach(StoreItem.catalog.filter { $0.category == category }) { item in
                            marketItem(item)
                        }
                    }
                }
                .padding(9)
            }
        }
        .accessibilityIdentifier("marketPhoneApp")
    }

    private func marketScooter(_ scooter: ScooterCatalogItem) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "scooter")
                .font(.system(size: 20, weight: .bold))
                .frame(width: 40, height: 40)
                .background(.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(scooter.name)
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                Text(scooter.subtitle)
                    .font(.system(size: 7, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(2)
            }
            Spacer()
            Button(session.ownedScooterIDs.contains(scooter.id) ? "OWNED" : "$\(Int(scooter.price))") {
                session.buyScooter(scooter)
            }
            .font(.system(size: 8, weight: .black, design: .rounded))
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
        }
        .padding(9)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }

    private func marketItem(_ item: StoreItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                    Text(item.detail)
                        .font(.system(size: 7, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(3)
                }
                Spacer()
                Button("$\(Int(item.price))") {
                    session.purchase(item)
                }
                .font(.system(size: 8, weight: .black, design: .rounded))
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            if let order = session.orders.first(where: { $0.itemID == item.id }), !order.delivered {
                ProgressView(value: order.progress(currentOdometerMeters: session.odometerMeters))
                    .tint(.cyan)
                Text("Delivery \(Int(order.progress(currentOdometerMeters: session.odometerMeters) * 100))% · drive to progress")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(.cyan)
            }
        }
        .padding(9)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ScooterPhoneView: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 0) {
            PhoneHeader(title: "Scooter", subtitle: session.selectedScooter.name, session: session)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    HStack(alignment: .lastTextBaseline) {
                        Text(Int(session.speedMPH.rounded()).formatted())
                            .font(.system(size: 48, weight: .black, design: .rounded))
                        Text("MPH")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.48))
                        Spacer()
                        Text("\(Int(session.simulationState.batteryStateOfCharge * 100))%")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundStyle(.cyan)
                    }
                    .padding(12)
                    .background(.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))

                    Picker("Mode", selection: $session.driveMode) {
                        ForEach(DriveMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    telemetry("Battery voltage", String(format: "%.1f V", session.simulationState.batteryVoltage))
                    telemetry("Battery current", String(format: "%.1f A", session.simulationState.batteryCurrentAmps))
                    telemetry("Motor power", "\(Int(session.simulationState.electricalPowerWatts)) W")
                    telemetry("Motor temp", "\(Int(session.simulationState.motorTemperatureCelsius))°C")
                    telemetry("Trip", String(format: "%.2f mi", session.tripMiles))

                    Button("RESET TRIP") { session.resetTrip() }
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .buttonStyle(.bordered)
                }
                .padding(11)
            }
        }
    }

    private func telemetry(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.white.opacity(0.56))
            Spacer()
            Text(value)
                .fontWeight(.bold)
        }
        .font(.system(size: 9, design: .rounded))
    }
}

private struct VESCPhoneView: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 0) {
            PhoneHeader(title: "VESC Tool", subtitle: "Simulated controller link", session: session)
            if session.hasVESC {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        status
                        tuningSlider("Battery current", value: binding(\.batteryCurrentLimitAmps), range: 5...35, suffix: "A")
                        tuningSlider("Motor current", value: binding(\.motorCurrentLimitAmps), range: 10...100, suffix: "A")
                        tuningSlider("Regen current", value: binding(\.regenCurrentLimitAmps), range: 0...25, suffix: "A")
                        tuningSlider("Throttle expo", value: binding(\.throttleExpo), range: -0.4...0.7, suffix: "")
                        tuningSlider("Ramp", value: binding(\.rampSeconds), range: 0.08...1.2, suffix: "s")
                        Button("WRITE CONFIGURATION") {
                            session.applyVESCConfiguration()
                        }
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .accessibilityIdentifier("writeVESCButton")
                    }
                    .padding(11)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.purple)
                    Text("NO COMPATIBLE CONTROLLER")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                    Text("Buy and install the Smart FOC controller from Volt Market. The tuning limits then rebuild the same motor/controller simulation used by the ride physics.")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                    Button("OPEN MARKET") {
                        session.selectedPhoneApp = .market
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
                .padding(24)
            }
        }
        .accessibilityIdentifier("vescPhoneApp")
    }

    private var status: some View {
        HStack {
            Circle().fill(.green).frame(width: 7, height: 7)
            VStack(alignment: .leading) {
                Text("CONNECTED")
                    .font(.system(size: 8, weight: .black, design: .rounded))
                Text("\(Int(session.simulationState.batteryVoltage)) V · \(Int(session.simulationState.motorRPM)) RPM")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.50))
            }
            Spacer()
            Text("FOC")
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(.purple)
        }
        .padding(9)
        .background(.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
    }

    private func tuningSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))\(suffix)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.purple)
            }
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            Slider(value: value, in: range)
                .tint(.purple)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<VESCConfiguration, Double>) -> Binding<Double> {
        Binding(
            get: { session.vescConfiguration[keyPath: keyPath] },
            set: { session.vescConfiguration[keyPath: keyPath] = $0 }
        )
    }
}
