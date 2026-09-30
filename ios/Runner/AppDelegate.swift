import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        configureGoogleMobileAdsAudioSession()
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration",
                             sessionRole: connectingSceneSession.role)
    }

    /// Tells the Google Mobile Ads SDK that *our* AVAudioSession management
    /// is authoritative, not its own. By default GMA sets the session to
    /// Ambient/SoloAmbient around ad video playback, which can stop the
    /// other app's music (Melon/YouTube) or silence our own engine. Looked
    /// up purely via the Objective-C runtime -- no compile-time dependency
    /// on GoogleMobileAds, so this still builds if the pod isn't present.
    private func configureGoogleMobileAdsAudioSession() {
        guard let adsClassAny = NSClassFromString("GADMobileAds") else { return }
        let adsClass = adsClassAny as AnyObject

        let sharedInstanceSel = Selector(("sharedInstance"))
        guard adsClass.responds(to: sharedInstanceSel) else { return }
        guard let sharedUnmanaged = adsClass.perform(sharedInstanceSel) else { return }
        let shared = sharedUnmanaged.takeUnretainedValue()

        let audioVideoManagerSel = Selector(("audioVideoManager"))
        guard shared.responds(to: audioVideoManagerSel) else { return }
        guard let managerAny = shared.value(forKey: "audioVideoManager") as AnyObject? else { return }

        let setManagedSel = NSSelectorFromString("setAudioSessionIsApplicationManaged:")
        guard managerAny.responds(to: setManagedSel) else { return }
        managerAny.setValue(true, forKey: "audioSessionIsApplicationManaged")
    }
}
