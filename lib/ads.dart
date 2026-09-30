import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// AdMob setup: consent (UMP) first, then SDK init. Banner only — full-screen
/// formats would cut into the live mic/echo session.
class Ads {
  Ads._();

  // AdMob account pub-3035772295627652, apps "에코마이크 Android/iOS".
  static const _bannerAndroid = 'ca-app-pub-3035772295627652/2012207743';
  static const _bannerIos = 'ca-app-pub-3035772295627652/1888170381';
  static const _interstitialAndroid = 'INTERSTITIAL_ANDROID_PENDING';
  static const _interstitialIos = 'INTERSTITIAL_IOS_PENDING';
  // Google's public test units — debug builds must never request live ads.
  static const _testBannerAndroid = 'ca-app-pub-3940256099942544/9214589741';
  static const _testBannerIos = 'ca-app-pub-3940256099942544/2435281174';
  static const _testInterstitialAndroid = 'ca-app-pub-3940256099942544/1033173712';
  static const _testInterstitialIos = 'ca-app-pub-3940256099942544/4411468910';

  static String _pick(String ios, String android, String testIos, String testAndroid) =>
      kReleaseMode ? (Platform.isIOS ? ios : android) : (Platform.isIOS ? testIos : testAndroid);

  static String get bannerUnitId =>
      _pick(_bannerIos, _bannerAndroid, _testBannerIos, _testBannerAndroid);
  static String get interstitialUnitId => _pick(
      _interstitialIos, _interstitialAndroid, _testInterstitialIos, _testInterstitialAndroid);

  /// iOS never shows the ATT prompt, so ads are requested non-personalized
  /// there (no tracking to declare in the App Store privacy label).
  static AdRequest get request => AdRequest(nonPersonalizedAds: Platform.isIOS);

  static Future<void>? _ready;

  /// Idempotent. Resolves once ads may be requested (consent gathered or not
  /// required). Never throws — a consent/SDK failure just means no banner.
  static Future<void> init() => _ready ??= _init();

  static Future<void> _init() async {
    try {
      await _gatherConsent();
      if (await ConsentInformation.instance.canRequestAds()) {
        await MobileAds.instance.initialize();
      }
    } catch (e) {
      debugPrint('ads init failed: $e');
    }
  }

  static Future<void> _gatherConsent() async {
    final done = Completer<void>();
    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      () => ConsentForm.loadAndShowConsentFormIfRequired((_) => done.complete()),
      (_) => done.complete(),
    );
    return done.future;
  }
}

/// Anchored adaptive banner pinned under the Start button. Takes no space
/// until an ad has loaded, so a failed load leaves the layout unchanged.
class AdBanner extends StatefulWidget {
  const AdBanner({super.key});

  @override
  State<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<AdBanner> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ad == null) _load();
  }

  Future<void> _load() async {
    final width = MediaQuery.of(context).size.width.truncate();
    await Ads.init();
    if (!mounted || !await ConsentInformation.instance.canRequestAds()) return;
    final size = await AdSize.getLargeAnchoredAdaptiveBannerAdSize(width);
    if (!mounted || size == null) return;
    _ad = BannerAd(
      adUnitId: Ads.bannerUnitId,
      size: size,
      request: Ads.request,
      listener: BannerAdListener(
        onAdLoaded: (_) => mounted ? setState(() => _loaded = true) : null,
        onAdFailedToLoad: (ad, err) {
          debugPrint('banner failed: $err');
          ad.dispose();
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (!_loaded || ad == null) return const SizedBox.shrink();
    return SizedBox(
      width: ad.size.width.toDouble(),
      height: ad.size.height.toDouble(),
      child: AdWidget(ad: ad),
    );
  }
}

/// Full-screen ad at a natural break: right after the user stops singing.
/// Never mid-session. Only after a real session and at most once per [_minGap],
/// so a quick start/stop to tweak settings does not trigger it.
class StopInterstitial {
  StopInterstitial._();

  static const _minSession = Duration(seconds: 60);
  static const _minGap = Duration(minutes: 3);

  static InterstitialAd? _ad;
  static bool _loading = false;
  static DateTime? _lastShown;

  static Future<void> preload() async {
    if (_ad != null || _loading) return;
    await Ads.init();
    if (!await ConsentInformation.instance.canRequestAds()) return;
    _loading = true;
    await InterstitialAd.load(
      adUnitId: Ads.interstitialUnitId,
      request: Ads.request,
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _loading = false;
          _ad = ad;
        },
        onAdFailedToLoad: (err) {
          _loading = false;
          debugPrint('interstitial failed: $err');
        },
      ),
    );
  }

  /// Call after the audio engine has stopped.
  static void maybeShow(Duration session) {
    final ad = _ad;
    final last = _lastShown;
    if (ad == null ||
        session < _minSession ||
        (last != null && DateTime.now().difference(last) < _minGap)) {
      if (ad == null) preload();
      return;
    }
    _ad = null;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        preload();
      },
      onAdFailedToShowFullScreenContent: (ad, err) {
        ad.dispose();
        preload();
      },
    );
    _lastShown = DateTime.now();
    ad.show();
  }
}
