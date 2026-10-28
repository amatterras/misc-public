import Flutter
import UIKit

// Hands theapp:// links (e.g. from an iOS Shortcut) to TheAppIosBridge.
// UNTESTED: written on Windows, never compiled. If Xcode reports that these
// methods do not override anything, remove the `override` keywords and the
// `super` calls.
/// A plain cover over the window while the app is inactive (the app
/// switcher takes its picture then) and while the screen is being recorded
/// or mirrored. Screenshots cannot be prevented by any app.
final class PrivacyShield {
  static let shared = PrivacyShield()
  private var cover: UIView?
  private weak var scene: UIWindowScene?
  private var active = true

  func attach(_ scene: UIScene) {
    guard let windowScene = scene as? UIWindowScene, self.scene == nil else { return }
    self.scene = windowScene
    NotificationCenter.default.addObserver(
      forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.update() }
  }

  func setActive(_ active: Bool) {
    self.active = active
    update()
  }

  private var captured: Bool { scene?.screen.isCaptured ?? false }

  private func update() {
    if !active || captured { show() } else { hide() }
  }

  private func show() {
    guard cover == nil,
      let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
    else { return }
    let view = UIView(frame: window.bounds)
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.backgroundColor = .systemBackground
    window.addSubview(view)
    cover = view
  }

  private func hide() {
    cover?.removeFromSuperview()
    cover = nil
  }
}

class SceneDelegate: FlutterSceneDelegate {
  override func sceneWillResignActive(_ scene: UIScene) {
    PrivacyShield.shared.attach(scene)
    PrivacyShield.shared.setActive(false)
    super.sceneWillResignActive(scene)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    PrivacyShield.shared.attach(scene)
    PrivacyShield.shared.setActive(true)
  }

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts {
      TheAppIosBridge.shared.received(url: context.url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts {
      TheAppIosBridge.shared.received(url: context.url)
    }
  }
}
