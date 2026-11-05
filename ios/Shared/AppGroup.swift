//
//  AppGroup.swift
//
//  Compiled into ALL THREE targets (Runner, ShareExtension, TheAppWidget), so
//  the app, the Share Extension and the widgets always agree on one App Group
//  folder.
//
//  Why this exists: the project declares `group.com.theapp.shared` in all three
//  .entitlements files, and a build signed with the Apple Developer Program
//  (the `ios-signed` workflow) really has that group. A free-Apple-ID sideloader
//  does not keep it: it re-signs the app and gives every target a group of its
//  own making, for example `group.<new bundle id>.<team id>`. Asking for the
//  fixed name then fails and the Share Extension reported "App Group missing"
//  even though the install did have an App Group.
//
//  The system itself decides which names this install may use:
//  containerURL(forSecurityApplicationGroupIdentifier:) returns nil for a group
//  the signature does not grant. So this tries the plausible names, in a fixed
//  order, and takes the first the system accepts. If it accepts none, nothing
//  is faked: `container` stays nil and callers report the error, now with the
//  names that were tried.
//
import Foundation

enum AppGroup {
  /// The group the project declares in the .entitlements files.
  static let declared = "group.com.theapp.shared"

  /// Appears in every summary (and so in the binary, which the build checks).
  static let tag = "THEAPP-APPGROUP-RESOLVER-1"

  struct Resolution {
    /// The group the system accepted, or nil.
    let identifier: String?
    /// Its shared folder, or nil.
    let container: URL?
    /// Where the accepted name came from (see `candidates`), or "none".
    let source: String
    /// Every name that was asked for, in order.
    let tried: [String]
    /// The app that hosts this process (the app itself, or the app that
    /// contains this extension).
    let hostBundleId: String
    /// Whether the host app has an embedded provisioning profile.
    let hasProfile: Bool

    /// One line for logs and for the Share Extension's error text.
    var summary: String {
      if let identifier = identifier {
        return "\(AppGroup.tag) App Group \(identifier) (\(source))"
      }
      return "\(AppGroup.tag) no App Group available; asked for: \(tried.joined(separator: ", ")); "
        + "app: \(hostBundleId); profile: \(hasProfile ? "yes" : "no")"
    }
  }

  /// Worked out once per process.
  static let resolution: Resolution = resolve()

  /// The shared folder, or nil when this install has no usable App Group.
  static var container: URL? { resolution.container }

  // MARK: resolving

  /// The app that contains this process: itself, or, for an extension
  /// (`Runner.app/PlugIns/X.appex`), the app that holds it.
  private static var hostBundle: Bundle {
    let main = Bundle.main
    if main.bundleURL.pathExtension == "appex" {
      let app = main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
      if let host = Bundle(url: app) { return host }
    }
    return main
  }

  /// The entitlements and team of the host app's embedded provisioning
  /// profile, if it has one (sideloaded and ad hoc builds do; the profile is a
  /// signed file with a plain property list inside it).
  private static func profileInfo(of bundle: Bundle) -> (groups: [String], teams: [String])? {
    guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Data(contentsOf: url),
      let start = data.range(of: Data("<?xml".utf8)),
      let end = data.range(
        of: Data("</plist>".utf8), options: [], in: start.lowerBound..<data.endIndex)
    else { return nil }
    let xml = data.subdata(in: start.lowerBound..<end.upperBound)
    guard
      let plist = try? PropertyListSerialization.propertyList(
        from: xml, options: [], format: nil) as? [String: Any]
    else { return nil }
    let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
    let groups = entitlements["com.apple.security.application-groups"] as? [String] ?? []
    let teams = plist["TeamIdentifier"] as? [String] ?? []
    return (groups, teams)
  }

  private static func resolve() -> Resolution {
    let host = hostBundle
    let hostId = host.bundleIdentifier ?? ""
    let profile = profileInfo(of: host)

    // (name, where it came from), in the order they are tried.
    var candidates: [(String, String)] = []
    func add(_ name: String, _ source: String) {
      if !name.isEmpty && !candidates.contains(where: { $0.0 == name }) {
        candidates.append((name, source))
      }
    }

    // 1. The declared group: a build signed with the Developer Program.
    add(declared, "declared")
    // 2. Groups a sideloader wrote into the app (AltStore/SideStore style).
    for name in host.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? [] {
      add(name, "ALTAppGroups")
    }
    // 3. Groups the provisioning profile granted this install.
    for name in profile?.groups ?? [] {
      add(name, "profile")
    }
    // 4. What iLoader-style signing makes: "group." + the re-signed bundle id.
    if !hostId.isEmpty {
      add("group." + hostId, "bundle id")
    }
    // 5. The declared name with the team id appended.
    for team in profile?.teams ?? [] {
      add(declared + "." + team, "declared + team")
    }

    var tried: [String] = []
    for (name, source) in candidates {
      tried.append(name)
      if let folder = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: name)
      {
        return Resolution(
          identifier: name, container: folder, source: source, tried: tried,
          hostBundleId: hostId, hasProfile: profile != nil)
      }
    }
    // Nothing the system accepts: say so in the log of whichever target this
    // is (the app, the Share Extension or a widget), with what was asked for.
    NSLog("\(tag) no App Group; asked for: \(tried.joined(separator: ", ")); app: \(hostId)")
    return Resolution(
      identifier: nil, container: nil, source: "none", tried: tried,
      hostBundleId: hostId, hasProfile: profile != nil)
  }
}
