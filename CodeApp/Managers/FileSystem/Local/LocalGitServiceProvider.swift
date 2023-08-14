//
//  GitServiceProvider.swift
//  Code
//
//  Created by Ken Chung on 14/1/2021.
//

import Foundation
import SwiftGit2

extension Diff.Status: CaseIterable {
    public static var allCases: [SwiftGit2.Diff.Status] {
        [
            .conflicted, .current, .ignored, .indexDeleted, .indexModified, .indexNew,
            .indexRenamed, .indexTypeChange, .workTreeDeleted, .workTreeNew, .workTreeRenamed,
            .workTreeModified, .workTreeUnreadable, .workTreeTypeChange,
        ]
    }

    var allIncludedCases: [Diff.Status] {
        return Diff.Status.allCases.compactMap {
            if self.contains($0) { return $0 }
            return nil
        }
    }

    func str() -> String {
        switch self {
        case .conflicted:
            return "CONFLICTED"
        case .current:
            return "CURRENT"
        case .ignored:
            return "IGNORED"
        case .indexDeleted:
            return "INDEX_DELETED"
        case .indexModified:
            return "INDEX_MODIFIED"
        case .indexNew:
            return "INDEX_ADDED"
        case .indexRenamed:
            return "INDEX_RENAMED"
        case .indexTypeChange:
            return "INDEX_TYPE_CHANGED"
        case .workTreeDeleted:
            return "DELETED"
        case .workTreeNew:
            return "UNTRACKED"
        case .workTreeRenamed:
            return "RENAMED"
        case .workTreeModified:
            return "MODIFIED"
        case .workTreeUnreadable:
            return "UNREADABLE"
        case .workTreeTypeChange:
            return "TYPE_CHANGED"
        default:
            switch self.rawValue {
            case 257:  // Untracked -> Staged -> Modify content
                return "MODIFIED"
            case 258:  // Modified -> Staged -> Modify content
                return "MODIFIED"
            case 514:  // Untracked -> Staged -> Delete file
                return "DELETED"
            default:
                print("Unknown Status found: \(self)")
                return "UNKNOWN"
            }

        }
    }
}

class LocalGitServiceProvider: GitServiceProvider {

    private var workingURL: URL
    private var repository: Repository? = nil
    private var signature: Signature? = nil
    private var credential: Credentials? = nil
    private var contentCache = NSCache<NSString, NSString>()

    public var hasRepository: Bool {
        return repository != nil
    }
    public var requiresSignature: Bool {
        return signature == nil
    }
    private let workerQueue = DispatchQueue(label: "git.serial.queue", qos: .userInitiated)

    init(root: URL) {
        self.workingURL = root
        loadDirectory(url: root)
    }

    private func checkedRepository() throws -> Repository {
        if let repository {
            return repository
        } else {
            throw NSError(descriptionKey: "Repository doesn't exist")
        }
    }
    private func checkedSignature() throws -> Signature {
        if let signature {
            return signature
        } else {
            throw NSError(descriptionKey: "Signature is not configured")
        }
    }
    private func checkedCredentials() throws -> Credentials {
        if let credential {
            return credential
        } else {
            throw NSError(descriptionKey: "Credentials are not configured")
        }
    }
    private func WorkerQueueTask<T>(_ body: @escaping () throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            workerQueue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func loadDirectory(url: URL) {
        contentCache.removeAllObjects()

        if url.absoluteString.contains("com.apple.filesystems.smbclientd") {
            return
        }
        workingURL = url

        if let usr_name = KeychainWrapper.standard.string(forKey: "git-username"),
            let usr_pwd = KeychainWrapper.standard.string(forKey: "git-password")
        {
            credential = Credentials.plaintext(username: usr_name, password: usr_pwd)
        }

        if let usr = UserDefaults.standard.object(forKey: "user_name") as? String,
            let email = UserDefaults.standard.object(forKey: "user_email") as? String
        {
            signature = Signature(name: usr, email: email)
        }
        load()
    }

    private func load() {
        repository = nil
        let result = Repository.at(workingURL)
        switch result {
        case .success(let repo):
            repository = repo
        case .failure(let error):
            print("Could not open repository: \(error)")
        }
    }

    func isCached(url: String) -> Bool {
        guard
            let path =
                url
                .replacingOccurrences(of: workingURL.absoluteString, with: "")
                .removingPercentEncoding
        else {
            return false
        }
        return contentCache.object(forKey: path as NSString) != nil
    }

    func sign(name: String, email: String) {
        signature = Signature(name: name, email: email)
    }

    func auth(name: String, password: String) {
        credential = Credentials.plaintext(username: name, password: password)
    }

    /// Count the number of unique commits between HEAD and the specified remote
    /// If remote is nil, origin will be used
    func aheadBehind(remote: Remote?) async throws -> (Int, Int) {
        return try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            let ref = try repository.HEAD().get()
            guard let branch = ref as? Branch,
                let branchName = branch.shortName
            else {
                throw NSError(descriptionKey: "Git is in detached mode")
            }
            let remoteBranch = try repository.remoteBranch(
                named: "\(remote?.name ?? "origin")/\(branchName)"
            ).get()
            return try repository.aheadBehind(local: ref.oid, upstream: remoteBranch.oid).get()
        }
    }

    func status() async throws -> [StatusEntry] {
        return try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            return try repository.status(options: [
                .recurseUntrackedDirs, .includeIgnored, .includeUntracked, .excludeSubmodules,
            ]).get()
        }
    }

    func createRepository() async throws {
        try await WorkerQueueTask {
            guard !self.hasRepository else {
                throw NSError(descriptionKey: "Repository already exists")
            }
            self.repository = try Repository.create(at: self.workingURL).get()
        }
    }

    func clone(from: URL, to: URL, progress: Progress?) async throws {
        try await WorkerQueueTask {
            progress?.fileOperationKind = .downloading
            let checkoutProgressBlock: CheckoutProgressBlock = { (message, current, total) in
                DispatchQueue.main.async {
                    progress?.localizedDescription = "Updating files"
                    progress?.totalUnitCount = Int64(total)
                    progress?.completedUnitCount = Int64(current)
                }
            }
            let fetchProgressBlock: FetchProgressBlock = { current, total in
                DispatchQueue.main.async {
                    progress?.localizedDescription = "Receiving objects"
                    progress?.fileOperationKind = .downloading
                    progress?.totalUnitCount = Int64(total)
                    progress?.completedUnitCount = Int64(current)
                }
            }
            if let credentials = self.credential {
                _ = try Repository.clone(
                    from: from,
                    to: to,
                    credentials: credentials,
                    checkoutProgress: checkoutProgressBlock,
                    fetchProgress: fetchProgressBlock
                ).get()
            } else {
                _ = try Repository.clone(
                    from: from,
                    to: to,
                    checkoutProgress: checkoutProgressBlock,
                    fetchProgress: fetchProgressBlock
                ).get()
            }
        }
    }

    func commit(message: String) async throws {
        try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            let signature = try self.checkedSignature()
            let isMerging = repository.repositoryState().contains(.merge)
            if isMerging {
                let head = try repository.HEAD().get()
                let oids = try [head.oid] + repository.enumerateMergeHeadEntries()
                let parents = try oids.map { oid in
                    try repository.commit(oid).get()
                }
                let treeOid = try repository.writeIndexAsTree()
                _ = try repository.commit(
                    tree: treeOid, parents: parents, message: message, signature: signature
                ).get()
            } else {
                _ = try repository.commit(message: message, signature: signature).get()
            }
            self.contentCache.removeAllObjects()
        }
    }

    func unstage(paths: [String]) async throws {
        try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            try paths.forEach {
                let path = try $0.replacingOccurrences(of: self.workingURL.absoluteString, with: "")
                    .removingPercentEncoding
                try repository.unstage(path: path).get()
            }
        }
    }

    func stage(paths: [String]) async throws {
        try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            try paths.forEach {
                let path = try $0.replacingOccurrences(of: self.workingURL.absoluteString, with: "")
                    .removingPercentEncoding
                try repository.add(path: path).get()
            }
        }
    }

    /// Checkout given files at HEAD
    func checkout(paths: [String]) async throws {
        try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            try paths.forEach {
                let path =
                    try $0
                    .replacingOccurrences(of: self.workingURL.absoluteString, with: "")
                    .removingPercentEncoding
                try repository.checkout(path: path, strategy: .Force).get()
            }
        }
    }

    func remotes() async throws -> [Remote] {
        return try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            return try repository.allRemotes().get()
        }
    }

    func currentBranch() async throws -> Branch {
        try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            let head = try repository.HEAD().get()
            if let branch = head as? Branch {
                return branch
            } else {
                throw NSError(descriptionKey: "Repository is in detached mode")
            }
        }
    }

    func push(branch: Branch, remote to: Remote, progress: Progress?) async throws {
        try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            let credentials = try self.checkedCredentials()
            try repository.push(
                credentials: credentials, branch: branch.longName, remoteName: to.name
            ) { current, total in
                DispatchQueue.main.async {
                    progress?.totalUnitCount = Int64(current)
                    progress?.completedUnitCount = Int64(total)
                }
            }.get()
        }
    }

    func checkout(oid: OID) async throws {
        try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            try repository.checkout(oid, strategy: .Force).get()
            self.contentCache.removeAllObjects()
        }
    }

    func localBranches() async throws -> [Branch] {
        return try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            return try repository.localBranches().get()
        }
    }

    func remoteBranches() async throws -> [Branch] {
        return try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            return try repository.remoteBranches().get()
        }
    }

    func tags() async throws -> [TagReference] {
        return try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            return try repository.allTags().get()
        }
    }

    /// Returns the OID of the path at the current HEAD
    private func fileOidAtPathForLastCommit(path: String) throws -> OID {
        let repository = try self.checkedRepository()
        let entries = try repository.status(options: [.includeUnmodified]).get()
        print(path)
        for entry in entries {
            print(entry)
            if let oldFilePath = entry.headToIndex?.oldFile?.path,
                path == oldFilePath,
                let oid = entry.headToIndex?.oldFile?.oid
            {
                return oid
            }
        }
        throw NSError(descriptionKey: "Unable to locate OID for \(path)")
    }

    func previous(path: String) async throws -> String {
        return try await WorkerQueueTask {
            let repository = try self.checkedRepository()

            if let cached = self.contentCache.object(forKey: path as NSString) {
                return (cached as String)
            }
            let path =
                try path
                .replacingOccurrences(of: self.workingURL.absoluteString, with: "")
                .removingPercentEncoding

            let oid = try self.fileOidAtPathForLastCommit(path: path)
            let blob = try repository.blob(oid).get()

            guard let content = String(data: blob.data, encoding: .utf8) else {
                throw NSError(descriptionKey: "Unable to decode data")
            }
            self.contentCache.setObject(content as NSString, forKey: path as NSString)
            return content
        }
    }

    func pull(branch: Branch, remote from: Remote) async throws {
        try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            let credentials = try self.checkedCredentials()
            let signature = try self.checkedSignature()
            try repository.pull(
                branch: branch, from: from, credentials: credentials, signature: signature)
        }
    }

    func fetch(remote from: Remote) async throws {
        try await WorkerQueueTask {
            let repository = try self.checkedRepository()
            let credentials = try self.checkedCredentials()
            try repository.fetch(from, credentials: credentials).get()
        }
    }
}
