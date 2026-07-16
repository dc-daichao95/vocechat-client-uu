import 'package:json_annotation/json_annotation.dart';
import 'package:vocechat_client/api/models/admin/login/oidc_info.dart';

part 'login_config.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class AdminLoginConfig {
  String whoCanSignUp;
  bool password;
  bool magicLink;
  bool google;
  bool github;
  List<OidcInfo> oidc;
  bool metamask;
  bool thirdParty;
  bool? e2eAvailable;
  bool? e2eDefaultOn;
  int? e2eProtocolVer;

  AdminLoginConfig(
      {required this.whoCanSignUp,
      required this.password,
      required this.magicLink,
      required this.google,
      required this.github,
      required this.oidc,
      required this.metamask,
      required this.thirdParty,
      this.e2eAvailable,
      this.e2eDefaultOn,
      this.e2eProtocolVer});

  factory AdminLoginConfig.fromJson(Map<String, dynamic> json) =>
      _$AdminLoginConfigFromJson(json);

  Map<String, dynamic> toJson() => _$AdminLoginConfigToJson(this);
}
