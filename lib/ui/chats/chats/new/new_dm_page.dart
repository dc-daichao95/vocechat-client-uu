import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:vocechat_client/app_consts.dart';
import 'package:vocechat_client/dao/init_dao/user_info.dart';
import 'package:vocechat_client/shared_funcs.dart';
import 'package:vocechat_client/ui/app_colors.dart';
import 'package:vocechat_client/ui/app_text_styles.dart';
import 'package:vocechat_client/ui/contact/contacts_add_page.dart';
import 'package:vocechat_client/ui/widgets/avatar/voce_avatar_size.dart';
import 'package:vocechat_client/ui/widgets/avatar/voce_user_avatar.dart';

class NewDmPage extends StatefulWidget {
  const NewDmPage({Key? key}) : super(key: key);

  @override
  State<NewDmPage> createState() => _NewDmPageState();
}

class _NewDmPageState extends State<NewDmPage> {
  Future<List<UserInfoM>>? _future;

  @override
  void initState() {
    super.initState();
    _future = _loadUsers();
  }

  Future<List<UserInfoM>> _loadUsers() async {
    final list = await UserInfoDao().getUserList() ?? [];
    return list.where((u) => !SharedFuncs.isSelf(u.uid)).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: barHeight,
        elevation: 0,
        backgroundColor: AppColors.coolGrey200,
        title: Text(AppLocalizations.of(context)!.newDmPageTitle,
            style: AppTextStyles.titleLarge,
            overflow: TextOverflow.ellipsis,
            maxLines: 1),
        leading: CupertinoButton(
            onPressed: () {
              Navigator.pop(context, null);
            },
            child: Icon(Icons.close, color: AppColors.grey97)),
        actions: [
          CupertinoButton(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ContactsAddPage()),
              );
              if (!mounted) return;
              setState(() {
                _future = _loadUsers();
              });
            },
            child: const Icon(Icons.person_add_alt_1, color: Colors.black87),
          ),
        ],
      ),
      body: FutureBuilder<List<UserInfoM>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CupertinoActivityIndicator());
            }

            final userList = snapshot.data ?? [];
            if (userList.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('No people available'),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => const ContactsAddPage()));
                        if (!mounted) return;
                        setState(() {
                          _future = _loadUsers();
                        });
                      },
                      icon: const Icon(Icons.person_add_alt_1),
                      label: const Text('Add Contact'),
                    ),
                  ],
                ),
              );
            }

            return ListView.separated(
              itemCount: userList.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final user = userList[index];
                final name = user.userInfo.name;
                return ListTile(
                  leading: VoceUserAvatar.user(
                      userInfoM: user, size: VoceAvatarSize.s36),
                  title: Text(name),
                  subtitle: Text(user.userInfo.email ?? ''),
                  onTap: () => Navigator.of(context).pop(user),
                );
              },
            );
          }),
    );
  }
}
