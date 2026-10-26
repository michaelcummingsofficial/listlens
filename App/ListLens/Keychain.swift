import Foundation
import Security

/// Stores the Meta Model API key on the phone, outside the app's preferences.
enum Keychain {
	private static let service = "fun.displaylist.listlens"

	static func read(_ account: String) -> String? {
		let query: [CFString: Any] = [
			kSecClass: kSecClassGenericPassword,
			kSecAttrService: service,
			kSecAttrAccount: account,
			kSecReturnData: true
		]
		var result: AnyObject?
		guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
			return nil
		}
		return String(data: data, encoding: .utf8)
	}

	static func write(_ value: String, for account: String) {
		let query: [CFString: Any] = [
			kSecClass: kSecClassGenericPassword,
			kSecAttrService: service,
			kSecAttrAccount: account
		]
		SecItemDelete(query as CFDictionary)
		guard !value.isEmpty else {
			return
		}
		var item = query
		item[kSecValueData] = Data(value.utf8)
		item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
		SecItemAdd(item as CFDictionary, nil)
	}
}
