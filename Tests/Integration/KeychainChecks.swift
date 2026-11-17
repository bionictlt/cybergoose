import Foundation

@main
struct KeychainChecks {
    static func main() {
        do { try check() }
        catch { print("Keychain check failed: \(error.localizedDescription)"); exit(1) }
    }
    static func check() throws {
        let id = "disposable-check-\(UUID())"
        let store = CredentialStore()
        defer { try? store.delete(id) }
        print("Checking missing item")
        let missing = try store.read(id)
        precondition(missing == nil)
        print("Creating disposable item")
        try store.save("temporary-test-secret", id: id)
        let first = try store.read(id)
        precondition(first == "temporary-test-secret")
        try store.save("updated-test-secret", id: id)
        let updated = try store.read(id)
        precondition(updated == "updated-test-secret")
        try store.delete(id)
        let removed = try store.read(id)
        precondition(removed == nil)
        print("Passed: Keychain missing/create/read/update/delete (disposable item removed)")
    }
}
