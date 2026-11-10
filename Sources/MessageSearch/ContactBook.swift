import Contacts
import Foundation

/// Maps the phone numbers and email addresses in chat.db to contact names.
enum ContactBook {
    /// Phone numbers compare by their last 10 digits, emails lowercased.
    static func normalize(_ id: String) -> String {
        if id.contains("@") { return id.lowercased() }
        let digits = id.filter(\.isNumber)
        return digits.count >= 7 ? String(digits.suffix(10)) : id
    }

    /// Asks for Contacts access (once) and returns normalized id -> name.
    /// Returns an empty map if access is denied; the app then shows raw ids.
    static func load(_ completion: @escaping ([String: String]) -> Void) {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { granted, _ in
            guard granted else { return completion([:]) }
            let keys = [
                CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            ] as [CNKeyDescriptor]
            var names: [String: String] = [:]
            try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                var name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                if name.isEmpty { name = contact.nickname }
                if name.isEmpty { name = contact.organizationName }
                guard !name.isEmpty else { return }
                for phone in contact.phoneNumbers { names[normalize(phone.value.stringValue)] = name }
                for email in contact.emailAddresses { names[normalize(email.value as String)] = name }
            }
            completion(names)
        }
    }
}
