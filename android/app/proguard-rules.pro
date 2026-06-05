# JNI 브릿지 — R8이 rename/strip하면 NoSuchMethodError 발생
-keep class com.dailightstudio.echomic.AudioEnginePlugin { *; }
-keepclasseswithmembernames class * { native <methods>; }
