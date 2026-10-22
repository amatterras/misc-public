import Flutter
import UIKit

// Hands theapp:// links (e.g. from an iOS Shortcut) to TheAppIosBridge.
// UNTESTED: written on Windows, never compiled. If Xcode reports that these
// methods do not override anything, remove the `override` keywords and the
// `super` calls.
class SceneDelegate: FlutterSceneDelegate {
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
