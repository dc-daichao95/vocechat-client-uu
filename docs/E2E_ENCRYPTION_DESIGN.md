# VoceChat 绔埌绔姞瀵嗭紙E2E锛夎法绔榻愯璁?

> 鐘舵€侊細**MVP 宸插疄鐜帮紙Server 鎻掍欢 + Web DM e2e_ver=1锛夛紱鍏朵綑 搂0.1 涓庨閬?Flutter/璇煶浠?Draft**锛圔ot 椤瑰凡纭锛? 
> 鏃ユ湡锛?026-07-13锛堜慨璁?5锛? 
> 濂戠害鏂囨。浠擄細`vocechat-web-uu/docs`锛堣法绔榻愶級锛?*Server 瀹炵幇浠擄細`vocechat-server-rust-uu`**  
> 瀹㈡埛绔疄鐜颁粨锛歚vocechat-client-uu`锛圓ndroid / iOS / Windows锛? 
> 鍏宠仈锛歔`../AGENTS.md`](../AGENTS.md)銆乕`../design.md`](../design.md)锛汼erver锛歚vocechat-server-rust-uu/AGENTS.md`

### 浠撳簱鑱岃矗婢勬竻锛堥噸瑕侊級

| 浠撳簱 | 瀹為檯瑙掕壊 | 鍦ㄦ湰璁捐涓殑鑱岃矗 |
| --- | --- | --- |
| **`vocechat-server-rust-uu`** | **VoceChat 鍚庣 Server锛圧ust锛?* | HTTP `/api`銆丼SE銆丼QLite銆丮sgDb銆丅ot/Webhook銆佹枃浠讹紱**E2E 鏈嶅姟绔涓哄湪姝ゅ疄鐜?*锛涜璇ヤ粨 `AGENTS.md` / `design.md` / [`docs/SECURITY_E2E_AND_OBFUSCATION.md`](../../vocechat-server-rust-uu/docs/SECURITY_E2E_AND_OBFUSCATION.md) |
| `vocechat-web-uu` | **Web 鍓嶇瀹㈡埛绔?*锛圧eact SPA锛涘彲琚?Server `wwwroot` 鎵樼锛?| Web 绔?E2E锛?*璺ㄧ鍗忚/API 濂戠害鏂囨。**鍙惤鏈粨 `docs/`锛?*涓嶆槸**鍚庣杩涚▼ |
| `vocechat-client-uu` | **Flutter 瀹㈡埛绔?* | Android / iOS / Windows 瀹炵幇鍚屼竴 E2E 鍗忚 |

> 姝ゅ墠銆寃eb-uu 灏辨槸 server 绔€嶅簲鏇存涓猴細鏃ュ父閮ㄧ讲閲?Web 甯镐笌 Server **鍚屽煙浜や粯**锛屼絾 **Server 婧愮爜涓庤繘绋嬫槸 `vocechat-server-rust-uu`**銆侫PI 濂戠害鏂囨。鍙啓鍦?web-uu锛屽疄鐜板繀椤绘敼 server-rust-uu銆?

---

## 0. 宸茬‘璁ゅ喅绛?

| # | 璁 | 鍐崇瓥 |
| --- | --- | --- |
| 1 | 濞佽儊妯″瀷 | **D锛氬叏閮?* 鈥?HTTPS MITM 璇诲唴瀹?+ DPI/鎸囩汗灏侀攣 + Server 璇诲簱 |
| 2 | 绫?REALITY 浼 | **搴旂敤澶?*锛堟湰鏈轰唬鐞?VPN锛夛紱搴旂敤鍐呬笉鍋?|
| 3 | E2E 鍐呭鑼冨洿锛堜慨璁級 | **绉佽亰 + 棰戦亾 + 鏂囦欢锛堟枃鏈?Markdown/闄勪欢锛?*锛?*璇煶娑堟伅涓?Agora 閫氳瘽鍧囧厛涓嶅姩** |
| 4 | 瀹㈡埛绔竴鑷存€?| Web锛坵eb-uu锛? Server API + client-uu锛圓ndroid/iOS/Windows锛夊崗璁竴鑷?|
| 5 | 浜у搧闄嶇骇锛堟悳绱?鎺ㄩ€?Widget 绛夛級 | **Bot 宸茬‘璁よ鏀寔閫氫俊鍔犲瘑**锛堣 搂0.1 / 搂5.7锛夛紱鍏朵綑椤逛粛寰呯‘璁?|
| 6 | 瀵嗛挜鍗忓晢 | 璐﹀彿绾ц嚜鍔ㄥ寲 + TOFU + 鍙€夊畨鍏ㄧ爜 |
| 7 | 闃舵 | 鍏堟枃妗ｅ榻愶紱鏈壒鍑嗗啓鐢熶骇浠ｇ爜 |
| 8 | 澶氳澶?MVP | **宸蹭唬瀹氾細B 鈥?鐢ㄦ埛鍙ｄ护鍔犲瘑鐨勮韩浠藉瘑閽ュ浠斤紝澶氳澶囨仮澶?*锛堣 搂5.3锛?|
| 9 | 杩佺Щ | **宸蹭唬瀹氾細浼氳瘽绾у紑鍏?+ 浠呮柊娑堟伅鍔犲瘑**锛涘巻鍙叉槑鏂囧彧璇伙紱鍏ㄧ珯寮哄埗鍚庢湡 |
| 10 | API 鏂囨。浣嶇疆 | 濂戠害鏂囨。鍙湪 **`vocechat-web-uu/docs`**锛?*瀹炵幇浠撲负 `vocechat-server-rust-uu`** |
| 11 | client-uu 骞冲彴 | 鐩爣 **Android銆乮OS銆乄indows**锛?*浼樺厛鎶?Windows 涓?Android 鏋勫缓璺戦€?*锛沬OS 鍦?macOS 鍙敤鏃惰ˉ榻?|

### 0.1 浜у搧鑳藉姏涓?E2E

| 浜у搧鑳藉姏 | 鍐崇瓥 |
| --- | --- |
| **Bot / Webhook** | **宸茬‘璁わ細鏀寔閫氫俊鍔犲瘑**銆侭ot 浣滀负 E2E **浼氳瘽鎴愬憳**锛堣嚜鏈?identity 瀵嗛挜瀵癸級锛涚敤鎴?棰戦亾娑堟伅鎸?Sender Keys / 浼氳瘽瀵嗛挜鍔犲瘑缁欏惈 Bot 鍦ㄥ唴鐨勬垚鍛樸€侭ot 杩愯鏃舵寔鏈夌閽ュ苟瑙ｅ瘑鍚庡鐞嗕笟鍔°€?*涓嶆槸**銆孲erver 浠ｈВ瀵嗗悗鍐嶈浆缁?Webhook銆嶃€?|
| 鏈嶅姟绔秷鎭悳绱?| 鎺ㄨ崘锛氫粎瀹㈡埛绔湰鍦版悳宸茶В瀵嗙紦瀛橈紱Server 瀵瑰瘑鏂囧叏鏂囨悳绱㈠け鏁?鈥?**寰呯‘璁?* |
| 鎺ㄩ€?/ 閭欢棰勮 | 鎺ㄨ崘锛氫粎鍗犱綅锛屼笉甯︽鏂?鈥?**寰呯‘璁?* |
| 褰掓。 / 杞彂 | 鎺ㄨ崘锛氬悓瀵嗛挜鍩熷彲璇伙紱璺ㄤ細璇濋噸鍔犲瘑 鈥?**寰呯‘璁?* |
| Widget / Guest | 鎺ㄨ崘锛氱涓€鏈熶笉鍋?E2E 鈥?**寰呯‘璁?* |

#### Bot 鍔犲瘑妯″瀷锛堥攣瀹氳涔夛級

1. **韬唤**锛氭瘡涓?Bot 璐﹀彿鐢熸垚 identity 瀵嗛挜瀵癸紱**鍏挜**缁忕幇鏈夌敤鎴?Bot 韬唤鎺ュ彛鍒嗗彂锛?*绉侀挜浠呭瓨鍦ㄤ簬 Bot 瀹夸富**锛堢敤鎴疯嚜寤?bot 杩涚▼銆佹垨瀹樻柟 bot runner锛夛紝MUST NOT 鐢?VoceChat 涓?Server 鎸佹湁锛堝惁鍒欎富 Server 鍙瀵嗘枃锛屼笌濞佽儊妯″瀷 D 鍐茬獊锛夈€? 
2. **鍏ヤ細**锛欱ot 鍔犲叆鐨?DM/棰戦亾鑻ュ凡 `e2e_enabled`锛屽繀椤绘妸 Bot 绾冲叆 Sender Keys / 鎴愬憳瀵嗛挜鍒嗗彂锛涙垚鍛樺彉鏇达紙韪?Bot銆佸姞 Bot锛夎Е鍙戣疆鎹€? 
3. **鍏ョ珯**锛氬姞瀵嗕細璇濅腑鐢ㄦ埛 鈫?Bot 鐨勬秷鎭负瀵嗘枃锛汢ot 鐢ㄧ閽ヨВ瀵嗗悗鍐嶈窇 webhook/鎻掍欢閫昏緫銆? 
4. **鍑虹珯**锛欱ot 鈫?鐢ㄦ埛/棰戦亾鐨勫洖澶嶇敱 Bot **鍦ㄦ湰鍦板姞瀵?*鍚庯紝缁忕幇鏈夈€孊ot 鍙戞秷鎭€岮PI 鎻愪氦涓嶉€忔槑淇″皝锛堜笌浜虹被瀹㈡埛绔悓涓€ `vocechat/e2e` 璇箟锛夈€? 
5. **Webhook URL**锛氬彲缁х画鐢?Server 瑙﹀彂銆屾湁鏂版秷鎭€嶄簨浠讹紝浣嗗洖璋冧綋瀵?E2E 浼氳瘽 **鍙甫瀵嗘枃鎴栦粎 mid/鍏冩暟鎹?*锛涙槑鏂囧彧鍦?Bot 瑙ｅ瘑鍚庡嚭鐜板湪 Bot 渚с€傝嫢鐜版湁瀹炵幇鏄?Server 鎶婃槑鏂?POST 鍒?webhook锛孍2E 浼氳瘽蹇呴』鏀逛负銆岄€氱煡 + 瀵嗘枃銆嶆垨銆孊ot 鑷鎷?SSE/API 鍐嶈В瀵嗐€嶃€? 
6. **涓嶆敮鎸佸姞瀵嗙殑鏃?Bot**锛氳繘鍏?E2E 浼氳瘽鏃朵笉寰楁帴鏀舵槑鏂囷紱UI/鏂囨。鎻愮ず鍗囩骇 Bot runner锛涘彲閫夌鐞嗗憳绛栫暐绂佹鏈叿澶?E2E 鐨?Bot 鍔犲叆宸插姞瀵嗛閬撱€?

> 鎺ㄨ锛氭墭绠″湪銆屼富 Server 杩涚▼鍐呫€佷笖绉侀挜涔熷湪涓?Server銆嶇殑鍐呯疆 Bot **涓嶈兘婊¤冻**銆岄槻 Server 璇诲簱銆嶏紱姝ょ被 Bot 鍙兘鐢ㄤ簬闈?E2E 浼氳瘽锛屾垨鏀逛负澶栫疆 runner 鎸侀挜銆?

---

## 1. 鐩爣涓庨潪鐩爣

### 1.1 鐩爣

1. **鍐呭鏈哄瘑鎬?*锛歁ITM 鎷?TLS 鎴?Server 璇诲簱鏃讹紝浠嶆棤娉曞緱鍒版秷鎭鏂囦笌鏂囦欢鏄庢枃銆? 
2. **璺ㄧ涓€鑷?*锛歐eb / Android / Windows锛堝強鍚庣画 iOS锛夊悓涓€韬唤涓庝細璇濆瘑閽ヨ涔夈€? 
3. **鑷姩鍖?*锛氱櫥褰曞悗鑷姩娉ㄥ唽韬唤鍏挜骞跺崗鍟嗭紱鍙€夊畨鍏ㄧ爜鏍￠獙銆? 
4. **浼犺緭鍏煎**锛歊EST + SSE 涓嶅彉锛汼erver 瀛樿浆鍙戝瘑鏂囦俊灏侊紱`local_id` / `mid` / 浜嬩欢椤哄簭涓嶅彉閲忎繚鎸併€?

### 1.2 闈炵洰鏍?

1. 搴旂敤鍐?REALITY / 浼€?SNI / 鑷畾涔?TLS 鎸囩汗銆? 
2. 闅愯棌鍏冩暟鎹紙閫氫俊鍏崇郴銆佹椂搴忋€侀暱搴︺€佷富鏈哄悕锛夈€? 
3. 闃叉埅灞?/ 鏈満鎭舵剰杞欢 / 宸茶В閿佸鎴风銆? 
4. **鏈湡涓嶅仛**锛氳闊虫秷鎭?E2E銆丄gora 閫氳瘽鍔犲瘑锛堟槑纭喕缁擄紝鍙︽鍐嶅紑锛夈€? 
5. 涓€娆℃€ч噸鍐欏巻鍙叉秷鎭负瀵嗘枃銆?

### 1.3 濞佽儊 vs 鎺у埗

| 濞佽儊 | 鎺у埗 | 瑕嗙洊 |
| --- | --- | --- |
| 鏃?MITM 绐冨惉 | HTTPS | 宸叉湁 |
| 鍋?CA MITM | 搴旂敤灞?E2E | 鉁?鍐呭 |
| DPI / 灏侀攣 | 鏈満 REALITY/VPN | 鉂?搴旂敤澶?|
| Server 璇诲簱 | E2E 瀵嗘枃瀛樺偍 | 鉁?鍐呭 |
| Server 鎹㈠叕閽?| TOFU + 瀹夊叏鐮佸憡璀?| 鈿狅笍 UX 蹇呭 |
| 娴侀噺鍒嗘瀽 | 鈥?| 鉂?涓嶅仛 |

---

## 2. 娴侀噺浼锛堝簲鐢ㄥ锛?

鑱岃矗鍦ㄧ郴缁?VPN / Xray REALITY 绛夛紱`vocechat-web-uu` MUST NOT 鐢?JS 浼€?TLS銆侲2E 涓庝吉瑁呬簰琛ャ€佷笉浜掔浉鏇夸唬銆?

---

## 3. E2E 浜у搧鑼冨洿锛堜慨璁㈠悗锛?

### 3.1 鏈湡鍔犲瘑

| 绫诲瀷 | Content-Type | 绛栫暐 |
| --- | --- | --- |
| 鏂囨湰 | `text/plain` | 淇″皝瀵嗘枃 |
| Markdown | `text/markdown` | 鍚屾枃鏈?|
| 鏂囦欢 | `vocechat/file` | 瀹㈡埛绔姞瀵?blob 鍚庤蛋鐜版湁涓婁紶 |
| 鍥炲 / edit / reaction | 鐜版湁妯″瀷 | `mid` 鍏冩暟鎹彲浠嶅彲瑙侊紱姝ｆ枃璧板瘑鏂?|

### 3.2 鏈湡鏄庣‘鍐荤粨

| 鑳藉姏 | 鐘舵€?|
| --- | --- |
| 璇煶娑堟伅 `vocechat/audio` | **涓嶅姩**锛堜笉绾冲叆 E2E 鎺掓湡锛?|
| Agora 瀹炴椂閫氳瘽 | **涓嶅姩** |

### 3.3 浼氳瘽

- **DM**锛歋ignal 椋庢牸浼氳瘽瀵嗛挜锛圶3DH + Double Ratchet 鎴栫瓑浠凤級銆? 
- **棰戦亾**锛歋ender Keys锛涙垚鍛樺彉鏇磋疆鎹€侻LS 鍚庣疆銆?

---

## 4. 鍗忚閫夊瀷

- **閿佸畾**锛歋ignal 椋庢牸锛涚兢 = Sender Keys 鈫?鍚庢湡鍙紨杩?MLS銆? 
- **涓嶅仛**锛氭埧闂村彛浠ゅ绉板姞瀵嗕綔涓昏矾寰勶紙涓庛€岃嚜鍔ㄥ寲銆嶅啿绐侊級銆? 
- **绠楁硶鍩虹嚎**锛歑25519 韬唤锛汚EAD锛圓ES-256-GCM 鎴?ChaCha20-Poly1305锛夛紱DM 鍓嶅悜淇濆瘑锛涢€€缇ゅ悗瀵嗛挜杞崲銆? 
- **搴撻€夊瀷**锛氬疄鐜拌鍒掗樁娈?spike 閿佸畾锛圵ebCrypto / libsignal 绛夛級锛涙湰鏂囧彧閿佸崗璁鏃忋€?

### 4.1 淇′换妯″瀷

1. 鐧诲綍鐢熸垚鎴栦粠鍙ｄ护澶囦唤鎭㈠韬唤瀵嗛挜锛?*浠呭叕閽?*涓婁紶 Server銆? 
2. TOFU锛沀I 灞曠ず瀹夊叏鐮侊紱鍙樺寲鍒欏己鐑堝憡璀︺€? 
3. 绠＄悊鍛橀缃寚绾圭洰褰?鈥?闈?MVP銆?

---

## 5. 鏋舵瀯琛旀帴

### 5.1 Server / API锛堝绾﹀啓鍦ㄦ湰浠?docs锛?

蹇呴』锛氬瓨鍙?identity 鍏挜涓庨閽ワ紙鍚?**Bot 璐﹀彿**锛夛紱娑堟伅 body 涓嶉€忔槑锛涗繚鐣?mid/SSE/閴存潈/鎴愬憳/宸茶銆? 
涓嶅緱锛氫负鎺ㄩ€?鎼滅储瑙ｅ瘑 E2E 鍐呭锛?*涓嶅緱**鎸佹湁 Bot 韬唤绉侀挜浠ｈВ瀵嗭紱鏃ュ織杈撳嚭瀵嗛挜鎴栨槑鏂囥€?

鍏蜂綋璺緞涓?JSON 瀛楁瑙?**闄勫綍 A**锛堣崏妗堬紝闅?搂0.1 瀹氱鍚庣粏鍖栵級銆?

### 5.2 娑堟伅淇″皝锛堟蹇碉級

```text
content_type: "vocechat/e2e"   # 鎴?properties.e2e=true + 淇濈暀鍘熺被鍨?
content: <opaque ciphertext>
properties: {
  e2e: true,
  e2e_ver: 1,
  sender_device_id: "...",
  ratchet_header: "...",
  local_id: <existing>
}
```

鍔犲瘑鍦ㄥ彂閫佸墠锛涜В瀵嗗湪杩?UI 鍓嶏紱澶辫触鏄剧ず鍗犱綅锛岀姝㈡妸瀵嗘枃褰撴鏂囥€?

### 5.3 澶氳澶囷紙宸蹭唬瀹?B锛?

- **鏂规 B**锛氳韩浠界閽ョ粡**鐢ㄦ埛鍙ｄ护**娲剧敓瀵嗛挜鍔犲瘑鍚庯紝鍙笂浼犮€屽姞瀵嗗浠?blob銆嶅埌 Server锛圫erver 鏃犳硶瑙ｅ瘑锛夈€? 
- 鏂拌澶囷紙Web / Android / Windows锛夎緭鍏ュ悓涓€鍙ｄ护鎭㈠韬唤锛屽啀寤虹珛浼氳瘽銆? 
- MUST NOT 涓婁紶韬唤绉侀挜鏄庢枃銆? 
- 瀹屾暣 Signal 澶氳澶囨墖鍑猴紙鏂规 C锛夊垪涓?P5 纭寲锛屼笉闃诲 MVP銆?

### 5.4 鏂囦欢

瀹㈡埛绔殢鏈烘枃浠跺瘑閽?鈫?鍔犲瘑 blob 鈫?鐜版湁鍒嗙墖涓婁紶锛涙枃浠跺瘑閽ョ粡浼氳瘽 E2E 涓嬪彂銆侻VP **鍔犲瘑鏂囦欢鍚?*锛圲I 鏄剧ず銆屽姞瀵嗘枃浠躲€嶏級銆?

### 5.5 Web锛坄vocechat-web-uu`锛?

瀵嗛挜瀛?IndexedDB锛涚姝㈤仴娴?瀹夸富妗ユ硠闇叉槑鏂囷紱Widget/Guest 鏄惁 E2E 寰?搂0.1銆?

### 5.6 Flutter锛坄vocechat-client-uu`锛?

- 瀵嗛挜锛欰ndroid Keystore / iOS Keychain / Windows 鍙敤 DPAPI 鎴栫瓑浠峰畨鍏ㄥ瓨鍌紙瀹炵幇鏃堕攣瀹氾級銆? 
- 涓嶇牬鍧?SSE EventQueue銆乣localMid`銆佸弻搴撻殧绂汇€? 
- **骞冲彴鏋勫缓浼樺厛绾?*锛堢敤鎴峰喅绛栵紝瑕嗙洊鏃с€屼粎 Android/iOS銆嶄骇鍝佸彊杩颁腑鐨勬闈㈢浠わ紝瑙?client `AGENTS.md` 鍚屾淇锛夛細  
  1. **Windows** desktop 鍙瀯寤? 
  2. **Android** debug/release 鍙瀯寤? 
  3. **iOS** 鍦?macOS Runner 鍙敤鍚庤ˉ榻? 

E2E 鍔熻兘寮€鍙戜笌銆屽厛鎵撻€?Windows/Android 鏋勫缓銆嶅彲骞惰锛屼絾 **鍚堝苟 E2E 鍓嶈嚦灏?Windows 鎴?Android 涔嬩竴鍏峰鍙鐜版瀯寤鸿瘉鎹?*銆?

### 5.7 Bot锛堝凡纭锛氭敮鎸侀€氫俊鍔犲瘑锛?

- Bot = 鐗规畩鐢ㄦ埛韬唤 + **澶栫疆 runner 鎸佹湁绉侀挜**锛堣 搂0.1锛夈€? 
- 浜虹被瀹㈡埛绔姞瀵嗗彂閫佹椂锛屽瘑閽ュ垎鍙?MUST 鍖呭惈浼氳瘽鍐呭凡鍚敤 E2E 鐨?Bot 鎴愬憳銆? 
- Bot 鍑虹珯娑堟伅涓庝汉绫荤浉鍚岋細鏈湴鍔犲瘑 鈫?API 鎻愪氦淇″皝銆? 
- Webhook锛欵2E 浼氳瘽绂佹 Server 闄勫甫鏄庢枃 body锛涙敼涓哄瘑鏂?鍏冩暟鎹€氱煡鎴?Bot 鑷媺銆? 
- 鎺掓湡锛欴M/棰戦亾 Sender Keys 闃舵蹇呴』鍖呭惈銆孊ot 鎴愬憳銆嶆祴璇曠煩闃碉紱鍙笌 P4 鍚屽垪鎴栫揣闅?P2 鍋氥€屽崟 Bot DM銆峴pike銆?

---

## 6. 鍏煎涓庤縼绉伙紙宸蹭唬瀹氾級

1. 鑳藉姏浣?`e2e_available`銆? 
2. **浼氳瘽绾у紑鍏?*锛涘紑鍚悗**浠呮柊娑堟伅** E2E锛涘巻鍙叉槑鏂囧彧璇汇€? 
3. 鍏ㄧ珯寮哄埗 鈥?鍚庢湡銆? 
4. 杩囨棫瀹㈡埛绔彁绀哄崌绾с€?

---

## 7. 鍒嗛樁娈佃矾绾匡紙闈炲紑宸ヤ护锛?

| 闃舵 | 鍐呭 |
| --- | --- |
| **P0** | 鏈枃 Accepted锛堝惈 搂0.1锛夛紱闄勫綍 A API 鑽夋瀹氱 |
| **P0b** | client-uu锛?*Windows + Android 鏋勫缓璺戦€?*锛堜笌 E2E 鍙苟琛岀殑宸ョ▼鍩虹嚎锛?|
| **P1** | 鍔犺В瀵?spike锛圵eb + 鑷冲皯涓€ Flutter 妗岄潰鎴?Android锛?|
| **P2** | DM 鏂囨湰 MVP + 鍙ｄ护澶囦唤鎭㈠ |
| **P2b** | **Bot DM E2E**锛氬缃?runner 鎸侀挜銆佽В瀵嗗叆绔欍€佸姞瀵嗗嚭绔欍€亀ebhook 鏃犳槑鏂?|
| **P3** | 鏂囦欢 E2E锛?*涓嶅惈**璇煶/Agora锛?|
| **P4** | 棰戦亾 Sender Keys锛堝惈 Bot 鎴愬憳杞崲锛?|
| **P5** | 澶氳澶囩‖鍖?/ MLS / 绠＄悊鍛樼瓥鐣?|
| **鍙︽** | 璇煶娑堟伅銆丄gora銆丷EALITY 鎵嬪唽 |

---

## 8. 瀹夊叏绾㈢嚎锛堝€欓€夊啓鍏ュ悇浠?AGENTS锛?

1. MUST NOT 涓婁紶鎴栨棩蹇楄褰曡韩浠界閽ャ€佷細璇濆瘑閽ャ€佹枃浠跺瘑閽ユ槑鏂囥€? 
2. MUST NOT 涓烘柟渚挎悳绱?鎺ㄩ€佸悜 Server 鍥炰紶 E2E 鏄庢枃锛汳UST NOT 鐢变富 Server 鎸佹湁 Bot 绉侀挜浠ｈВ瀵嗐€? 
3. 鍏挜鎸囩汗鍙樺寲 MUST 鍛婅锛孧UST NOT 闈欓粯鎺ュ彈銆? 
4. MUST NOT 澹扮О搴旂敤鍐呴槻 DPI/绛夊悓 REALITY銆? 
5. MUST NOT 鎶婅闊?Agora 濉炶繘鏈壒鍑嗙殑 E2E PR銆?

---

## 9. 璇勫鐘舵€?

| 椤?| 鐘舵€?|
| --- | --- |
| 闈炵洰鏍囧惈涓嶅仛搴旂敤鍐?REALITY | 鍚屾剰锛堟部鐢級 |
| 璇煶 + Agora 鍏堜笉鍔?| **宸茬‘璁?* |
| Signal 椋庢牸 + Sender Keys | 鍚屾剰锛堟部鐢級 |
| 搂0.1 Bot 鏀寔閫氫俊鍔犲瘑锛堝缃寔閽ワ級 | **宸茬‘璁?* |
| 搂0.1 鎼滅储 / 鎺ㄩ€?/ 褰掓。 / Widget | **寰呯‘璁?*锛堜粛鐢ㄦ帹鑽愰粯璁わ紝鏈攣瀹氾級 |
| 澶氳澶?B锛堝彛浠ゅ浠斤級 | **宸蹭唬瀹?* |
| 杩佺Щ锛氫細璇濆紑鍏?+ 鏂版秷鎭?| **宸蹭唬瀹?* |
| API 鏂囨。鍦?web-uu | **宸茬‘璁?* |
| client锛歐in/Android 浼樺厛鏋勫缓 | **宸茬‘璁?* |

---

## 闄勫綍 A 鈥?Server API 鑽夋锛堥鏋讹紝搂0.1 瀹氱鍚庤ˉ瀛楁锛?

> 钀界偣锛氭湰鏂囦欢锛涘疄鐜版柟鍙湪鍚庣浠撹惤鍦帮紝浣嗚矾寰勮涔変互杩欓噷涓哄噯銆?

### A.1 韬唤涓庨閽?

- `PUT /user/e2e/identity` 鈥?涓婁紶/杞崲 identity 鍏挜锛堝強璁惧 id锛夛紱**浜虹被涓?Bot 璐﹀彿鍏辩敤璇箟**  
- `GET /user/e2e/identity/{uid}` 鈥?鍙栧绔紙鍚?Bot锛夊叕閽ヤ笌鎸囩汗鏉愭枡  
- `PUT /user/e2e/prekeys` / `GET ...` 鈥?涓€娆℃€ч閽ワ紙鑻ョ敤 X3DH锛? 
- `PUT /user/e2e/backup` 鈥?涓婁紶鍙ｄ护鍔犲瘑鐨勮韩浠藉浠?blob锛堜笉閫忔槑锛涗富瑕侀潰鍚戜汉绫诲璁惧锛? 
- `GET /user/e2e/backup` 鈥?涓嬭浇鏈处鍙峰浠?blob  
- Bot runner锛氫娇鐢?Bot token 璋冪敤涓婅堪 identity/prekeys锛?*绉侀挜姘镐笉缁忚繃涓?Server**

### A.2 娑堟伅

- 鐜版湁鍙戦€?API锛堝惈 Bot 鍙戞秷鎭級鎺ュ彈 `vocechat/e2e`锛堟垨 `properties.e2e=true`锛変笉閫忔槑 `content`  
- SSE `chat` 鍘熸牱涓嬪彂锛汼erver 涓嶅仛鍐呭瑙ｆ瀽  
- Webhook 鍥炶皟锛欵2E 浼氳瘽瀛楁涓嶅緱鍚槑鏂?`content`锛涙彁渚?`e2e: true` + 瀵嗘枃鎴栦粎 `mid`

### A.3 浼氳瘽绛栫暐

- 棰戦亾/DM 璁剧疆锛歚e2e_enabled: bool`锛堜細璇濈骇锛? 
- Server 閰嶇疆锛歚e2e_available: bool`  
- 鍙€夛細`require_e2e_capable_bots` 鈥?宸插姞瀵嗕細璇濇嫆缁濇棤 E2E 韬唤鐨?Bot 鍔犲叆  

锛堣缁?JSON schema銆侀敊璇爜銆佺増鏈ご `e2e_ver` 鍦ㄥ叾浣?搂0.1 椤圭‘璁ゅ悗绗簩杞ˉ鍏ㄣ€傦級

---

## 10. 淇璁板綍

| 鏃ユ湡 | 鍙樻洿 |
| --- | --- |
| 2026-07-13 | 鍒濈 |
| 2026-07-13 | 淇 2锛氳闊?Agora 鍐荤粨锛涘璁惧瀹?B锛涜縼绉诲畾浼氳瘽寮€鍏筹紱API 钀?web-uu锛沜lient 骞冲彴 Win/Android 浼樺厛锛浡?.1 鏍囧緟鏀?|
| 2026-07-13 | 淇 3锛?*Bot 鏀寔閫氫俊鍔犲瘑**锛堝缃?runner 鎸侀挜銆亀ebhook 鏃犳槑鏂囥€丳2b/P4 鎺掓湡锛夛紱绂佹涓?Server 浠ｈВ瀵?|
| 2026-07-13 | 淇 4锛氱‘璁?**`vocechat-server-rust-uu` 涓?Server 瀹炵幇浠?*锛涙洿姝?web-uu 鈮?鍚庣杩涚▼ |
| 2026-07-13 | 淇 5锛歁VP 钀藉湴 鈥?Server `/api/user/e2e/*` + `vocechat/e2e` 瀛樿浆鍙?+ webhook 鑴辨晱 + `e2e_available`锛沇eb DM e2e_ver=1锛圥-256 ECDH + AES-GCM锛夈€傞閬?Sender Keys / Flutter / 璇煶浠嶆湭瀹炵幇 |

