# SniperPVEGA — 全球行动

| 项 | 值 |
|---|---|
| GitHub 仓库 | **pvega** |
| Package | `com.sniper.pvega` |
| TWEAK_NAME | `SniperPVEGA` |
| 当前版本 | **0.2.0**（修「玩几把就闪退」+ 删最后一发保护） |
| 运行时配置 | `Documents/pvega_config.json` |
| 日志 | `Documents/pvega_tweak.log` |

## 🆕 v0.2.0 改了什么（2026-10-02）

1. **删掉「最后一发保护」**（整段删除，与 `autohead.js v8.40` 同步）
   - 配置里的 `shot_guard` / `guard_margin` / `guard_fire_ms` 三个键已**全部移除**，
     旧的 `pvega_config.json` 里即便还留着也会被忽略（不会被解析）。
   - 理由：狙击是**松手开枪**（`ShootUp` 尾部才 `TryNormalShoot`），而 v0.1.0 的实现是
     「按下就不松手」⇒ 一枪都没打出去 ⇒ 保护触发了、日志有记录，照样闪退。
   - ⇒ **本局最后一发请自己开枪**。
2. **修「玩几把就闪退」**（真正的根因不是保护，是跨局野指针）
   - 旧代码在**对局结束后仍继续**往已释放的 il2cpp 对象里写：
     封顶（`targetTick` 每秒无条件写）、刷怪器（`spawnTick` 500ms 无条件写）、
     无限子弹（`refillAmmo` **每帧**写 + 射手句柄缓存 5 秒 ≈ 换局后 300 次写死对象）。
   - v0.2.0 加了 **`matchWatch()` / `onNewMatch()` 换局生命周期**：控制器实例换新
     或 `_running` 0→1 时，统一作废 击杀表 / 射手 / 控制器缓存 / 封顶记录。
   - 所有写入都加了**对局门**：不在对局中就不写（准备阶段封顶改为「每实例只写一次」）。
   - 缓存与频率降负：`ctrlInst` 400ms→**120ms**、刷怪 500ms→**1000ms**、弹药每帧→**200ms**，
     1 秒定时器不再重复 frame() 里已有的活。
   - 日志新增 `[PVE] 换局#N（原因）→ 已作废 …`，心跳新增 `局数=N`。

## 上传文件清单（放在仓库根目录）

- `Makefile`
- `control`  ← ⚠️ 最容易传错的一个
- `SniperPVEGA.plist`
- `Tweak.xm`
- `.github/workflows/build.yml`
- （可选）`pvega_config.example.json`、`README.md`

## ⚠️ 别再犯的对调事故（2026-10-02 真实踩坑）

曾经把 `PVE僵尸噩梦` 的 control（`Package: com.sniper.pvezb`）传到 pvega 仓库。
结果：deb 的 Package 变成 pvezb，但里面装的还是 `SniperPVEGA.dylib`，
**包 ID 与代码不一致** → 手机上既不杀怪，也不生成 `pvega_config.json`。

**上传前务必确认 `control` 第一行是：**

```
Package: com.sniper.pvega
```

## 上传后怎么确认

Actions 日志里应有两步自检，必须全绿：

1. `Verify identity` → `✅ 身份自洽：Makefile / control / plist 三者匹配`
2. `Verify deb` → `✅ 产物自洽：Package=com.sniper.pvega 与 dylib=SniperPVEGA.dylib 匹配`

任一步红字 = 文件传错了，**不要装产物**。

## Architecture 必须是 arm64

手机系统是 `iphoneos-arm64`。control 里若写 `iphoneos-arm`，
`dpkg -i` 会直接拒绝：`package architecture (iphoneos-arm) does not match system (iphoneos-arm64)`。
已统一为 `iphoneos-arm64`。

## 装完怎么确认真的生效（关键）

看手机 Sniper3D 的 Documents 目录：

| 看到的文件 | 结论 |
|---|---|
| `pvega_config.json` + `pvega_tweak.log` | ✅ 装对了，全球行动生效 |
| `pvezb_config.json` + `pvezb_tweak.log` | ❌ 装的还是僵尸代码（又踩对调包） |

`pvega_tweak.log` 里还应有这三行：

```
[PVE] [LOADED] target=com.fungames.sniper3d v...（SniperPVEGA）
[PVE] 🔎 方法绑定: ... 全球单例=1
[PVE] ✅ ReportLevelResult 已挂钩
```

> ⚠️ **同名文件陷阱（2026-10-02 真踩过）**：
> `D:\IOS共享\` 根目录和 `已修正\` 子目录里可能同时存在
> `com.sniper.pvega_0.1.0-1+debug_iphoneos-arm64.deb`，**文件名一模一样**，
> 但根目录那份可能是旧的对调包（里面装的是 `SniperPVEZB.dylib` 僵尸代码）。
> 装之前用 `chk_deb.py` 确认，或直接看解压后 dylib 的名字。

## 本地自检（上传前秒级验证，不用等 CI）

在 `DEB分类` 目录运行：

```
python check_before_upload.py
```

全绿再上传。
