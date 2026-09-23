import 'package:epub_image_compressor/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epub_image_compressor/utils/prefs_util.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PrefsUtil.ensureInitialized();
    await PrefsUtil().setIsFirstOpen(false);
  });

  testWidgets('显示压缩界面', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('压缩参数设置:'), findsOneWidget);
    expect(find.text('全局进度'), findsOneWidget);
  });
}
