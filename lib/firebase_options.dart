// Firebase project echomic-dailight (Analytics only). Options live here, not
// in google-services.json / GoogleService-Info.plist, so neither platform
// build needs the Google Services plugin or an Xcode resource entry.
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';

FirebaseOptions get firebaseOptions => Platform.isIOS ? _ios : _android;

const FirebaseOptions _android = FirebaseOptions(
  apiKey: 'AIzaSyCUiN7HJBg6r57kEs2oE3HnLkSI0VIU-7E',
  appId: '1:820215156909:android:5c5d5ce3f3f9e49a47f624',
  messagingSenderId: '820215156909',
  projectId: 'echomic-dailight',
  storageBucket: 'echomic-dailight.firebasestorage.app',
);

const FirebaseOptions _ios = FirebaseOptions(
  apiKey: 'AIzaSyCQX8UI0p8dOMv2iKUqNqTfEVnKQQJnSxI',
  appId: '1:820215156909:ios:75af4b29026cf8a947f624',
  messagingSenderId: '820215156909',
  projectId: 'echomic-dailight',
  storageBucket: 'echomic-dailight.firebasestorage.app',
  iosBundleId: 'com.dailightstudio.echomic',
);
