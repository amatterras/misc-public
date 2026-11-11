import Flutter
import UIKit

// Hands theapp:// links (e.g. from an iOS Shortcut) to TheAppIosBridge.
// UNTESTED: written on Windows, never compiled. If Xcode reports that these
// methods do not override anything, remove the `override` keywords and the
// `super` calls.

/// A plain cover over the window while the app is really in the background
/// (the app switcher takes its picture then) and while the screen is being
/// recorded or mirrored. Screenshots cannot be prevented by any app.
///
/// The cover is NOT shown when the app is merely inactive. iOS makes an app
/// inactive for a screenshot, Control Center, the notification shade, a
/// system alert or a multitasking gesture; covering the window then made the
/// whole screen flash black for a moment on every screenshot. The picture for
/// the app switcher is only taken once the app has entered the background,
/// and the cover is put up at exactly that point.
final class PrivacyShield {
  static let shared = PrivacyShield()
  private var cover: UIView?
  private weak var scene: UIWindowScene?
  private var inBackground = false
  private var observing = false

  func attach(_ scene: UIScene) {
    guard let windowScene = scene as? UIWindowScene else { return }
    self.scene = windowScene
    guard !observing else { return }
    observing = true
    let center = NotificationCenter.default
    center.addObserver(
      forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.update() }
    // Posted synchronously during the transition, before iOS takes the
    // app-switcher picture, so the cover is in that picture.
    center.addObserver(
      forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] note in
      if let s = note.object as? UIWindowScene { self?.scene = s }
      self?.setInBackground(true)
    }
    center.addObserver(
      forName: UIScene.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.setInBackground(false) }
  }

  func setInBackground(_ value: Bool) {
    inBackground = value
    update()
  }

  private var captured: Bool { scene?.screen.isCaptured ?? false }

  private func update() {
    if inBackground || captured { show() } else { hide() }
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
    // Nothing is covered here: see PrivacyShield. (Covering on "inactive"
    // flashed the screen black on every screenshot.)
    PrivacyShield.shared.attach(scene)
    super.sceneWillResignActive(scene)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    PrivacyShield.shared.attach(scene)
    // Whatever happened before, an active app is never left covered.
    PrivacyShield.shared.setInBackground(false)
    // A new window (Stage Manager, a second scene) gets full-rate Pencil
    // capture too, once Dart has switched it on.
    TheAppIosBridge.shared.installInkObservers()
    // The same for Pencil squeeze (eraser) and double-tap (Undo): if Dart
    // asked while no window was ready, they start working now.
    TheAppIosBridge.shared.installPencilInteractions()
  }

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    // Observers are in place from the first moment, not only after the app
    // first becomes active.
    PrivacyShield.shared.attach(scene)
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
