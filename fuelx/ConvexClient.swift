//
//  ConvexClient.swift
//  fuelx
//
//  Created by Thibault Henry on 31/10/2026.
//

import ConvexMobile
import Foundation

enum ConvexConfig {
  /// `CONVEX_URL` from .env.local (dev deployment).
  static let deploymentURL = "https://elated-vulture-953.convex.cloud"
  /// `CONVEX_SITE_URL` from .env.local. Better Auth is served from here.
  static let siteURL = URL(string: "https://elated-vulture-953.convex.site")!
}

let betterAuth = BetterAuthAPI(siteURL: ConvexConfig.siteURL)

let convex = ConvexClientWithAuth(
  deploymentUrl: ConvexConfig.deploymentURL,
  authProvider: BetterAuthProvider(api: betterAuth)
)
