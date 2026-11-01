import AppKit
import AuthenticationServices
import SwiftUI

class CredentialProviderViewController: ASCredentialProviderViewController {
    private let filler = CredentialFiller()

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 420, height: 560)
        view.removeConstraints(view.constraints)
        view.subviews.forEach { $0.removeFromSuperview() }
        let picker = AutofillPicker(
            model: filler.model,
            onSelect: { [weak self] item in
                guard let self else { return }
                self.finish(self.filler.selected(item))
            },
            onCancel: { [weak self] in
                self?.cancel(nil)
            },
            onUnlock: { [weak self] in
                guard let self, let result = self.filler.afterUnlock() else { return }
                self.finish(result)
            }
        )
        let host = NSHostingController(rootView: picker)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        filler.prepareList(serviceIdentifiers, codesOnly: false)
    }

    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        filler.prepareList(serviceIdentifiers, codesOnly: true)
    }

    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        finish(filler.silent(credentialRequest, registration: false))
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        filler.prepare(credentialRequest, registration: false)
    }

    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        filler.prepare(registrationRequest, registration: true)
    }

    override func performWithoutUserInteractionIfPossible(passkeyRegistration registrationRequest: ASPasskeyCredentialRequest) {
        finish(filler.conditional(registrationRequest))
    }

    override func reportPublicKeyCredentialUpdate(forRelyingParty relyingParty: String, userHandle: Data, newName: String) {
        filler.model.renamePasskey(relyingParty: relyingParty, userHandle: userHandle, newName: newName)
    }

    override func reportUnknownPublicKeyCredential(forRelyingParty relyingParty: String, credentialID: Data) {
        filler.model.hideUnknownPasskey(relyingParty: relyingParty, credentialID: credentialID)
    }

    @IBAction func cancel(_ sender: AnyObject?) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue))
    }

    @IBAction func passwordSelected(_ sender: AnyObject?) {
        cancel(sender)
    }

    private func finish(_ result: FillResult) {
        switch result {
        case .password(let user, let password):
            let credential = ASPasswordCredential(user: user, password: password)
            extensionContext.completeRequest(withSelectedCredential: credential, completionHandler: nil)
        case .passkey(let userHandle, let party, let signature, let hash, let authenticatorData, let credentialID):
            let credential = ASPasskeyAssertionCredential(
                userHandle: userHandle,
                relyingParty: party,
                signature: signature,
                clientDataHash: hash,
                authenticatorData: authenticatorData,
                credentialID: credentialID
            )
            extensionContext.completeAssertionRequest(using: credential, completionHandler: nil)
        case .code(let code):
            extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code), completionHandler: nil)
        case .registration(let party, let hash, let credentialID, let attestation):
            let credential = ASPasskeyRegistrationCredential(
                relyingParty: party,
                clientDataHash: hash,
                credentialID: credentialID,
                attestationObject: attestation
            )
            extensionContext.completeRegistrationRequest(using: credential, completionHandler: nil)
        case .needsUI:
            extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
        case .missing:
            extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.credentialIdentityNotFound.rawValue))
        }
    }
}
