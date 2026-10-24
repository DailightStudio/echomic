// Firebase project echomic-dailight (Analytics only). iOS is configured from
// these options, so no GoogleService-Info.plist / Xcode resource is needed.
// Android reads its config from res/values/firebase.xml instead: Analytics
// only takes google_app_id from resources, and FirebaseInitProvider already
// creates the default app from them before Dart runs.
import 'package:firebase_core/firebase_core.dart';

const FirebaseOptions iosFirebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyCQX8UI0p8dOMv2iKUqNqTfEVnKQQJnSxI',
  appId: '1:820215156909:ios:75af4b29026cf8a947f624',
  messagingSenderId: '820215156909',
  projectId: 'echomic-dailight',
  storageBucket: 'echomic-dailight.firebasestorage.app',
  iosBundleId: 'com.dailightstudio.echomic',
);
