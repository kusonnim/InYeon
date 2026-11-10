import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

abstract interface class LanguagePreference {
  Future<Locale> read();
  Future<void> write(Locale locale);
}

final class AndroidLanguagePreference implements LanguagePreference {
  const AndroidLanguagePreference();

  static const _channel = MethodChannel('com.itda.itda_mobile/local_shares');

  @override
  Future<Locale> read() async {
    try {
      if (await _channel.invokeMethod<String>('getAppLanguage') == 'en') {
        return const Locale('en');
      }
    } on PlatformException {
      // Start in the default language if the preference cannot be read.
    }
    return const Locale('ko');
  }

  @override
  Future<void> write(Locale locale) => _channel.invokeMethod<void>(
        'setAppLanguage',
        {'language': locale.languageCode},
      );
}
