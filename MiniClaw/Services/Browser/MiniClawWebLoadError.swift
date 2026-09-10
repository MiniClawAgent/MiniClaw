//
// MiniClawWebLoadError.swift
// MiniClaw
//
// Shared Safari-style error model + overlay for the
// built-in WKWebViews. When a page fails to load (DNS not found, host
// unreachable, offline, timeout, TLS error, …) WKWebView is left showing a
// blank white/black page with no indication of what happened. This gives all
// three built-in web surfaces (chat link preview, markdown link preview, and
// the agent browser) a consistent icon + short message + Retry, mirroring what
// Safari shows.
//

import Foundation
import SwiftUI
import WebKit

public struct MiniClawWebLoadError: Equatable {
    public let title: String
    public let message: String
    public let systemImage: String
    public let failedURL: URL?

    public init?(error: Error,failedURL: URL? = nil) {
        let ns = error as NSError

        if ns.domain == NSURLErrorDomain,ns.code == NSURLErrorCancelled { return nil }
        if ns.domain == WKError.errorDomain,ns.code == 102 { return nil }

        let urlFromError = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        self.failedURL = urlFromError ?? failedURL

        let host = self.failedURL?.host
        switch (ns.domain,ns.code) {
        case (NSURLErrorDomain,NSURLErrorCannotFindHost),
             (NSURLErrorDomain,NSURLErrorDNSLookupFailed):
            title = String(localized: "Cannot Open Page")
            message = host.map {
                String(localized: "MiniClaw can’t open the page because it can’t find the server “\($0)”.")
            } ?? String(localized: "MiniClaw can’t open the page because it can’t find the server.")
            systemImage = "wifi.exclamationmark"

        case (NSURLErrorDomain,NSURLErrorCannotConnectToHost):
            title = String(localized: "Cannot Open Page")
            message = String(localized: "MiniClaw can’t open the page because it can’t connect to the server.")
            systemImage = "wifi.exclamationmark"

        case (NSURLErrorDomain,NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain,NSURLErrorNetworkConnectionLost),
             (NSURLErrorDomain,NSURLErrorInternationalRoamingOff),
             (NSURLErrorDomain,NSURLErrorDataNotAllowed):
            title = String(localized: "You Are Not Connected to the Internet")
            message = String(localized: "The page couldn’t load because you’re not connected to the internet.")
            systemImage = "wifi.slash"

        case (NSURLErrorDomain,NSURLErrorTimedOut):
            title = String(localized: "The Connection Timed Out")
            message = host.map {
                String(localized: "The server “\($0)” took too long to respond.")
            } ?? String(localized: "The server took too long to respond.")
            systemImage = "clock.badge.exclamationmark"

        case (NSURLErrorDomain,NSURLErrorSecureConnectionFailed),
             (NSURLErrorDomain,NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain,NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain,NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain,NSURLErrorServerCertificateNotYetValid),
             (NSURLErrorDomain,NSURLErrorClientCertificateRejected),
             (NSURLErrorDomain,NSURLErrorClientCertificateRequired):
            title = String(localized: "This Connection Is Not Private")
            message = host.map {
                String(localized: "MiniClaw can’t verify the identity of the server “\($0)”.")
            } ?? String(localized: "MiniClaw can’t verify the identity of the server.")
            systemImage = "lock.slash"

        case (NSURLErrorDomain,NSURLErrorUnsupportedURL),
             (NSURLErrorDomain,NSURLErrorBadURL):
            title = String(localized: "Cannot Open Page")
            message = String(localized: "The address isn’t valid.")
            systemImage = "exclamationmark.triangle"

        default:
            title = String(localized: "Cannot Open Page")
            message = host.map {
                String(localized: "A problem occurred loading “\($0)”.")
            } ?? String(localized: "A problem occurred while loading this page.")
            systemImage = "exclamationmark.triangle"
        }
    }
}

public struct MiniClawWebLoadErrorOverlay: View {
    public let error: MiniClawWebLoadError
    public let onRetry: () -> Void

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: error.systemImage)
                .font(.system(size: 44,weight: .regular))
                .foregroundStyle(.secondary)
            Text(error.title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(error.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false,vertical: true)
            Button(action: onRetry) {
                Label(String(localized: "Try Again"), systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top,2)
        }
        .padding(28)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity,maxHeight: .infinity)
        .background(.background)
    }
}
