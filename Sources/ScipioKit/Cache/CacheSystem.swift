import Foundation
import TSCUtility
import PackageGraph
import TSCBasic

private let jsonEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    return encoder
}()

struct ClangChecker<E: Executor> {
    private let executor: E

    init(executor: E = ProcessExecutor()) {
        self.executor = executor
    }

    func fetchClangVersion() async throws -> String? {
        let result = try await executor.execute("/usr/bin/xcrun", "clang", "--version")
        let rawString = try result.unwrapOutput()
        return parseClangVersion(from: rawString)
    }

    private func parseClangVersion(from outputString: String) -> String? {
        // TODO Use modern regex
        let regex = try! NSRegularExpression(pattern: "Apple\\sclang\\sversion\\s.+\\s\\((?<version>.+)\\)")
        return regex.matches(in: outputString, range: NSRange(location: 0, length: outputString.utf16.count)).compactMap { match -> String? in
            guard let version = match.captured(by: "version", in: outputString) else { return nil }
            return version
        }.first
    }
}

extension PinsStore.PinState: Codable {
    enum Key: CodingKey {
        case revision
        case branch
        case version
    }

    public func encode(to encoder: Encoder) throws {
        var versionContainer = encoder.container(keyedBy: Key.self)
        switch self {
        case .version(let version, let revision):
            try versionContainer.encode(version.description, forKey: .version)
            try versionContainer.encode(revision, forKey: .revision)
        case .revision(let revision):
            try versionContainer.encode(revision, forKey: .revision)
        case .branch(let branchName, let revision):
            try versionContainer.encode(branchName, forKey: .branch)
            try versionContainer.encode(revision, forKey: .revision)
        }
    }

    public init(from decoder: Decoder) throws {
        let decoder = try decoder.container(keyedBy: Key.self)
        if decoder.contains(.branch) {
            let branchName = try decoder.decode(String.self, forKey: .branch)
            let revision = try decoder.decode(String.self, forKey: .revision)
            self = .branch(name: branchName, revision: revision)
        } else if decoder.contains(.version) {
            let version = try decoder.decode(Version.self, forKey: .version)
            let revision = try decoder.decode(String?.self, forKey: .revision)
            self = .version(version, revision: revision)
        } else {
            let revision = try decoder.decode(String.self, forKey: .revision)
            self = .revision(revision)
        }
    }
}

extension PinsStore.PinState: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .revision(let revision):
            hasher.combine(revision)
        case .version(let version, let revision):
            hasher.combine(version)
            hasher.combine(revision)
        case .branch(let branchName, let revision):
            hasher.combine(branchName)
            hasher.combine(revision)
        }
    }
}

public struct CacheKey: Hashable, Codable, Equatable {
    var targetName: String
    var pin: PinsStore.PinState
    var buildOptions: BuildOptions
    var clangVersion: String
}

public protocol CacheStorage {
    func existsValidCache(for cacheKey: CacheKey) async -> Bool
    func fetchArtifacts(for cacheKey: CacheKey, to destinationDir: AbsolutePath) async throws
    func cacheFramework(_ frameworkPath: AbsolutePath, for cacheKey: CacheKey) async
}

struct CacheSystem {
    private let rootPackage: Package
    private let buildOptions: BuildOptions
    private let outputDirectory: AbsolutePath
    private let storage: (any CacheStorage)?
    private let fileSystem: any FileSystem

    enum Error: LocalizedError {
        case revisionNotDetected(String)
        case compilerVersionNotDetected

        var errorDescription: String? {
            switch self {
            case .revisionNotDetected(let packageName):
                return "Repository version is not detected for \(packageName)."
            case .compilerVersionNotDetected:
                return "Compiler version not detected. Please check your environment"
            }
        }
    }

    init(rootPackage: Package, buildOptions: BuildOptions, outputDirectory: AbsolutePath, storage: (any CacheStorage)?, fileSystem: FileSystem = localFileSystem) {
        self.rootPackage = rootPackage
        self.buildOptions = buildOptions
        self.outputDirectory = outputDirectory
        self.storage = storage
        self.fileSystem = fileSystem
    }

    func cacheFramework(_ frameworkPath: AbsolutePath, subPackage: ResolvedPackage, target: ResolvedTarget) async throws {
        let cacheKey = try await calculateCacheKey(package: subPackage, target: target)

        await storage?.cacheFramework(frameworkPath, for: cacheKey)
    }

    func generateVersionFile(subPackage: ResolvedPackage, target: ResolvedTarget) async throws {
        let cacheKey = try await calculateCacheKey(package: subPackage, target: target)

        let data = try jsonEncoder.encode(cacheKey)
        let versionFilePath = outputDirectory.appending(component: versionFileName(for: target.name))
        try fileSystem.writeFileContents(versionFilePath, data: data)
    }

    func existsValidCache(subPackage: ResolvedPackage, target: ResolvedTarget) async -> Bool {
        do {
            let cacheKey = try await calculateCacheKey(package: subPackage, target: target)
            let versionFilePath = versionFilePath(for: cacheKey.targetName)
            guard fileSystem.exists(versionFilePath) else { return false }
            let decoder = JSONDecoder()
            let versionFileKey = try decoder.decode(path: versionFilePath, fileSystem: fileSystem, as: CacheKey.self)
            return versionFileKey == cacheKey
        } catch {
            return false
        }
    }

    func restoreCacheIfPossible(subPackage: ResolvedPackage, target: ResolvedTarget) async -> Bool {
        guard let storage = storage else { return false }
        do {
            let cacheKey = try await calculateCacheKey(package: subPackage, target: target)
            if await storage.existsValidCache(for: cacheKey) {
                try await storage.fetchArtifacts(for: cacheKey, to: outputDirectory)
                return true
            } else {
                return false
            }
        } catch {
            return false
        }
    }

    private func fetchArtifacts(subPackage: ResolvedPackage, target: ResolvedTarget, to destination: AbsolutePath) async throws {
        guard let storage = storage else { return }
        let cacheKey = try await calculateCacheKey(package: subPackage, target: target)
        try await storage.fetchArtifacts(for: cacheKey, to: destination)
    }

    private func calculateCacheKey(package: ResolvedPackage, target: ResolvedTarget) async throws -> CacheKey {
        let targetName = target.name
        let pin = try retrievePin(package: package, target: target)
        let buildOptions = buildOptions
        guard let clangVersion = try await ClangChecker().fetchClangVersion() else { throw Error.compilerVersionNotDetected } // TODO DI
        return CacheKey(
            targetName: targetName,
            pin: pin.state,
            buildOptions: buildOptions,
            clangVersion: clangVersion
        )
    }

    private func retrievePin(package: ResolvedPackage, target: ResolvedTarget) throws -> PinsStore.Pin {
        let pinsStore = try rootPackage.workspace.pinsStore.load()
        guard let pin = pinsStore.pinsMap[package.identity] else {
            throw Error.revisionNotDetected(package.manifest.displayName)
        }
        return pin
    }

    private func versionFilePath(for targetName: String) -> AbsolutePath {
        outputDirectory.appending(component: versionFileName(for: targetName))
    }

    private func versionFileName(for targetName: String) -> String {
        ".\(targetName).version"
    }
}

extension CacheKey {
    func calculateChecksum() throws -> String {
        let data = try jsonEncoder.encode(self)
        return ByteString(data).sha256Checksum
    }
}
