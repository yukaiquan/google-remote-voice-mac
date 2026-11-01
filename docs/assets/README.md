# 首页视觉资源

- `cover-g9n9n.png`：当前首页封面。用内置图像编辑工具，按用户提供的 G9N9N 外形参考修正按键布局；它是生成插画，不是实物照片，兼容型号以项目文档为准。
- `cover.png`：保留的初版概念封面，其中遥控器布局不对应实物，已停止用于首页。
- `hero.svg`：保留的第一版矢量封面。
- 本次仅修改仓库展示和文档，未修改应用功能或本机配置。

## G9N9N 外形修正

前视图参考用户提供的遥控器实物照片，侧面轮廓参考补充图片。原始照片和购物截图不随仓库发布；参考图中的价格、商家文案和认证说法不构成本项目结论。

检查重点：顶部方向环与中心确认键；返回/黑色 Assistant、主页/静音、YouTube/Netflix 三排双键；底部电源/指示灯/信源；侧面音量键。保留原封面配色和文案。

编辑使用内置图像工具，提示词如下（Image 1 为初版封面，Image 2 为前视参考，Image 3 为侧面补充参考）：

```text
Edit target: Image 1 is the current GitHub banner. Reference Image 2 is the authoritative real Chromecast Voice Remote front shape and exact buttons. Reference Image 3 is supporting reference for the SAME remote side thickness and side volume rocker only; IGNORE all marketplace UI, prices, sellers, hands, backgrounds and text. Change ONLY the remote hardware in Image 1 to faithfully match the real white G9N9N remote in Image 2. Preserve Image 1's complete wide 3:1 composition, Chinese headline '开口，就开工。', subtitle '按住说话 · 松开输入', English texts, ivory/mint palette, soft light, waveform, plinth and speech bubble. CRITICAL IDENTITY: elongated white rounded capsule body; large circular white D-pad at top with smaller round white central select; directly BELOW the D-pad THREE ROWS of TWO equal small ROUND buttons, columns aligned: row 1 LEFT white back-arrow, RIGHT BLACK Google Assistant button with white four-dot Assistant mark (NOT a microphone icon, NOT green, NOT enlarged); row 2 LEFT white home icon, RIGHT white speaker-with-x mute icon; row 3 LEFT white 'YouTube' button, RIGHT white 'NETFLIX' button. Below these a recessed shallow horizontal strip with LEFT smaller round POWER button, CENTER tiny horizontal status LED dash, RIGHT smaller round INPUT/source arrow-in-box button. Preserve exact order, relative spacing and proportions from reference Image 2. Long blank white rounded tail below power row. Subtle two-part volume rocker on right side as reference Image 3 if visible. Use an almost front-on product view with slight perspective so all front buttons are clearly visible and legible; do not let the bubble hide any buttons. Do not invent/reorder/remove buttons. This is a faithful product-shaped illustration rather than an invented generic remote. No hand, no marketplace screenshot, no user photo background. Keep every other banner element and text unchanged.
```

## 初版封面生成提示词

```text
Use case: ads-marketing. Create a finished premium GitHub README cover banner for the open source project Google Remote Voice for Mac. Wide panoramic 3:1 composition. Editorial consumer electronics art direction, exceptionally refined, bright warm ivory background, muted mint green, ink charcoal typography, one small warm coral accent. On the left 55 percent: spacious expertly typeset text, EXACT main Chinese headline on two lines '开口，' then '就开工。' in large beautiful bold modern Chinese sans serif. Small English project name above: 'GOOGLE REMOTE VOICE'. Short subtitle below Chinese headline: '按住说话 · 松开输入'. Small lower caption 'for Mac  /  Works with Handy'. On the right: a beautifully crafted softly lit stylized 3D white Chromecast-style voice remote with circular directional ring and central button, small round buttons beneath, pale mint microphone button emphasized, a restrained floating mint audio waveform and one tasteful rounded frosted transcription bubble containing only '今天，开始创造。'. Remote tilted slightly, soft contact shadows on a pale mint sculptural circular plinth, studio product rendering meets restrained editorial design. Keep all text clean, exactly spelled, no additional text, no large brand logos, no Google G logo, no watermarks, no badges, no tiny illegible labels, no screenshots or app window chrome, no neon, no dark background. Generous negative space and subtle paper grain. All content safely inside generous margins. This is a conceptual product illustration, not a photograph or official manufacturer advertising. This banner must look sophisticated, calm, polished and immediately beautiful as the top of a GitHub repository.
```
