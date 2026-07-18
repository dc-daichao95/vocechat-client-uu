class ConversationTarget {
  final int? uid;
  final int? gid;
  final int mid;

  ConversationTarget.group({required int gid, required this.mid})
      : uid = null,
        gid = _positive(gid, 'gid') {
    _positive(mid, 'mid');
  }

  ConversationTarget.direct({required int uid, required this.mid})
      : uid = _positive(uid, 'uid'),
        gid = null {
    _positive(mid, 'mid');
  }

  static int _positive(int value, String name) {
    if (value <= 0) {
      throw ArgumentError.value(value, name, 'must be positive');
    }
    return value;
  }
}
