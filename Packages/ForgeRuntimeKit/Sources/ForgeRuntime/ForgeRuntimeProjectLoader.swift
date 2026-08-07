import Foundation

public struct ForgeRuntimeLaunchRequest: Equatable, Sendable {
    public let authorization: ForgeRuntimeLaunchAuthorization
    public let entryPointURL: URL
    public let assetURLs: [String: URL]

    init(
        authorization: ForgeRuntimeLaunchAuthorization,
        entryPointURL: URL,
        assetURLs: [String: URL]
    ) {
        self.authorization = authorization
        self.entryPointURL = entryPointURL
        self.assetURLs = assetURLs
    }
}

public enum ForgeRuntimeProjectLoadingError: Error, Equatable, Sendable {
    case manifestFile(ForgeProjectSandboxError)
    case manifestReadFailed
    case manifestDecode(ForgeRuntimeManifestLoadingError)
    case authorization(ForgeRuntimeLaunchAuthorizationError)
    case entryPoint(ForgeProjectSandboxError)
    case asset(path: String, error: ForgeProjectSandboxError)
}

/// Loads a generated project into a bounded, host-authorized launch request.
///
/// This layer performs no WebKit execution. It ensures the future runtime host receives only an
/// already-authorized manifest plus canonical in-sandbox URLs for the exact launch files.
public struct ForgeRuntimeProjectLoader: Sendable {
    public static let defaultManifestPath = "novaforge.runtime.json"

    public let manifestPath: String
    public let manifestDecoder: ForgeRuntimeManifestDecoder
    public let manifestValidator: ForgeRuntimeManifestValidator

    public init(
        manifestPath: String = Self.defaultManifestPath,
        manifestDecoder: ForgeRuntimeManifestDecoder = .init(),
        manifestValidator: ForgeRuntimeManifestValidator = .init()
    ) {
        self.manifestPath = manifestPath
        self.manifestDecoder = manifestDecoder
        self.manifestValidator = manifestValidator
    }

    public func load(
        projectRootURL: URL,
        expectedProjectID: String,
        host: ForgeRuntimeHostSupport
    ) throws -> ForgeRuntimeLaunchRequest {
        let sandbox = ForgeProjectSandbox(rootURL: projectRootURL)

        let manifestURL: URL
        do {
            manifestURL = try sandbox.resolveExistingFile(relativePath: manifestPath)
        } catch let error as ForgeProjectSandboxError {
            throw ForgeRuntimeProjectLoadingError.manifestFile(error)
        } catch {
            throw ForgeRuntimeProjectLoadingError.manifestReadFailed
        }

        let manifestData: Data
        do {
            manifestData = try readBoundedFile(
                at: manifestURL,
                maximumBytes: manifestDecoder.maximumManifestBytes
            )
        } catch let error as ForgeRuntimeManifestLoadingError {
            throw ForgeRuntimeProjectLoadingError.manifestDecode(error)
        } catch {
            throw ForgeRuntimeProjectLoadingError.manifestReadFailed
        }

        let manifest: ForgeProjectManifest
        do {
            manifest = try manifestDecoder.decode(manifestData)
        } catch let error as ForgeRuntimeManifestLoadingError {
            throw ForgeRuntimeProjectLoadingError.manifestDecode(error)
        } catch {
            throw ForgeRuntimeProjectLoadingError.manifestReadFailed
        }

        let authorization: ForgeRuntimeLaunchAuthorization
        do {
            authorization = try manifestValidator.authorize(
                manifest,
                expectedProjectID: expectedProjectID,
                host: host
            )
        } catch let error as ForgeRuntimeLaunchAuthorizationError {
            throw ForgeRuntimeProjectLoadingError.authorization(error)
        } catch {
            throw ForgeRuntimeProjectLoadingError.manifestReadFailed
        }

        let entryPointURL: URL
        do {
            entryPointURL = try sandbox.resolveExistingFile(relativePath: authorization.entryPoint)
        } catch let error as ForgeProjectSandboxError {
            throw ForgeRuntimeProjectLoadingError.entryPoint(error)
        } catch {
            throw ForgeRuntimeProjectLoadingError.manifestReadFailed
        }

        var assetURLs: [String: URL] = [:]
        assetURLs.reserveCapacity(manifest.bundledAssets.count)
        for path in manifest.bundledAssets {
            guard assetURLs[path] == nil else { continue }
            do {
                assetURLs[path] = try sandbox.resolveExistingFile(relativePath: path)
            } catch let error as ForgeProjectSandboxError {
                throw ForgeRuntimeProjectLoadingError.asset(path: path, error: error)
            } catch {
                throw ForgeRuntimeProjectLoadingError.manifestReadFailed
            }
        }

        return ForgeRuntimeLaunchRequest(
            authorization: authorization,
            entryPointURL: entryPointURL,
            assetURLs: assetURLs
        )
    }

    private func readBoundedFile(at url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let readLimit: Int
        if maximumBytes == Int.max {
            readLimit = Int.max
        } else {
            readLimit = maximumBytes + 1
        }

        let data = try handle.read(upToCount: readLimit) ?? Data()
        guard data.count <= maximumBytes else {
            throw ForgeRuntimeManifestLoadingError.manifestTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumBytes
            )
        }
        return data
    }
}
