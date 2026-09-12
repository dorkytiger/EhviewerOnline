import 'package:ehviewer_online/core/service/preferences_provider.dart';
import 'package:ehviewer_online/core/service/server_address.dart';
import 'package:ehviewer_online/core/service/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 服务器地址状态的不变式。
///
/// 这一组测试来自一个真实的卡死：地址编辑最初只放在设置页，而未登录时路由把人
/// 挡在设置页之外——默认地址不对（自建服务、走隧道、局域网 IP）就等于应用完全
/// 不可用，连改的地方都找不到。所以「换地址」和「清会话」现在都由 core 承担，
/// 登录页与设置页只是它的两个入口。
void main() {
  late SharedPreferences prefs;
  late ProviderContainer container;

  Future<void> setUpContainer(Map<String, Object> initial) async {
    SharedPreferences.setMockInitialValues(initial);
    prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
  }

  test('默认地址指向回环，且没有存过值时也自洽', () async {
    await setUpContainer({});
    expect(container.read(serverAddressProvider), 'http://127.0.0.1:8080');
  });

  test('换地址会清掉属于旧服务器的会话', () async {
    await setUpContainer({'ehw_session': 'issued-by-old-server'});

    final result =
        await container.read(serverAddressProvider.notifier).set('http://new:8080');

    expect(result.isSuccess, isTrue);
    expect(container.read(serverAddressProvider), 'http://new:8080');
    // 带着旧服务器的令牌去请求新服务器只会得到一串难以解释的 401。
    expect(prefs.getString('ehw_session'), isNull);
  });

  test('地址没变就不清会话', () async {
    await setUpContainer({'ehw_session': 'keep-me'});

    // 只是重敲一遍（连尾部斜杠都一样），点一次保存就被踢回登录页是不可接受的。
    final result = await container
        .read(serverAddressProvider.notifier)
        .set('  http://127.0.0.1:8080/  ');

    expect(result.isSuccess, isTrue);
    expect(prefs.getString('ehw_session'), 'keep-me');
  });

  test('非法地址被拒，且不影响已存的地址与会话', () async {
    await setUpContainer({'ehw_session': 'keep-me'});

    for (final bad in ['', '127.0.0.1:8080', 'ftp://host', 'http://']) {
      final result =
          await container.read(serverAddressProvider.notifier).set(bad);
      expect(result.isError, isTrue, reason: '「$bad」不该被接受');
      expect(result.error?.message, '地址需要形如 http://主机:端口');
    }
    expect(container.read(serverAddressProvider), 'http://127.0.0.1:8080');
    expect(prefs.getString('ehw_session'), 'keep-me');
  });

  test('存过的地址在读取时也会被归一化', () async {
    // 旧版本或手工写入可能留下尾斜杠；读到它必须和输入时一样干净，否则
    // resolve() 会拼出 //img/...。
    await setUpContainer({'pref_base_url': 'https://example.com/  '});
    expect(container.read(serverAddressProvider), 'https://example.com');
  });

  test('会话存储只认自己的键', () async {
    await setUpContainer({'ehw_session': 'tok', 'unrelated': 'x'});
    final store = container.read(sessionStoreProvider);

    expect(store.read(), 'tok');
    expect(await store.clear(), isTrue);
    expect(store.read(), isNull);
    // 清会话不能顺手清掉别的键。
    expect(prefs.getString('unrelated'), 'x');
  });
}
