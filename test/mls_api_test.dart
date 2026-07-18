import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/api/lib/mls_api.dart';

void main() {
  test('opaque artifact batches are length-delimited and ordered', () {
    final buffer = BytesBuilder();
    for (final entry in [(7, [1, 2]), (9, [3])]) {
      final header = ByteData(12)
        ..setUint64(0, entry.$1, Endian.big)
        ..setUint32(8, entry.$2.length, Endian.big);
      buffer.add(header.buffer.asUint8List());
      buffer.add(entry.$2);
    }

    final result = MlsApi.decodeBatch(buffer.takeBytes());

    expect(result.map((item) => item.sequence), [7, 9]);
    expect(result.map((item) => item.payload.toList()), [
      [1, 2],
      [3]
    ]);
  });

  test('truncated opaque artifact is rejected', () {
    expect(
      () => MlsApi.decodeBatch(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });
}
