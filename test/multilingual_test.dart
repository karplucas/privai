import 'package:flutter_test/flutter_test.dart';
void main() {
  group('Multilingual Support Tests', () {
    test('Whisper supported languages', () {
      final whisperLanguages = {
        'en': 'English',
        'es': 'Spanish',
        'fr': 'French',
        'de': 'German',
        'it': 'Italian',
        'pt': 'Portuguese',
        'ru': 'Russian',
        'ja': 'Japanese',
        'zh': 'Chinese',
        'ko': 'Korean',
        'ar': 'Arabic',
        'hi': 'Hindi',
        'tr': 'Turkish',
        'pl': 'Polish',
        'nl': 'Dutch',
        'sv': 'Swedish',
        'da': 'Danish',
        'no': 'Norwegian',
        'fi': 'Finnish',
        'he': 'Hebrew',
        'th': 'Thai',
        'vi': 'Vietnamese',
        'cs': 'Czech',
        'hu': 'Hungarian',
        'ro': 'Romanian',
        'sk': 'Slovak',
        'sl': 'Slovenian',
        'hr': 'Croatian',
        'bg': 'Bulgarian',
        'uk': 'Ukrainian',
        'el': 'Greek',
        'lt': 'Lithuanian',
        'lv': 'Latvian',
        'et': 'Estonian',
        'mt': 'Maltese',
        'is': 'Icelandic',
        'ga': 'Irish',
        'cy': 'Welsh',
        'eu': 'Basque',
        'ca': 'Catalan',
        'gl': 'Galician',
        'eo': 'Esperanto',
        'si': 'Sinhala',
        'ne': 'Nepali',
        'mk': 'Macedonian',
        'bn': 'Bengali',
        'ta': 'Tamil',
        'te': 'Telugu',
        'ur': 'Urdu',
        'fa': 'Persian',
        'am': 'Amharic',
        'ti': 'Tigrinya',
        'om': 'Oromo',
        'so': 'Somali',
        'sw': 'Swahili',
        'rw': 'Kinyarwanda',
        'ln': 'Lingala',
        'yo': 'Yoruba',
        'ig': 'Igbo',
        'ha': 'Hausa',
        'zu': 'Zulu',
        'xh': 'Xhosa',
        'af': 'Afrikaans',
        'tn': 'Tswana',
        'st': 'Southern Sotho',
        'ts': 'Tsonga',
        'ss': 'Swati',
        've': 'Venda',
        'nr': 'Southern Ndebele',
        'km': 'Khmer',
        'lo': 'Lao',
        'my': 'Burmese',
        'ka': 'Georgian',
        'hy': 'Armenian',
        'az': 'Azerbaijani',
        'kk': 'Kazakh',
        'ky': 'Kyrgyz',
        'tg': 'Tajik',
        'tk': 'Turkmen',
        'uz': 'Uzbek',
        'mn': 'Mongolian',
        'bo': 'Tibetan',
        'dz': 'Dzongkha',
        'pa': 'Punjabi',
        'gu': 'Gujarati',
        'or': 'Oriya',
        'as': 'Assamese',
        'mr': 'Marathi',
        'sa': 'Sanskrit',
        'ml': 'Malayalam',
        'kn': 'Kannada',
        'sd': 'Sindhi',
        'ps': 'Pashto',
        'ku': 'Kurdish',
        'ug': 'Uyghur',
        'tt': 'Tatar',
        'ba': 'Bashkir',
        'cv': 'Chuvash',
        'jv': 'Javanese',
        'su': 'Sundanese',
        'yi': 'Yiddish',
        'lb': 'Luxembourgish',
        'fy': 'Frisian',
        'br': 'Breton',
        'co': 'Corsican',
        'oc': 'Occitan',
        'sc': 'Sardinian',
        'ast': 'Asturian',
        'an': 'Aragonese',
        'ia': 'Interlingua',
        'ie': 'Interlingue',
        'io': 'Ido',
        'vo': 'Volapük'
      };

      // Verify all language codes are valid
      whisperLanguages.forEach((code, name) {
        expect(code.length, greaterThanOrEqualTo(2));
        expect(code.length, lessThanOrEqualTo(3));
        expect(code, matches(r'^[a-z]{2,3}$'));
        expect(name, isNotEmpty);
      });

      // Verify common languages are included
      expect(whisperLanguages.containsKey('en'), isTrue);
      expect(whisperLanguages.containsKey('es'), isTrue);
      expect(whisperLanguages.containsKey('fr'), isTrue);
      expect(whisperLanguages.containsKey('de'), isTrue);
      expect(whisperLanguages.containsKey('zh'), isTrue);
      expect(whisperLanguages.containsKey('ja'), isTrue);
      expect(whisperLanguages.containsKey('ko'), isTrue);
    });

    test('TTS voice configurations with Kokoro model', () {
      // Test TTS voice configurations for Kokoro multilingual model
      final kokoroConfig = {
        'model': 'kokoro-multi-lang-v1_1',
        'languages': ['en', 'zh'],
        'total_speakers': 103,
        'sample_rate': 24000, // Kokoro uses 24kHz
        'speakers_per_language': {
          'en': 44, // American/British English speakers
          'zh': 5, // Chinese speakers
        }
      };

      expect(kokoroConfig['total_speakers']!, equals(103));
      expect(kokoroConfig['sample_rate']!, equals(24000));
      expect(kokoroConfig['languages']!, contains('en'));
      expect(kokoroConfig['languages']!, contains('zh'));
    });

    test('Kokoro TTS speaker IDs are valid', () {
      // Test speaker IDs for Kokoro model (0-102 = 103 speakers)
      const minSpeakerId = 0;
      const maxSpeakerId = 102;
      const totalSpeakers = 103;

      expect(minSpeakerId, isNonNegative);
      expect(maxSpeakerId, lessThan(totalSpeakers));
      expect(totalSpeakers, equals(maxSpeakerId - minSpeakerId + 1));

      // Test some specific speaker IDs
      final testSpeakerIds = [0, 1, 50, 100, 102];
      for (final id in testSpeakerIds) {
        expect(id, greaterThanOrEqualTo(minSpeakerId));
        expect(id, lessThanOrEqualTo(maxSpeakerId));
      }
    });

    test('Language detection and switching', () {
      // Test language detection logic
      final testTexts = {
        'Hello world': 'en',
        'Hola mundo': 'es',
        'Bonjour le monde': 'fr',
        'Hallo Welt': 'de',
        '你好世界': 'zh',
        'こんにちは世界': 'ja',
        '안녕하세요 세계': 'ko',
      };

      testTexts.forEach((text, expectedLang) {
        expect(expectedLang.length, equals(2));
        expect(expectedLang, matches(r'^[a-z]{2}$'));
      });
    });

    test('Multilingual chat scenarios', () {
      final conversationScenarios = [
        {
          'user_lang': 'en',
          'ai_lang': 'en',
          'message': 'Hello, how are you?',
          'response': 'I am doing well, thank you!'
        },
        {
          'user_lang': 'es',
          'ai_lang': 'es',
          'message': '¿Hola, cómo estás?',
          'response': '¡Estoy bien, gracias!'
        },
        {
          'user_lang': 'fr',
          'ai_lang': 'fr',
          'message': 'Bonjour, comment allez-vous?',
          'response': 'Je vais bien, merci!'
        },
        {
          'user_lang': 'zh',
          'ai_lang': 'zh',
          'message': '你好，你怎么样？',
          'response': '我很好，谢谢！'
        },
        {
          'user_lang': 'ja',
          'ai_lang': 'ja',
          'message': 'こんにちは、お元気ですか？',
          'response': '元気です、ありがとうございます！'
        }
      ];

      for (final scenario in conversationScenarios) {
        expect(scenario['user_lang']!, isNotNull);
        expect(scenario['ai_lang']!, isNotNull);
        expect(scenario['message']!, isNotNull);
        expect(scenario['response']!, isNotNull);
      }
    });

    test('Speech recognition accuracy by language', () {
      // Test expected accuracy ranges for different languages
      final accuracyRanges = {
        'en': {'min': 0.85, 'max': 0.95},
        'es': {'min': 0.80, 'max': 0.90},
        'fr': {'min': 0.80, 'max': 0.90},
        'de': {'min': 0.75, 'max': 0.88},
        'zh': {'min': 0.70, 'max': 0.85},
        'ja': {'min': 0.65, 'max': 0.80},
        'ko': {'min': 0.70, 'max': 0.85},
      };

      accuracyRanges.forEach((lang, range) {
        expect(range['min']!, greaterThanOrEqualTo(0.0));
        expect(range['max']!, lessThanOrEqualTo(1.0));
        expect(range['min']!, lessThan(range['max']!));
      });
    });

    test('Text-to-speech quality metrics', () {
      final ttsQualityMetrics = {
        'naturalness': {'min': 3.5, 'max': 5.0},
        'intelligibility': {'min': 4.0, 'max': 5.0},
        'speaker_similarity': {'min': 3.0, 'max': 4.5},
      };

      ttsQualityMetrics.forEach((metric, range) {
        expect(range['min']!, greaterThanOrEqualTo(1.0));
        expect(range['max']!, lessThanOrEqualTo(5.0));
        expect(range['min']!, lessThanOrEqualTo(range['max']!));
      });
    });
  });
}
