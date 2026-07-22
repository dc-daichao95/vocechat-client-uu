/// Delivery state machine for outbound E2EE v2 messages.
///
/// Mirrors the Web client (Task 5) exactly so server-observed behavior is
/// consistent across platforms:
///   encrypting -> sending -> sent
///                         -> sent_waiting_key (no recipient device key yet)
///                         -> failed
///   sent_waiting_key -> sent (once every current recipient device has a
///                             completed envelope)
///
/// `local_id` is the stable outbox key; the canonical `mid` returned by the
/// server updates the same local outbox entry rather than creating a new
/// row (see [E2eOutboxEntryM]).
enum E2eDeliveryState {
  encrypting,
  sentWaitingKey,
  sending,
  sent,
  failed,
}

extension E2eDeliveryStateWire on E2eDeliveryState {
  /// Exact wire/string value shared with the server contract and Web client.
  String get wireValue {
    switch (this) {
      case E2eDeliveryState.encrypting:
        return 'encrypting';
      case E2eDeliveryState.sentWaitingKey:
        return 'sent_waiting_key';
      case E2eDeliveryState.sending:
        return 'sending';
      case E2eDeliveryState.sent:
        return 'sent';
      case E2eDeliveryState.failed:
        return 'failed';
    }
  }

  /// Terminal states no longer need background completion work.
  bool get isTerminal =>
      this == E2eDeliveryState.sent || this == E2eDeliveryState.failed;
}

E2eDeliveryState e2eDeliveryStateFromWire(String value) {
  switch (value) {
    case 'encrypting':
      return E2eDeliveryState.encrypting;
    case 'sent_waiting_key':
      return E2eDeliveryState.sentWaitingKey;
    case 'sending':
      return E2eDeliveryState.sending;
    case 'sent':
      return E2eDeliveryState.sent;
    case 'failed':
      return E2eDeliveryState.failed;
    default:
      throw ArgumentError.value(value, 'value', 'unknown delivery_state');
  }
}
