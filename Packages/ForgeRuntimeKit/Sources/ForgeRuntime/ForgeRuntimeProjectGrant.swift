import Foundation

/// Host-owned, project-specific authority ceiling for one Forge Runtime launch.
///
/// A generated manifest may request capabilities and HTTPS hosts, but it cannot create this value.
/// The app/policy layer must bind the grant to the exact project before launch authorization is
/// derived. Empty capability/network sets are a valid deny-all grant.
public struct ForgeRuntimeProjectGrant: Equatable, Sendable {
    public let projectID: String
    public let grantedCapabilityIDs: Set<String>
    public let allowedHTTPSHosts: Set<String>

    public init(
        projectID: String,
        grantedCapabilityIDs: Set<String> = [],
        allowedHTTPSHosts: Set<String> = []
    ) {
        self.projectID = projectID
        self.grantedCapabilityIDs = grantedCapabilityIDs
        self.allowedHTTPSHosts = Set(allowedHTTPSHosts.map { $0.lowercased() })
    }

    public static func denyAll(projectID: String) -> Self {
        .init(projectID: projectID)
    }
}

public enum ForgeRuntimeProjectGrantError: Error, Equatable, Sendable {
    case projectIdentityMismatch(expectedProjectID: String, grantedProjectID: String)
    case unsupportedGrantedCapability(String)
    case invalidGrantedNetworkHost(String)
}

extension ForgeRuntimeProjectGrant {
    func validate(
        expectedProjectID: String,
        host: ForgeRuntimeHostSupport
    ) throws {
        guard projectID == expectedProjectID else {
            throw ForgeRuntimeProjectGrantError.projectIdentityMismatch(
                expectedProjectID: expectedProjectID,
                grantedProjectID: projectID
            )
        }

        if let unsupported = grantedCapabilityIDs
            .filter({ !host.supportedCapabilityIDs.contains($0) })
            .sorted()
            .first {
            throw ForgeRuntimeProjectGrantError.unsupportedGrantedCapability(unsupported)
        }

        if let invalidHost = allowedHTTPSHosts.sorted().first(where: { !Self.isValidExactHost($0) }) {
            throw ForgeRuntimeProjectGrantError.invalidGrantedNetworkHost(invalidHost)
        }
    }

    private static func isValidExactHost(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 253,
              !value.contains("://"),
              !value.contains("/"),
              !value.contains("@"),
              !value.contains(":"),
              !value.contains("*"),
              !value.hasPrefix("."),
              !value.hasSuffix(".") else {
            return false
        }

        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else {
                return false
            }
            return label.unicodeScalars.allSatisfy { scalar in
                let isUpper = scalar.value >= 65 && scalar.value <= 90
                let isLower = scalar.value >= 97 && scalar.value <= 122
                let isDigit = scalar.value >= 48 && scalar.value <= 57
                return isUpper || isLower || isDigit || scalar == "-"
            }
        }
    }
}
