import Flutter
import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let engine = FlutterEngine(name: "main_engine")
        engine.run()

        GeneratedPluginRegistrant.register(with: engine)
        if let registrar = engine.registrar(forPlugin: "AudioEnginePlugin") {
            AudioEnginePlugin.register(with: registrar.messenger())
        }

        let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        self.window = window
        window.makeKeyAndVisible()
    }
}
