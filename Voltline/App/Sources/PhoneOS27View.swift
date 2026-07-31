import SwiftUI

/// Original in-game operating system built with modern SwiftUI glass APIs.
/// It uses a believable 19.5:9 portrait device instead of the old square shell.
struct PhoneOS27View: View {
    @ObservedObject var session: GameSession
    @State private var dragOrigin: CGSize = .zero
    @State private var minimized = false
    @Namespace private var glassNamespace

    var body: some View {
        GeometryReader { proxy in
            if minimized {
                minimizedButton(proxy: proxy)
            } else {
                expandedPhone(proxy: proxy)
            }
        }
        .onAppear { dragOrigin = session.phoneOffset }
    }

    private func expandedPhone(proxy: GeometryProxy) -> some View {
        let height = min(370.0, max(326.0, proxy.size.height - 16.0))
        let width = height * 9.0 / 19.5
        let baseX = proxy.size.width - width * 0.5 - 12
        let baseY = proxy.size.height * 0.5

        return ZStack {
            RoundedRectangle(cornerRadius: width * 0.205, style: .continuous)
                .fill(Color.black)

            VStack(spacing: 0) {
                statusBar(
                    proxy: proxy,
                    phoneWidth: width,
                    phoneHeight: height,
                    baseX: baseX,
                    baseY: baseY
                )

                PhoneOS27Router(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: width * 0.105, style: .continuous))

                dock
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
            }
            .padding(5)
            .clipShape(RoundedRectangle(cornerRadius: width * 0.175, style: .continuous))

            RoundedRectangle(cornerRadius: width * 0.205, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.38), .gray.opacity(0.20), .black, .white.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
                .allowsHitTesting(false)

            VStack {
                Capsule()
                    .fill(.black)
                    .frame(width: width * 0.32, height: max(12, width * 0.076))
                    .overlay(alignment: .trailing) {
                        Circle()
                            .fill(Color(red: 0.025, green: 0.075, blue: 0.12))
                            .frame(width: max(5, width * 0.030))
                            .overlay {
                                Circle().fill(.blue.opacity(0.16)).padding(1)
                            }
                            .padding(.trailing, 7)
                    }
                    .padding(.top, 7)
                Spacer()
            }
            .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .position(x: baseX, y: baseY)
        .offset(session.phoneOffset)
        .shadow(color: .black.opacity(0.85), radius: 28, y: 13)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phoneOS")
    }

    private func statusBar(
        proxy: GeometryProxy,
        phoneWidth: CGFloat,
        phoneHeight: CGFloat,
        baseX: CGFloat,
        baseY: CGFloat
    ) -> some View {
        HStack(spacing: 5) {
            Text(phoneTime)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))

            Spacer(minLength: 35)

            HStack(spacing: 3) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
            }
            .font(.system(size: 7, weight: .bold))

            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    minimized = true
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .black))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("minimizePhoneButton")

            Button {
                session.togglePhone()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .black))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("closePhoneButton")
        }
        .padding(.horizontal, 9)
        .padding(.top, 8)
        .frame(height: 31)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    let proposed = CGSize(
                        width: dragOrigin.width + value.translation.width,
                        height: dragOrigin.height + value.translation.height
                    )
                    let minX = phoneWidth * 0.5 + 7 - baseX
                    let maxX = proxy.size.width - phoneWidth * 0.5 - 7 - baseX
                    let minY = phoneHeight * 0.5 + 7 - baseY
                    let maxY = proxy.size.height - phoneHeight * 0.5 - 7 - baseY
                    session.setPhoneOffset(CGSize(
                        width: min(max(proposed.width, minX), maxX),
                        height: min(max(proposed.height, minY), maxY)
                    ))
                }
                .onEnded { _ in dragOrigin = session.phoneOffset }
        )
    }

    private func minimizedButton(proxy: GeometryProxy) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                minimized = false
            }
        } label: {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 48, height: 48)
        }
        .phoneGlassButton(prominent: true)
        .position(x: proxy.size.width - 40, y: proxy.size.height * 0.45)
        .accessibilityIdentifier("restorePhoneButton")
    }

    @ViewBuilder
    private var dock: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 7) {
                HStack(spacing: 7) {
                    glassDockButton(.home, symbol: "square.grid.3x3.fill")
                    glassDockButton(.messages, symbol: "message.fill")
                    glassDockButton(.scooter, symbol: "scooter")
                    glassDockButton(.market, symbol: "bag.fill")
                }
            }
            .frame(height: 42)
        } else {
            HStack(spacing: 7) {
                fallbackDockButton(.home, symbol: "square.grid.3x3.fill")
                fallbackDockButton(.messages, symbol: "message.fill")
                fallbackDockButton(.scooter, symbol: "scooter")
                fallbackDockButton(.market, symbol: "bag.fill")
            }
            .frame(height: 42)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    @available(iOS 26.0, *)
    private func glassDockButton(_ app: PhoneApp, symbol: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                session.selectedPhoneApp = app
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 29, height: 29)
        }
        .buttonStyle(.glass)
        .glassEffectID(app.rawValue, in: glassNamespace)
    }

    private func fallbackDockButton(_ app: PhoneApp, symbol: String) -> some View {
        Button {
            session.selectedPhoneApp = app
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 29, height: 29)
                .background(.white.opacity(0.09), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var phoneTime: String {
        let total = Int(session.gameSeconds / 4)
            .quotientAndRemainder(dividingBy: 24 * 60)
            .remainder
        let hour = total / 60
        let minute = total % 60
        return String(format: "%d:%02d", hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour), minute)
    }
}

private struct PhoneOS27Router: View {
    @ObservedObject var session: GameSession

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.035, green: 0.07, blue: 0.14),
                    Color(red: 0.06, green: 0.025, blue: 0.12),
                    Color(red: 0.005, green: 0.012, blue: 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            switch session.selectedPhoneApp {
            case .home: PhoneOS27Home(session: session)
            case .messages: PhoneOS27Messages(session: session)
            case .maps: PhoneOS27Maps(session: session)
            case .camera: PhoneOS27Camera(session: session)
            case .photos: PhoneOS27Photos(session: session)
            case .weather: PhoneOS27Weather(session: session)
            case .bank: PhoneOS27Bank(session: session)
            case .market: PhoneOS27Market(session: session)
            case .scooter: PhoneOS27Scooter(session: session)
            case .vesc: PhoneOS27VESC(session: session)
            }
        }
    }
}

private struct PhoneOS27Header: View {
    let title: String
    let subtitle: String?
    @ObservedObject var session: GameSession

    var body: some View {
        HStack(spacing: 7) {
            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                    session.selectedPhoneApp = .home
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .black))
                    .frame(width: 25, height: 25)
            }
            .phoneGlassButton()

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 6.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }
}

private struct PhoneOS27Home: View {
    @ObservedObject var session: GameSession
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 3)

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(PhoneApp.allCases.filter { $0 != .home }) { app in
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            session.selectedPhoneApp = app
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: app.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(appColor(app), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(.white.opacity(0.22), lineWidth: 0.7)
                                }
                                .shadow(color: appColor(app).opacity(0.34), radius: 6, y: 3)
                            Text(app.rawValue)
                                .font(.system(size: 6.2, weight: .bold, design: .rounded))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("phoneApp-\(app.rawValue)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 15)
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

private struct PhoneOS27Messages: View {
    @ObservedObject var session: GameSession
    @State private var message = ""

    var body: some View {
        VStack(spacing: 0) {
            PhoneOS27Header(title: "Messages", subtitle: "Simulated contacts", session: session)
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(session.messages) { line in
                        HStack {
                            if line.sender == .player { Spacer(minLength: 23) }
                            Text(line.text)
                                .font(.system(size: 7.5, weight: .medium, design: .rounded))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    line.sender == .player ? Color.blue : Color.white.opacity(0.11),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                                )
                            if line.sender != .player { Spacer(minLength: 23) }
                        }
                    }
                }
                .padding(8)
            }
            HStack(spacing: 5) {
                TextField("Message", text: $message)
                    .font(.system(size: 7.5, design: .rounded))
                    .padding(.horizontal, 8)
                    .frame(height: 27)
                    .background(.white.opacity(0.09), in: Capsule())
                Button {
                    session.sendMessage(message)
                    message = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
            }
            .padding(7)
        }
    }
}

private struct PhoneOS27Maps: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 0) {
            PhoneOS27Header(title: "Maps", subtitle: "Voltline District", session: session)
            GeometryReader { proxy in
                ZStack {
                    Color(red: 0.07, green: 0.09, blue: 0.11)
                    Rectangle().fill(.gray.opacity(0.32)).frame(width: 46)
                    Rectangle().fill(.white.opacity(0.24)).frame(width: 1.5)
                    ForEach(session.renderSnapshot.traffic) { car in
                        Circle()
                            .fill(.orange)
                            .frame(width: 4, height: 4)
                            .position(
                                x: proxy.size.width * 0.5 + CGFloat(car.laneX) * 2,
                                y: proxy.size.height * 0.5 - CGFloat(car.z - session.renderSnapshot.playerZ) * 0.32
                            )
                    }
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(.cyan)
                        .rotationEffect(.radians(session.renderSnapshot.yawRadians))
                        .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)
                    VStack {
                        Text("TUNNEL ROUTE")
                            .font(.system(size: 6.5, weight: .black, design: .rounded))
                            .padding(5)
                            .phoneGlassSurface(radius: 10)
                        Spacer()
                    }
                    .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .padding(8)
            }
        }
    }
}

private struct PhoneOS27Camera: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 0) {
            PhoneOS27Header(title: "Camera", subtitle: session.camera.rawValue, session: session)
            ZStack {
                LinearGradient(colors: [.indigo.opacity(0.70), .black], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 6) {
                    Image(systemName: "scooter")
                        .font(.system(size: 52, weight: .thin))
                        .foregroundStyle(.cyan)
                    Text("\(Int(session.speedMPH.rounded())) MPH")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                }
                VStack {
                    Spacer()
                    Button {
                        session.capturePhoto()
                    } label: {
                        Circle()
                            .fill(.white)
                            .frame(width: 37, height: 37)
                            .overlay { Circle().stroke(.black, lineWidth: 2.5).padding(3) }
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("capturePhotoButton")
                }
            }
        }
    }
}

private struct PhoneOS27Photos: View {
    @ObservedObject var session: GameSession
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 2)

    var body: some View {
        VStack(spacing: 0) {
            PhoneOS27Header(title: "Photos", subtitle: "\(session.photos.count) captures", session: session)
            ScrollView(showsIndicators: false) {
                if session.photos.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 32, weight: .light))
                        Text("Use Camera during a ride")
                            .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 70)
                } else {
                    LazyVGrid(columns: columns, spacing: 5) {
                        ForEach(session.photos) { photo in
                            ZStack(alignment: .bottomLeading) {
                                LinearGradient(colors: [.cyan.opacity(0.72), .indigo.opacity(0.52), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                                Image(systemName: "scooter")
                                    .font(.system(size: 21, weight: .thin))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                Text("\(Int(photo.speedMPH)) mph")
                                    .font(.system(size: 5.8, weight: .black, design: .rounded))
                                    .padding(4)
                            }
                            .frame(height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                    .padding(7)
                }
            }
        }
    }
}

private struct PhoneOS27Weather: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 0) {
            PhoneOS27Header(title: "Weather", subtitle: "Voltline District", session: session)
            VStack(spacing: 8) {
                Image(systemName: session.surface == .wetAsphalt ? "cloud.rain.fill" : "moon.stars.fill")
                    .font(.system(size: 38, weight: .light))
                    .symbolRenderingMode(.multicolor)
                Text(session.surface == .wetAsphalt ? "61°" : "68°")
                    .font(.system(size: 34, weight: .thin, design: .rounded))
                Text(session.surface.rawValue)
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                Text("Grip \(Int(session.surface.frictionCoefficient * 100))%")
                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
                Picker("Surface", selection: $session.surface) {
                    ForEach(RideSurface.allCases) { surface in
                        Text(surface.rawValue).tag(surface)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 8, weight: .bold))
            }
            .padding(12)
            Spacer()
        }
    }
}

private struct PhoneOS27Bank: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 0) {
            PhoneOS27Header(title: "Volt Bank", subtitle: "Drive-to-earn", session: session)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 9) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AVAILABLE")
                            .font(.system(size: 6, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.42))
                        Text(session.bankDisplay)
                            .font(.system(size: 27, weight: .black, design: .rounded))
                        Text("\(session.pendingDisplay) toward next $100 deposit")
                            .font(.system(size: 6.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.cyan)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .phoneGlassSurface(radius: 14, tint: .mint)

                    Text("RECENT DEPOSITS")
                        .font(.system(size: 6.5, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.44))

                    ForEach(session.deposits.prefix(8)) { deposit in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Drive earnings")
                                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                                Text(String(format: "At %.1f miles", deposit.odometerMeters / 1_609.344))
                                    .font(.system(size: 5.8, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            Spacer()
                            Text("+$\(Int(deposit.amount))")
                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                                .foregroundStyle(.green)
                        }
                    }
                }
                .padding(8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bankPhoneApp")
    }
}

private struct PhoneOS27Market: View {
    @ObservedObject var session: GameSession
    @State private var category: StoreCategory = .scooters

    var body: some View {
        VStack(spacing: 0) {
            PhoneOS27Header(title: "Volt Market", subtitle: session.bankDisplay, session: session)
            Picker("Category", selection: $category) {
                ForEach(StoreCategory.allCases) { category in
                    Text(category.rawValue).tag(category)
                }
            }
            .pickerStyle(.menu)
            .font(.system(size: 7.5, weight: .bold))
            .frame(height: 27)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    if category == .scooters {
                        ForEach(ScooterCatalogItem.all) { scooter in
                            HStack(spacing: 6) {
                                Image(systemName: "scooter")
                                    .font(.system(size: 15, weight: .bold))
                                    .frame(width: 31, height: 31)
                                    .background(.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(scooter.name)
                                        .font(.system(size: 7, weight: .heavy, design: .rounded))
                                        .lineLimit(2)
                                    Text(scooter.subtitle)
                                        .font(.system(size: 5.5, weight: .medium, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.46))
                                        .lineLimit(2)
                                }
                                Spacer()
                                Button(session.ownedScooterIDs.contains(scooter.id) ? "OWNED" : "$\(Int(scooter.price))") {
                                    session.buyScooter(scooter)
                                }
                                .font(.system(size: 5.8, weight: .black, design: .rounded))
                                .buttonStyle(.borderedProminent)
                                .tint(.cyan)
                            }
                            .padding(7)
                            .phoneGlassSurface(radius: 12)
                        }
                    } else {
                        ForEach(StoreItem.catalog.filter { $0.category == category }) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name)
                                            .font(.system(size: 7, weight: .heavy, design: .rounded))
                                        Text(item.detail)
                                            .font(.system(size: 5.5, weight: .medium, design: .rounded))
                                            .foregroundStyle(.white.opacity(0.46))
                                            .lineLimit(3)
                                    }
                                    Spacer()
                                    Button("$\(Int(item.price))") {
                                        session.purchase(item)
                                    }
                                    .font(.system(size: 5.8, weight: .black, design: .rounded))
                                    .buttonStyle(.borderedProminent)
                                    .tint(.orange)
                                }
                                if let order = session.orders.first(where: { $0.itemID == item.id }), !order.delivered {
                                    ProgressView(value: order.progress(currentOdometerMeters: session.odometerMeters))
                                        .tint(.cyan)
                                }
                            }
                            .padding(7)
                            .phoneGlassSurface(radius: 12)
                        }
                    }
                }
                .padding(7)
            }
        }
        .accessibilityIdentifier("marketPhoneApp")
    }
}

private struct PhoneOS27Scooter: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 0) {
            PhoneOS27Header(title: "Scooter", subtitle: session.selectedScooter.name, session: session)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    HStack(alignment: .lastTextBaseline) {
                        Text(Int(session.speedMPH.rounded()).formatted())
                            .font(.system(size: 36, weight: .black, design: .rounded))
                        Text("MPH")
                            .font(.system(size: 6.5, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.48))
                        Spacer()
                        Text("\(Int(session.simulationState.batteryStateOfCharge * 100))%")
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                            .foregroundStyle(.cyan)
                    }
                    .padding(9)
                    .phoneGlassSurface(radius: 13, tint: .cyan)

                    Picker("Mode", selection: $session.driveMode) {
                        ForEach(DriveMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .scaleEffect(0.78)
                    .frame(height: 27)

                    telemetry("Battery voltage", String(format: "%.1f V", session.simulationState.batteryVoltage))
                    telemetry("Battery current", String(format: "%.1f A", session.simulationState.batteryCurrentAmps))
                    telemetry("Motor power", "\(Int(session.simulationState.electricalPowerWatts)) W")
                    telemetry("Motor temp", "\(Int(session.simulationState.motorTemperatureCelsius))°C")
                    telemetry("Trip", String(format: "%.2f mi", session.tripMiles))

                    Button("RESET TRIP") { session.resetTrip() }
                        .font(.system(size: 7, weight: .black, design: .rounded))
                        .buttonStyle(.bordered)
                }
                .padding(8)
            }
        }
    }

    private func telemetry(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.white.opacity(0.56))
            Spacer()
            Text(value).fontWeight(.bold)
        }
        .font(.system(size: 7, design: .rounded))
        .padding(.horizontal, 5)
    }
}

private struct PhoneOS27VESC: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 0) {
            PhoneOS27Header(title: "VESC Tool", subtitle: "Simulated FOC controller", session: session)
            if session.hasVESC {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 5) {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("CONNECTED")
                                    .font(.system(size: 6.5, weight: .black, design: .rounded))
                                Text("\(Int(session.simulationState.batteryVoltage)) V · \(Int(session.simulationState.motorRPM)) RPM")
                                    .font(.system(size: 5.7, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.50))
                            }
                            Spacer()
                            Text("FOC")
                                .font(.system(size: 7, weight: .black, design: .rounded))
                                .foregroundStyle(.purple)
                        }
                        .padding(7)
                        .phoneGlassSurface(radius: 11, tint: .purple)

                        slider("Battery current", value: binding(\.batteryCurrentLimitAmps), range: 5...35, suffix: "A")
                        slider("Motor current", value: binding(\.motorCurrentLimitAmps), range: 10...100, suffix: "A")
                        slider("Regen", value: binding(\.regenCurrentLimitAmps), range: 0...25, suffix: "A")
                        slider("Throttle expo", value: binding(\.throttleExpo), range: -0.4...0.7, suffix: "")
                        slider("Ramp", value: binding(\.rampSeconds), range: 0.08...1.2, suffix: "s")

                        Button("WRITE CONFIGURATION") {
                            session.applyVESCConfiguration()
                        }
                        .font(.system(size: 6.8, weight: .black, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .accessibilityIdentifier("writeVESCButton")
                    }
                    .padding(8)
                }
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.purple)
                    Text("NO COMPATIBLE CONTROLLER")
                        .font(.system(size: 8.5, weight: .black, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text("Install the Smart FOC controller from Volt Market to unlock live current and throttle tuning.")
                        .font(.system(size: 6.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                    Button("OPEN MARKET") { session.selectedPhoneApp = .market }
                        .font(.system(size: 7, weight: .black, design: .rounded))
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                }
                .padding(18)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vescPhoneApp")
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.1f%@", value.wrappedValue, suffix))
                    .font(.system(size: 6.5, weight: .black, design: .monospaced))
                    .foregroundStyle(.purple)
            }
            .font(.system(size: 6.5, weight: .bold, design: .rounded))
            Slider(value: value, in: range)
                .tint(.purple)
                .frame(height: 16)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<VESCConfiguration, Double>) -> Binding<Double> {
        Binding(
            get: { session.vescConfiguration[keyPath: keyPath] },
            set: { session.vescConfiguration[keyPath: keyPath] = $0 }
        )
    }
}

private extension View {
    @ViewBuilder
    func phoneGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self
                .buttonStyle(.plain)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    @ViewBuilder
    func phoneGlassSurface(radius: CGFloat, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint.opacity(0.18)), in: .rect(cornerRadius: radius))
            } else {
                self.glassEffect(.regular, in: .rect(cornerRadius: radius))
            }
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
        }
    }
}
