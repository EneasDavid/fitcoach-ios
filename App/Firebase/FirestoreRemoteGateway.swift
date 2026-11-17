import FirebaseFirestore
import Foundation
import SyncKit

// NOT COMPILED IN THE AUTHORING ENVIRONMENT (needs Xcode + the Firebase iOS SDK). Written against the
// Firebase iOS SDK 11.x API; see README → "Verification status".

/// Firestore implementation of `RemoteGateway`, honouring the contract in `SyncKit/RemoteGateway.swift`:
/// one transaction per mutation that (1) recognises replays by `_mutationId`, (2) enforces optimistic
/// concurrency on `_rev`, (3) writes the payload and re-stamps the server-owned bookkeeping fields.
///
/// The Firestore client is configured with a **memory-only cache** (see `AppContainer`), so the SDK's own
/// disk-backed write queue is out of the picture and `MutationQueue` is the single source of truth for pending writes.
struct FirestoreRemoteGateway: RemoteGateway {
    private let database: Firestore

    init(database: Firestore = .firestore()) {
        self.database = database
    }

    private enum Field {
        static let revision = "_rev"
        static let mutationID = "_mutationId"
        static let updatedAt = "_updatedAt"
    }

    private enum Abort {
        static let domain = "FitCoach.Sync"
        static let conflict = 1
        static let notFound = 2
    }

    func apply(_ mutation: Mutation) async throws -> RemoteApplyResult {
        let reference = database.collection(mutation.path.collection).document(mutation.path.documentID)
        let payload = FirestoreValues.encode(mutation.payload)

        do {
            let outcome = try await database.runTransaction { transaction, errorPointer -> Any? in
                let snapshot: DocumentSnapshot
                do { snapshot = try transaction.getDocument(reference) } catch let error as NSError {
                    errorPointer?.pointee = error
                    return nil
                }
                let current = (snapshot.data()?[Field.revision] as? Int) ?? 0

                if snapshot.exists, snapshot.data()?[Field.mutationID] as? String == mutation.id.uuidString {
                    return ["rev": current, "replay": true]                                  // (1) idempotent replay
                }
                if let base = mutation.baseVersion, base != current {                         // (2) optimistic concurrency
                    errorPointer?.pointee = NSError(domain: Abort.domain, code: Abort.conflict, userInfo: ["serverVersion": current])
                    return nil
                }

                let bookkeeping: [String: Any] = [
                    Field.revision: current + 1,
                    Field.mutationID: mutation.id.uuidString,
                    Field.updatedAt: FieldValue.serverTimestamp(),
                ]
                switch mutation.kind {
                case .upsert:                                                                  // (3) full replace
                    transaction.setData(payload.merging(bookkeeping) { _, new in new }, forDocument: reference)
                case .patch:
                    guard snapshot.exists else {
                        errorPointer?.pointee = NSError(domain: Abort.domain, code: Abort.notFound)
                        return nil
                    }
                    transaction.updateData(payload.merging(bookkeeping) { _, new in new }, forDocument: reference)
                case .delete:
                    guard snapshot.exists else {
                        errorPointer?.pointee = NSError(domain: Abort.domain, code: Abort.notFound)
                        return nil
                    }
                    transaction.deleteDocument(reference)
                }
                return ["rev": current + 1, "replay": false]
            }
            let result = outcome as? [String: Any]
            return RemoteApplyResult(version: result?["rev"] as? Int ?? 0, alreadyApplied: result?["replay"] as? Bool ?? false)
        } catch {
            throw Self.map(error)
        }
    }

    func fetch(_ path: DocumentPath) async throws -> RemoteDocument? {
        do {
            let snapshot = try await database.collection(path.collection).document(path.documentID).getDocument(source: .server)
            guard snapshot.exists, let data = snapshot.data() else { return nil }
            return RemoteDocument(fields: FirestoreValues.decode(data),
                                  version: data[Field.revision] as? Int ?? 0,
                                  updatedAt: (data[Field.updatedAt] as? Timestamp)?.dateValue())
        } catch {
            throw Self.map(error)
        }
    }

    /// Maps Firestore / transaction errors onto the dispatcher's failure taxonomy.
    static func map(_ error: Error) -> RemoteError {
        let nsError = error as NSError
        if nsError.domain == Abort.domain {
            switch nsError.code {
            case Abort.conflict: return .conflict(serverVersion: nsError.userInfo["serverVersion"] as? Int)
            case Abort.notFound: return .notFound
            default: break
            }
        }
        guard nsError.domain == FirestoreErrorDomain, let code = FirestoreErrorCode.Code(rawValue: nsError.code) else {
            return .transient(retryAfter: nil)
        }
        switch code {
        case .unavailable: return .offline                                   // no route to the backend: stop & probe, don't burn retries
        case .deadlineExceeded, .aborted, .internal, .dataLoss, .unknown, .cancelled: return .transient(retryAfter: nil)
        case .resourceExhausted: return .transient(retryAfter: 30)
        case .unauthenticated: return .unauthenticated
        case .permissionDenied: return .permissionDenied
        case .notFound: return .notFound
        case .invalidArgument, .failedPrecondition, .outOfRange, .alreadyExists, .unimplemented: return .invalid(nsError.localizedDescription)
        default: return .transient(retryAfter: nil)
        }
    }
}

/// `JSONValue` ⇄ Firestore value conversion (`.date` ⇄ `Timestamp`).
enum FirestoreValues {
    static func encode(_ fields: [String: JSONValue]) -> [String: Any] {
        fields.mapValues(encode)
    }

    static func encode(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(encode)
        case .object(let fields): return encode(fields)
        case .date(let date): return Timestamp(date: date)
        }
    }

    static func decode(_ data: [String: Any]) -> [String: JSONValue] {
        data.filter { !$0.key.hasPrefix("_") }.mapValues(decode)          // server bookkeeping stays out of the domain
    }

    static func decode(_ value: Any) -> JSONValue {
        switch value {
        case is NSNull: return .null
        case let timestamp as Timestamp: return .date(timestamp.dateValue())
        case let string as String: return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return CFNumberIsFloatType(number) ? .double(number.doubleValue) : .int(number.intValue)
        case let array as [Any]: return .array(array.map(decode))
        case let object as [String: Any]: return .object(object.mapValues(decode))
        default: return .null
        }
    }
}
