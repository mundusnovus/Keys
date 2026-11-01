import AuthenticationServices
import Foundation

/// QuickType identities. Names and domains only. Passwords stay in the vault.
enum IdentityPublisher {
    static func publish(_ items: [VaultItem]) async {
        var identities: [any ASCredentialIdentity] = []
        for item in items where item.deleted == nil {
            switch item.kind {
            case .login, .password:
                let service = serviceIdentifier(for: item)
                identities.append(ASPasswordCredentialIdentity(
                    serviceIdentifier: service,
                    user: item.username,
                    recordIdentifier: item.id.uuidString
                ))
                if !item.totp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    identities.append(ASOneTimeCodeCredentialIdentity(
                        serviceIdentifier: service,
                        label: item.displayTitle,
                        recordIdentifier: item.id.uuidString
                    ))
                }
            case .code:
                guard !item.totp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                identities.append(ASOneTimeCodeCredentialIdentity(
                    serviceIdentifier: serviceIdentifier(for: item),
                    label: item.displayTitle,
                    recordIdentifier: item.id.uuidString
                ))
            case .passkey:
                guard !item.credentialID.isEmpty, !item.userHandle.isEmpty, !item.relyingParty.isEmpty else { continue }
                identities.append(ASPasskeyCredentialIdentity(
                    relyingPartyIdentifier: item.relyingParty,
                    userName: item.username,
                    credentialID: item.credentialID,
                    userHandle: item.userHandle,
                    recordIdentifier: item.id.uuidString
                ))
            default:
                break
            }
        }
        try? await ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities)
    }

    static func autofillEnabled() async -> Bool {
        await withCheckedContinuation { continuation in
            ASCredentialIdentityStore.shared.getState { state in
                continuation.resume(returning: state.isEnabled)
            }
        }
    }

    private static func serviceIdentifier(for item: VaultItem) -> ASCredentialServiceIdentifier {
        let host = item.primaryHost.isEmpty ? item.displayTitle : item.primaryHost
        return ASCredentialServiceIdentifier(identifier: host, type: .domain)
    }
}
