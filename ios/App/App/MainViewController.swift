//
//  MainViewController.swift
//  App — registers the app-local WhispersBilling plugin (Capacitor 8 has no
//  auto-registration for plugins living inside the app target).
//

import UIKit
import Capacitor

class MainViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(WhispersBillingPlugin())
    }
}
