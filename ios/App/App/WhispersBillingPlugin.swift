//
//  WhispersBillingPlugin.swift
//  App — Masked Whispers 3.1.0 (iOS twin of the Android WhispersBillingPlugin)
//
//  StoreKit 2 subscriptions. Mirrors the Android plugin's JS contract so the
//  site-side billing bridge can call the same methods on both platforms:
//    purchase({productId})    -> { ok, productId, purchaseToken(JWS), transactionId, ... }
//    listPurchases()          -> { purchases: [...] }
//    openManage()             -> { ok }
//  "purchaseToken" carries the signed-transaction JWS so the server can
//  verify it with Apple's App Store Server API (TM_Apple_Billing).
//

import Foundation
import UIKit
import Capacitor
import StoreKit

@objc(WhispersBillingPlugin)
public class WhispersBillingPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "WhispersBillingPlugin"
    public let jsName = "WhispersBilling"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "purchase", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "listPurchases", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openManage", returnType: CAPPluginReturnPromise)
    ]

    private var updatesTask: Task<Void, Never>? = nil

    public override func load() {
        // Drain Transaction.updates so renewals / interrupted purchases are
        // finished even when they complete outside an active purchase() call.
        updatesTask = Task.detached {
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    @objc func purchase(_ call: CAPPluginCall) {
        guard let productId = call.getString("productId"), !productId.isEmpty else {
            call.reject("productId required")
            return
        }
        Task {
            do {
                let products = try await Product.products(for: [productId])
                guard let product = products.first else {
                    call.reject("Product not found in App Store Connect: " + productId)
                    return
                }
                let result = try await product.purchase()
                switch result {
                case .success(let verification):
                    switch verification {
                    case .verified(let transaction):
                        await transaction.finish()
                        call.resolve([
                            "ok": true,
                            "productId": productId,
                            "basePlanId": "",
                            "purchaseToken": verification.jwsRepresentation,
                            "transactionId": String(transaction.id),
                            "originalTransactionId": String(transaction.originalID),
                            "isAcknowledged": true
                        ])
                    case .unverified(_, let error):
                        call.reject("Purchase could not be verified: \(error.localizedDescription)")
                    }
                case .userCancelled:
                    call.reject("USER_CANCELED")
                case .pending:
                    call.reject("PENDING")
                @unknown default:
                    call.reject("Unknown purchase result")
                }
            } catch {
                call.reject("Purchase failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func listPurchases(_ call: CAPPluginCall) {
        Task {
            var purchases: [[String: Any]] = []
            for await entitlement in Transaction.currentEntitlements {
                if case .verified(let transaction) = entitlement {
                    purchases.append([
                        "productId": transaction.productID,
                        "purchaseToken": entitlement.jwsRepresentation,
                        "transactionId": String(transaction.id),
                        "originalTransactionId": String(transaction.originalID),
                        "isAcknowledged": true,
                        "isAutoRenewing": transaction.expirationDate != nil,
                        "purchaseTime": Int(transaction.purchaseDate.timeIntervalSince1970 * 1000)
                    ])
                }
            }
            call.resolve(["purchases": purchases])
        }
    }

    @objc func openManage(_ call: CAPPluginCall) {
        Task { @MainActor in
            if let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                try? await AppStore.showManageSubscriptions(in: scene)
                call.resolve(["ok": true])
            } else if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                await UIApplication.shared.open(url)
                call.resolve(["ok": true])
            } else {
                call.reject("Unable to open subscription management")
            }
        }
    }
}
