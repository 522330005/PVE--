/* ============================================================================
 * SniperPVEGA — Sniper3D PVE【全球行动】tweak（autohead.js v8.42 模式2 的原生移植）
 * 注入方式：Dopamine 运行时注入（不动磁盘二进制，TNG 已验证的路线）
 *
 * ★★★ v0.3.3：闪退根因定案 = 双开吞吐超载（配置二分铁证）★★★
 *   v0.3.1/v0.3.2 在"2 刷怪器关卡"进关 1~2 秒 SIGABRT（.ips 纯引擎帧 UnityRepaint→abort）。
 *   SSH 热重载配置四轮二分（同一关卡实测）：
 *     A) auto_kill=0 + spawn=0  → 不崩     B) 只 auto_kill            → 不崩
 *     C) 只 spawn               → 不崩     D) 双开@20刷+20杀（历史）  → 必崩×4
 *   ⇒ 不是写入写坏内存，是"刷怪+杀怪"总吞吐超载：2 刷怪器地图天然刷怪多，
 *     叠加 20只/秒刷 + 20只/秒杀后引擎在渲染循环主动 abort。1 刷怪器小地图撑得住，
 *     大地图撑不住 —— 与"写几个刷怪器"无关（v0.3.2 只写 1 个照样崩）。
 *   用户拍板常驻参数（真机稳定）：杀 3个×200ms=15只/秒 · 刷 5只/秒 · 同屏 5 ·
 *   总数 0(内部500) · 封顶 500。已写入 DEF_* 默认值 + WriteDefaultConfig。
 *
 * 功能模块（对应 autohead.js 的模式 2 常驻项）：
 *   g  自动杀怪：每 tick_ms 杀 kill_per_tick 个，固定爆头（Person.Kill(true)）
 *       ★ 必须等 _running=1（任务正式开始）才动手 —— 准备阶段的预置怪杀了不算数还扎眼
 *   p  分数封顶：TournamentInGameController._targetPoints 恒定写目标分，并关 capBonus
 *       ⇒ 到分就结算，被游戏重设会自动再写（自愈）
 *   w  刷怪加速：写【通用 TimedSpawner】的 间隔/总数/同屏上限（按类名分派偏移）
 *   ∞  无限子弹：每把枪 currentAmmo 常驻写满 maxAmmo
 *   n  安全结算 ★ v0.3.1：拦截 LevelController::ShowKillCam（空命中慢动作的唯一入口），
 *       复刻官方 FakeKillCam：等 CharacterShooter.get_KillDelay 秒 → OnKillCamFinished()
 *       ⇒ 【不用再开最后一枪】，按游戏自己的"无弹结算"节奏正常结算上报、不闪退
 *   （连击注入已移除：全球行动没有连击加分，僵尸模式才有）
 *   ~~m 最后一发保护~~ ★ v0.2.0 已【整段删除】（同 autohead.js v8.40）—— 最后一发自己开枪
 *
 * ★★★ v0.3.1：安全结算（真机日志定案的替代方案）★★★
 *   v0.3.0 的 1 字节补丁（_showKillCamOnEndLevel=0 ⇒ Win(false) ⇒ else 分支【立即】
 *   OnKillCamFinished）在真机上仍然闪退。pvega_tweak.log 时间线：自动杀怪 20/秒在
 *   1~2 秒内清空目标 → 立即结算 → 进程消失（且无 .ips）。对比：JS v8.40 手动开
 *   最后一枪走原生 KillCam 结算 = 稳定。两个嫌疑：
 *     X) ReportLevelResult 的 MSHook（v0.3.0 第一次真正被加载，从未验证）；
 *     Y) 立即结算 —— 官方自己的"无弹结算" FakeKillCam 是【等 get_KillDelay 秒】
 *        才调 OnKillCamFinished 的（0x32b9768 实证），我们提前了整整一个镜头的时长，
 *        结算 UI 在死亡动画/布娃娃未清理时就弹出。
 *   v0.3.1 同时消除两者：
 *     ① 撤掉 0x101 补丁，改为 MSHook LevelController::ShowKillCam（全二进制唯一
 *        调用点 = Win+0x63c，零副作用）。替换体复刻 FakeKillCam：读 _player(+0x230)
 *        的 get_KillDelay → dispatch_after 主线程等同样时长 → runtime_invoke
 *        OnKillCamFinished → 走原生结算/上报。没开枪也不会再卡死/闪退。
 *     ② ReportLevelResult 钩子改为配置 equip_hook（默认 false）才安装。
 *   （v0.3.0 的分析详见 D:\sniper_chams\wo\全球行动_KillCam结算链路_全面分析.md；
 *     真机定案过程见工作日志 2026-10-02）
 *
 * ★★★ v0.2.0：修复"全球行动玩几把就闪退"（僵尸噩梦 deb 不闪退）★★★
 *   根因 = 换局后继续读写**已释放的 il2cpp 对象**，攒几局把堆写坏。四处：
 *     ① targetTick()  每秒无条件写控制器 +0x54 / +0x28（不检查 _running，对局结束后照写）
 *     ② spawnTick()   每 500ms 无条件写刷怪器（且不检查 _running）
 *     ③ refillAmmo()  **每帧**写弹药，而 shooterInst 缓存 5 秒（换局后 60Hz×5s 写死对象）
 *     ④ ctrlInst()    控制器实例缓存 400ms，跨过换局点就是野指针
 *   另外 m 那条链本身也是崩源之一（见下"历史包袱"）。
 *   修复：新增 onNewMatch() 换局生命周期（_running 0→1 / 实例换指针 → 全部作废重抓），
 *         并给 targetTick / spawnTick / refillAmmo 加上"必须真在对局中"的门。
 *   历史包袱（说明为什么"按住连发"救不了场，只能删）：
 *     狙击是"松手开枪"（ShootUp 尾部才 TryNormalShoot），而 v0.1.0 的"保护"是
 *     【按下就不松手】，等于**一枪都没打出去** —— 终局没有真实弹道记录，
 *     KillCam 该空引用还是空引用。加上 8Hz 反复调 ShootDown 会把射手状态机搅乱。
 *     ⇒ 用户拍板：整段删掉，最后一发自己手动开枪。
 *
 * 配置：沙盒 Documents/pvega_config.json（首次运行自动生成，改完 5 秒热重载）
 * 日志：沙盒 Documents/pvega_tweak.log（[LOADED] = 注入成功铁证）
 *
 * ⚠️ 沿用 SniperPVP 的血泪教训：
 *   - il2cpp API 只在**主线程**调用（后台 pthread 会撞 Unity 初始化窗口 →
 *     il2cpp 内部 SIGSEGV 0x135，两份 .ips 实证）
 *   - %ctor 里一个 Foundation 都不碰，全部排到主队列
 *   - 默认值宏必须定义在文件头（ConfigDefaults 会用到，晚定义会编译报错）
 * ========================================================================== */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <math.h>
#include <stdlib.h>      /* malloc / calloc */
#include <sys/stat.h>    /* 配置热重载：stat() 取文件修改时间 */

#define TWEAK_VERSION "0.4.0"
#define BUNDLE_SNIPER3D "com.fungames.sniper3d"

/* ★ 默认参数（会被配置覆盖）—— 必须定义在文件头，ConfigDefaults() 要用 */
/* ★ 2026-10-01 用户指定：节奏 200ms、每秒杀 20 个、刷怪常年 20 只/秒
 * ★ v0.2.0：「保护段距满分 250 分」随最后一发保护一起删除 */
#define DEF_TICK_MS        200      /* 杀怪节奏：每 200ms 一拍 → 5 拍/秒 */
/* ★ v0.3.3 默认值（2026-10-02 真机二分定案，用户拍板常驻）：
 *   闪退根因不是某个写入写坏内存，而是"刷怪+杀怪"双开总吞吐超载 —— 2 刷怪器地图
 *   天然刷怪多，20只/秒刷 + 20只/秒杀叠加后引擎在渲染循环主动 abort（.ips 纯引擎帧）。
 *   二分铁证：A(全关)不崩 / B(只杀)不崩 / C(只刷)不崩 / 双开@20+20 必崩。
 *   用户最终参数（稳定+不闪退）：杀 3个×200ms=15只/秒 · 刷 5只/秒 · 同屏 5 · 总数 0 · 封顶 500。 */
#define DEF_KILL_PER_TICK  3        /* 每拍杀 3 个 ⇒ 5 × 3 = 每秒 15 个 */
#define DEF_SPAWN_RATE     5        /* 每秒刷 5 只 */
#define DEF_SPAWN_LIMIT    5        /* 同屏上限 */
#define DEF_SPAWN_TOTAL    0        /* 0 = 不限（内部用 500） */
#define DEF_TARGET_POINTS  500      /* 分数封顶 = 500 */
/* ★ v0.2.0：DEF_GUARD_MARGIN / DEF_GUARD_FIRE_MS 已随"最后一发保护"整段删除 */

/* 全球行动控制器 TournamentInGameController */
#define TIC_RUNNING     0x40        /* _running：StartCounting() 置 1，Finish() 清 0 */
#define TIC_TARGET      0x28        /* _targetPoints（封顶分） */
#define TIC_POINTS      0x44        /* _points（实时分，不是右上角 UI） */
#define TIC_CAPBONUS    0x50        /* _capBonus */
#define TIC_USECAP      0x54        /* _useCapBonus（置 0 = 不叠加，封顶就等于 _targetPoints） */

/* ★ v0.3.1：安全结算 —— 那个"慢动作画面"是 KillCam：LevelController::Win(bool)
 *   → ShowKillCam()（没开枪 ⇒ CharacterShooter._hits 为空 ⇒ 直接 return ⇒ 永不结算）。
 *   官方自己的无弹结算路径 FakeKillCam 是【等 get_KillDelay 秒再 OnKillCamFinished】
 *   （0x32b9768 实证），v0.3.0 的 0x101 补丁把结算提前了整整一个镜头的时长，真机闪退。
 *   ⇒ v0.3.1 改为 MSHook ShowKillCam（全二进制唯一调用点 Win+0x63c），替换体复刻
 *   FakeKillCam 的节奏，走游戏自己的结算链。 */
#define LC_PLAYER 0x230    /* LevelController._player（CharacterShooter） */
/* 开火键屏幕坐标（同 aim.js 实测值） */
#define FIRE_POS_X      0.125
#define FIRE_POS_Y      0.81

/* 刷怪器：三个类的布局**不完全一样**（dump.cs 实证），认不出就绝不写 */
#define SP_TOTAL_MIN  0x28
#define SP_TOTAL_MAX  0x2C
#define SP_ITV_MIN    0x30
#define SP_ITV_MAX    0x34
#define SP_LIMIT      0x38
/* 类相关偏移 */
#define SP_HALLOW_CUR 0x88
#define SP_HALLOW_RUN 0x90
#define SP_HALLOW_LEFT 0x94
#define SP_TIMED_CUR  0x94
#define SP_TIMED_RUN  0x9C
#define SP_TIMED_LEFT 0xA0
#define SP_T500_CUR   0x84
#define SP_T500_RUN   0x8C
#define SP_T500_LEFT  0x90

/* 僵尸控制器（HalloweenLiveEventLevelController） */
#define HALL_MATCHTIMER  0x308     /* → MatchTimer */
#define HALL_STORAGE     0x350     /* → KilledZombieStorage（本局人头） */
#define MT_RUNNING       0x24      /* isTimerRunning (u8) */
#define MT_SECONDS       0x20      /* matchTimeSeconds (float) */
#define MT_LEFT          0x28      /* timeLeft (float) */
/* 连击相关偏移已移除（全球行动无连击加分） */
/* Person 存活位 */
#define P_ALIVE  0x190
#define P_DEAD   0x191
#define P_DYING  0x1C0
/* 无限子弹：CharacterShooter +0xC8 参数表 */
#define CS_AMMO_LIST  0xC8
#define AMMO_CUR      0x18
#define AMMO_MAX      0x1C

/* ================= 日志 ================= */
static NSLock *gLogLock = nil;
static NSString *LogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/pvega_tweak.log"];
}
static void TLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void TLog(NSString *fmt, ...) {
    if (!gLogLock) gLogLock = [[NSLock alloc] init];
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        [gLogLock lock];
        static NSDateFormatter *df = nil;
        if (!df) { df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss"; }
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *p = LogPath();
        if (![fm fileExistsAtPath:p]) [fm createFileAtPath:p contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        [gLogLock unlock];
    }
}

/* ================= 配置（Documents/pvega_config.json，5 秒热重载） ================= */
typedef struct {
    BOOL   master;
    BOOL   autoKill;       /* g 自动杀怪 */
    int    tickMs;         /* 节奏 */
    int    killPerTick;    /* 每拍杀几个 */
    BOOL   spawn;          /* w 刷怪加速 */
    int    spawnRate;      /* 每秒几只 */
    int    spawnLimit;     /* 同屏上限 */
    int    spawnTotal;     /* 总数，0=不限 */
    int    targetPoints;   /* p 分数封顶（0 = 不干预，用游戏原封顶） */
    /* ★ v0.2.0：shotGuard / guardMargin / guardFireMs 已随"最后一发保护"整段删除 */
    BOOL   infiniteAmmo;   /* 无限子弹 */
    float  equipBonus;     /* 装备/联赛得分加成倍数（1.0=不改；2.0=提交分×2；作用于 ReportLevelResult 的 scoreDelta） */
    BOOL   equipHook;      /* ★ v0.3.1：是否安装 ReportLevelResult 钩子（默认关；v0.3.0 该 MSHook 涉嫌结算闪退） */
    BOOL   noKillCam;      /* ★ v0.3.1：安全结算（拦截 ShowKillCam，复刻 FakeKillCam 延迟结算） */
    BOOL   spawnMulti;     /* ★ v0.3.2：是否改写全部运行中的刷怪器（默认关=只写第一个；全部都写=40只/秒 会引擎 SIGABRT） */
} GAConfig;
static GAConfig cfg;

static NSString *ConfigPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/pvega_config.json"];
}
static void ConfigDefaults(GAConfig *c) {
    c->master = YES;
    c->autoKill = YES; c->tickMs = DEF_TICK_MS; c->killPerTick = DEF_KILL_PER_TICK;
    c->spawn = YES; c->spawnRate = DEF_SPAWN_RATE; c->spawnLimit = DEF_SPAWN_LIMIT; c->spawnTotal = DEF_SPAWN_TOTAL;
    c->targetPoints = DEF_TARGET_POINTS;
    c->infiniteAmmo = YES;
    c->equipBonus   = 1.0f;   /* 默认不改提交分 */
    c->noKillCam    = YES;    /* ★ v0.3.1：默认安全结算 */
    c->equipHook    = NO;     /* ★ v0.3.1：装备钩子默认关 */
    c->spawnMulti   = NO;     /* ★ v0.3.2：默认只改第一个刷怪器（防 40只/秒 引擎 abort） */
}
static int cfgInt(NSDictionary *d, NSString *k, int def) {
    id v = d[k];
    if (v && [v isKindOfClass:[NSNumber class]]) { int x = [v intValue]; if (x >= 0) return x; }
    return def;
}
static BOOL cfgBool(NSDictionary *d, NSString *k, BOOL def) {
    id v = d[k];
    if (v && [v isKindOfClass:[NSNumber class]]) return [v boolValue];
    return def;
}
static float cfgFloat(NSDictionary *d, NSString *k, float def) {
    id v = d[k];
    if (v && [v isKindOfClass:[NSNumber class]]) { float x = [v floatValue]; if (x > 0) return x; }
    return def;
}
static void ConfigFromDict(GAConfig *c, NSDictionary *d) {
    c->master       = cfgBool(d, @"master", YES);
    c->autoKill     = cfgBool(d, @"auto_kill", YES);
    c->tickMs       = cfgInt(d, @"tick_ms", DEF_TICK_MS);
    c->killPerTick  = cfgInt(d, @"kill_per_tick", DEF_KILL_PER_TICK);
    c->spawn        = cfgBool(d, @"spawn", YES);
    c->spawnRate    = cfgInt(d, @"spawn_rate", DEF_SPAWN_RATE);
    c->spawnLimit   = cfgInt(d, @"spawn_limit", DEF_SPAWN_LIMIT);
    c->spawnTotal   = cfgInt(d, @"spawn_total", DEF_SPAWN_TOTAL);
    c->targetPoints = cfgInt(d, @"target_points", DEF_TARGET_POINTS);
    /* shot_guard / guard_margin / guard_fire_ms 已删除：json 里留着也会被忽略 */
    c->infiniteAmmo = cfgBool(d, @"infinite_ammo", YES);
    c->equipBonus   = cfgFloat(d, @"equip_bonus", 1.0f);
    if (c->equipBonus < 1.0f) c->equipBonus = 1.0f;   /* 加成只能≥1，<1 视为无效 */
    c->noKillCam    = cfgBool(d, @"no_killcam", YES); /* ★ v0.3.1：安全结算 */
    c->equipHook    = cfgBool(d, @"equip_hook", NO);  /* ★ v0.3.1：装备钩子默认关，改后需重启 */
    c->spawnMulti   = cfgBool(d, @"spawn_multi", NO); /* ★ v0.3.2：默认只改第一个刷怪器 */
    if (c->tickMs < 30) c->tickMs = 30;          /* 太快会压死主线程 */
    if (c->killPerTick < 1) c->killPerTick = 1;
    if (c->spawnLimit < 1) c->spawnLimit = 1;
}
static void WriteDefaultConfig(void) {
    NSString *body =
        @"{\n"
        @"  \"master\": true,\n"
        @"  \"auto_kill\": true,\n"
        @"  \"tick_ms\": 200,\n"
        @"  \"kill_per_tick\": 3,\n"
        @"  \"spawn\": true,\n"
        @"  \"spawn_rate\": 5,\n"
        @"  \"spawn_limit\": 5,\n"
        @"  \"spawn_total\": 0,\n"
        @"  \"target_points\": 500,\n"
        @"  \"infinite_ammo\": true,\n"
        @"  \"equip_bonus\": 1.0,\n"
        @"  \"equip_hook\": false,\n"
        @"  \"spawn_multi\": false,\n"
        @"  \"no_killcam\": true\n"
        @"}\n";
    [body writeToFile:ConfigPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void LoadConfig(void) {
    ConfigDefaults(&cfg);
    NSData *data = [NSData dataWithContentsOfFile:ConfigPath()];
    if (!data) { WriteDefaultConfig(); return; }
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([d isKindOfClass:[NSDictionary class]]) ConfigFromDict(&cfg, d);
}

/* ================= il2cpp API（dlsym，与 aim.js / autohead.js 同一套导出） ================= */
static void* (*il2cpp_domain_get)(void);
static void* (*il2cpp_thread_attach)(void*);
static void* (*il2cpp_domain_get_assemblies)(void*, size_t*);
static void* (*il2cpp_assembly_get_image)(void*);
static const char* (*il2cpp_image_get_name)(void*);
static const char* (*il2cpp_class_get_name)(void*);
static void* (*il2cpp_class_from_name)(void*, const char*, const char*);
static void* (*il2cpp_class_get_type)(void*);
static void* (*il2cpp_type_get_object)(void*);
static void* (*il2cpp_class_get_method_from_name)(void*, const char*, int);
static void* (*il2cpp_runtime_invoke)(void*, void*, void*, void*);
/* ★ 按类名全域兜底要用（autohead.js 的 fc() 同款）：遍历 image 里所有类比对名字 */
static size_t  (*il2cpp_image_get_class_count)(void*);
static void*   (*il2cpp_image_get_class)(void*, size_t);
static BOOL il2cppBound = NO;

static BOOL bindIl2cpp(void) {
    if (il2cppBound) return YES;
    *(void **)&il2cpp_domain_get            = dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    *(void **)&il2cpp_thread_attach         = dlsym(RTLD_DEFAULT, "il2cpp_thread_attach");
    *(void **)&il2cpp_domain_get_assemblies = dlsym(RTLD_DEFAULT, "il2cpp_domain_get_assemblies");
    *(void **)&il2cpp_assembly_get_image    = dlsym(RTLD_DEFAULT, "il2cpp_assembly_get_image");
    *(void **)&il2cpp_image_get_name        = dlsym(RTLD_DEFAULT, "il2cpp_image_get_name");
    *(void **)&il2cpp_class_get_name        = dlsym(RTLD_DEFAULT, "il2cpp_class_get_name");
    *(void **)&il2cpp_class_from_name       = dlsym(RTLD_DEFAULT, "il2cpp_class_from_name");
    *(void **)&il2cpp_class_get_type        = dlsym(RTLD_DEFAULT, "il2cpp_class_get_type");
    *(void **)&il2cpp_type_get_object       = dlsym(RTLD_DEFAULT, "il2cpp_type_get_object");
    *(void **)&il2cpp_class_get_method_from_name = dlsym(RTLD_DEFAULT, "il2cpp_class_get_method_from_name");
    *(void **)&il2cpp_runtime_invoke        = dlsym(RTLD_DEFAULT, "il2cpp_runtime_invoke");
    *(void **)&il2cpp_image_get_class_count = dlsym(RTLD_DEFAULT, "il2cpp_image_get_class_count");
    *(void **)&il2cpp_image_get_class       = dlsym(RTLD_DEFAULT, "il2cpp_image_get_class");
    il2cppBound = (il2cpp_domain_get && il2cpp_thread_attach && il2cpp_domain_get_assemblies &&
                   il2cpp_assembly_get_image && il2cpp_image_get_name && il2cpp_class_from_name &&
                   il2cpp_class_get_type && il2cpp_type_get_object &&
                   il2cpp_class_get_method_from_name && il2cpp_runtime_invoke);
    return il2cppBound;
}
static uintptr_t UFBase(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, "UnityFramework")) return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

/* ================= 类 / 方法绑定 ================= */
static void *ASMS = NULL;                    /* Assembly-CSharp image */
static void *K_coreImg = NULL;               /* UnityEngine.CoreModule image */
static void *K_object = NULL, *K_person = NULL, *K_shooter = NULL;
/* 僵尸专属类已移除（K_halloween / K_zombie / K_hallPerson） */
static void *K_tic = NULL;          /* TournamentInGameController（全球行动控制器） */
static void *K_spawnerH = NULL, *K_spawnerX = NULL, *K_spawnerG = NULL, *K_spawnerG5 = NULL;
static void *mFOOAll = NULL, *mKill1 = NULL;   /* 僵尸专属方法已移除（mHallInst/mHallScore/mHallTD） */
static void *mTicInst = NULL;       /* 全球行动静态单例 get_Instance */
static void *mReport  = NULL;       /* TournamentClient.ReportLevelResult（对局结束提交分，装备加成挂钩点） */
/* ★ v0.3.0：LevelController（关结算慢动作用）。全球行动用的是它的子类
 *   RandomMission.RandomLevelController，get_Instance 拿到的就是当关实例。 */
static void *K_lc     = NULL;
static void *mOnKCF   = NULL;       /* ★ v0.3.1 LevelController.OnKillCamFinished（安全结算终点） */
static void *mShowKC  = NULL;       /* ★ v0.3.1 LevelController.ShowKillCam（挂钩目标，唯一调用点 Win+0x63c） */
static void *mKillDelay = NULL;     /* ★ v0.3.1 CharacterShooter.get_KillDelay（复刻 FakeKillCam 的等待时长） */
/* ★ v0.2.0：mShootD / mShootU / mForceD / mForceU 已随"最后一发保护"整段删除（不再碰开火） */
static void *tPerson = NULL, *tSpawnerH = NULL, *tSpawnerX = NULL, *tSpawnerG = NULL, *tSpawnerG5 = NULL;

/* ★ 所有程序集都存下来（不只 Assembly-CSharp）：类的命名空间可能不在 Assembly-CSharp */
static void *gImgs[96];
static int gImgsN = 0;
static void clsFromAdd(void *img) {
    @try {
        const char *nm = il2cpp_image_get_name(img);
        if (!nm) return;
        if (strstr(nm, "UnityEngine.CoreModule")) K_coreImg = img;
    } @catch (NSException *e) {}
    if (gImgsN < 96) gImgs[gImgsN++] = img;
}
/* ★ 强版查找 = autohead.js 的 fc()：
 *   ① 所有 image 里按 (命名空间, 类名) 找
 *   ② 找不到就在所有 image 里**逐个类比名字**兜底（命名空间经常对不上） */
static void *clsFrom(const char *ns, const char *nm) {
    for (int i = 0; i < gImgsN; i++) {
        void *c = il2cpp_class_from_name(gImgs[i], ns, nm);
        if (c) return c;
    }
    for (int i = 0; i < gImgsN; i++) {
        void *c = il2cpp_class_from_name(gImgs[i], "", nm);
        if (c) return c;
    }
    if (il2cpp_image_get_class_count && il2cpp_image_get_class) {
        for (int i = 0; i < gImgsN; i++) {
            size_t cnt = 0;
            @try { cnt = il2cpp_image_get_class_count(gImgs[i]); } @catch (NSException *e) { continue; }
            for (size_t j = 0; j < cnt; j++) {
                void *cls = NULL;
                @try { cls = il2cpp_image_get_class(gImgs[i], j); } @catch (NSException *e) { continue; }
                if (!cls) continue;
                const char *cn = il2cpp_class_get_name(cls);
                if (cn && strcmp(cn, nm) == 0) return cls;
            }
        }
    }
    return NULL;
}
static void *meth(void *cls, const char *nm, int n) {
    return cls ? il2cpp_class_get_method_from_name(cls, nm, n) : NULL;
}
static void *typeObj(void *cls) {
    if (!cls) return NULL;
    void *t = il2cpp_class_get_type(cls);
    return t ? il2cpp_type_get_object(t) : NULL;
}

static BOOL setupAll(void) {
    void *d = il2cpp_domain_get();
    if (!d) return NO;
    il2cpp_thread_attach(d);
    size_t n = 0;
    void **arr = (void **)il2cpp_domain_get_assemblies(d, &n);
    if (!arr || !n) return NO;
    K_coreImg = NULL;
    ASMS = NULL;
    gImgsN = 0;
    for (size_t i = 0; i < n; i++) {
        void *img = il2cpp_assembly_get_image(arr[i]);
        if (!img) continue;
        clsFromAdd(img);                                   /* ★ 全部存下来，供 clsFrom 兜底遍历 */
        const char *nm = il2cpp_image_get_name(img);
        if (!nm) continue;
        if (strstr(nm, "Assembly-CSharp")) ASMS = img;
    }
    if (!K_coreImg || !ASMS) return NO;
    K_object      = il2cpp_class_from_name(K_coreImg, "UnityEngine", "Object");
    K_person      = clsFrom("Person", "Person");
    K_shooter     = clsFrom("Player", "CharacterShooter");
    K_tic         = clsFrom("", "TournamentInGameController");   /* 全球行动（命名空间兜底） */
    /* 僵尸专属类不再绑定 */
    K_spawnerH    = clsFrom("Game.HalloweenLiveEvent.Sniper3D", "HalloweenLiveEventTimedSpawner");
    K_spawnerX    = clsFrom("Game.ChristmasLiveEvent.Sniper3D", "ChristmasLiveEventTimedSpawner");
    K_spawnerG    = clsFrom("", "TimedSpawner");
    K_spawnerG5   = clsFrom("", "TimedSpawner500");
    if (!K_object || !K_person) return NO;
    mFOOAll    = meth(K_object, "FindObjectsOfTypeAll", 1);
    mKill1     = meth(K_person, "Kill", 1);
    /* 僵尸专属方法不再绑定 */
    mTicInst   = meth(K_tic, "get_Instance", 0);
    mReport    = meth(clsFrom("", "TournamentClient"), "ReportLevelResult", 7);   /* 7 参：(score,head,kill,round,won,weaponId,cb) */
    /* ★ v0.3.0：LevelController（关结算慢动作） */
    K_lc       = clsFrom("", "LevelController");
    mOnKCF     = meth(K_lc, "OnKillCamFinished", 0);
    mShowKC    = meth(K_lc, "ShowKillCam", 0);
    mKillDelay = meth(K_shooter, "get_KillDelay", 0);
    /* 开火入口已移除（v0.2.0 删除最后一发保护） */
    tPerson    = typeObj(K_person);
    tSpawnerH  = typeObj(K_spawnerH);
    tSpawnerX  = typeObj(K_spawnerX);
    tSpawnerG  = typeObj(K_spawnerG);
    tSpawnerG5 = typeObj(K_spawnerG5);
    return (mFOOAll != NULL && mKill1 != NULL);
}

/* ================= 基础工具 ================= */
static void *gExc = NULL;
static void *gArgsBuf[8];
#define FNP(p) ((void *)(uintptr_t)(p))
static void *inv(void *m, void *obj, void **args, int n) {
    if (!m) return NULL;
    if (!gExc) gExc = calloc(1, 8);
    void **p = NULL;
    if (args && n > 0) {
        int c = n < 8 ? n : 8;
        for (int i = 0; i < c; i++) gArgsBuf[i] = args[i];
        p = gArgsBuf;
    }
    *(void **)gExc = NULL;
    void *r = il2cpp_runtime_invoke(m, obj, p, gExc);
    return *(void **)gExc ? NULL : r;
}
static NSString *csStr(void *s) {
    if (!s) return @"";
    int32_t l = *(int32_t *)((char *)s + 0x10);
    if (l <= 0 || l > 200) return @"";
    return [[NSString alloc] initWithCharacters:(const unichar *)((char *)s + 0x14) length:(NSUInteger)l];
}
/* gDmg 已删：它只服务于僵尸的 TakeDamages(1e6,…)，全球行动用 Person.Kill(true)，不需要 double 参数 */
static uint8_t gTrue = 1;      /* Person.Kill(true) 的 bool 参数（gFalse 已删：全球行动不用 TakeDamages） */

/* ================= 运行时状态 ================= */
static BOOL gReady = NO;
static void *shooterInst = NULL;
static long shooterFindAt = 0;
static int  totalKilled = 0;
static long lastKillAt = 0, lastSpawnAt = 0, lastAmmoAt = 0, lastBeatAt = 0;
static long frames = 0;
static BOOL inHallLogged = NO;    /* "进入全球行动关卡"只报一次 */
static BOOL spawnLogged = NO;     /* "刷怪加速生效"只报一次（别和上面共用同一个标志） */
/* 注：僵尸专属的 hallInst / 本局人头 / realKills 已全部移除 */
/* 全球行动控制器（同拍缓存，别每拍都 invoke）
 * ★ v0.2.0：缓存从 400ms 砍到 120ms —— 换局时旧控制器会被销毁，400ms 的窗口
 *   足够让"对局结束那一瞬间"拿到已释放对象再拿去读 _running / 写封顶。 */
static void *ctrlInstCached = NULL;
static long ctrlCacheAt = 0;
static void ctrlDrop(void) { ctrlInstCached = NULL; ctrlCacheAt = 0; }   /* 换局时强制重取 */
static void *ctrlInst(void) {
    long now = (long)(CFAbsoluteTimeGetCurrent() * 1000);
    if (ctrlInstCached && now - ctrlCacheAt < 120) return ctrlInstCached;
    ctrlInstCached = inv(mTicInst, NULL, NULL, 0);
    ctrlCacheAt = now;
    return ctrlInstCached;
}
/* ★ v8.11：任务是否正式开始。准备阶段场上就有预置怪，提前杀不算数还扎眼 */
static BOOL tournamentRunning(void) {
    void *inst = ctrlInst();
    if (!inst) return NO;
    @try { return *(uint8_t *)((char *)inst + TIC_RUNNING) != 0; } @catch (NSException *e) { return NO; }
}
/* 已击杀名单（同一对象只杀一次；换局自动清空）—— 全球行动专用 */
static void *killedList[512];
static int killedN = 0;
static BOOL killedSeen(void *p) {
    for (int i = 0; i < killedN; i++) if (killedList[i] == p) return YES;
    return NO;
}
static void killedPush(void *p) {
    if (killedN >= 512) killedN = 0;         /* 满了就整轮重置（相当于换局） */
    killedList[killedN++] = p;
}

/* ═══ ★ v0.2.0 换局生命周期（防闪退核心）═══════════════════════════════════
 * 换局时上一局的 il2cpp 对象（控制器 / 射手 / 刷怪器 / Person）全部被销毁，
 * 而旧代码这些句柄是**跨局复用**的（shooterInst 缓存 5 秒、ctrlInst 400ms、
 * 刷怪器每次现查但写完就写）—— 于是每局都在往已释放的对象里写，攒几局就把堆写坏
 * ⇒ 表现就是"全球行动玩几把就闪退"，而僵尸那份因为句柄一直能用所以不闪退。
 * 这里在「控制器实例换指针」或「_running 0→1」时统一作废，下一局重新抓。 */
static int  matchId = 0;
static void *lastMatchInst = NULL;
static int  lastMatchRun = 0;
static void *capInstWrote = NULL;      /* 准备阶段已写过封顶的控制器实例（每实例只写一次） */
static void onNewMatch(const char *why) {
    matchId++;
    killedN = 0;                       /* 击杀去重表（对象池会复用旧地址） */
    shooterInst = NULL; shooterFindAt = 0;
    ctrlDrop();
    capInstWrote = NULL;
    spawnLogged = NO;
    inHallLogged = NO;
    TLog(@"[PVE] 换局#%d（%s）→ 已作废 击杀表/射手/控制器缓存/封顶记录（防野指针）", matchId, why);
}
static void matchWatch(void) {
    @try {
        void *ci = ctrlInst();
        int run = 0;
        if (ci) { @try { run = *(uint8_t *)((char *)ci + TIC_RUNNING) ? 1 : 0; } @catch (NSException *e) {} }
        if (ci && run == 1) {
            BOOL changed = (lastMatchInst && lastMatchInst != ci);
            if (lastMatchRun == 0 || changed)
                onNewMatch(changed ? "控制器换新" : "新对局开始");
        }
        lastMatchInst = ci; lastMatchRun = run;
    } @catch (NSException *e) {}
}
static void *findShooter(void) {
    @try {
        void *t = typeObj(K_shooter);
        if (!t) return NULL;
        void *r = inv(mFOOAll, NULL, (void *[]){ t }, 1);
        if (!r) return NULL;
        int n = *(int32_t *)((char *)r + 0x18);
        for (int i = 0; i < n && i < 10; i++) {
            void *s = *(void **)((char *)r + 0x20 + 8 * i);
            if (s) return s;
        }
    } @catch (NSException *e) {}
    return NULL;
}
/* 本局人头（僵尸专属）已移除：全球行动不需要 */

/* ================= g：自动杀怪 ================= */
#define MAX_TARGETS 400
static void *targets[MAX_TARGETS];
static int targetsN = 0;
/* Zombie 包装里的 person 往往**同时**也在 Person 列表里 → 不去重的话，
 * 同一只僵尸会占掉好几个击杀名额（kill_per_tick=5 却只杀了 1 只）。 */
static BOOL targetSeen(void *p) {
    for (int i = 0; i < targetsN; i++) if (targets[i] == p) return YES;
    return NO;
}
static void collectTargets(void) {
    targetsN = 0;
    @try {
        void *r = inv(mFOOAll, NULL, (void *[]){ tPerson }, 1);
        if (r) {
            int n = *(int32_t *)((char *)r + 0x18);
            for (int i = 0; i < n && targetsN < MAX_TARGETS; i++) {
                void *p = *(void **)((char *)r + 0x20 + 8 * i);
                if (!p) continue;
                @try {
                    if (!*(uint8_t *)((char *)p + P_ALIVE)) continue;
                    if (*(uint8_t *)((char *)p + P_DEAD)) continue;
                    if (*(uint8_t *)((char *)p + P_DYING)) continue;
                    targets[targetsN++] = p;
                } @catch (NSException *e) {}
            }
        }
    } @catch (NSException *e) {}
    /* Zombie 包装扫描已移除：全球行动的敌人就是普通 Person，全量扫描 + 存活过滤即可 */
}
static BOOL gaWasRunning = NO;
static long lastKillDiag = 0;
static void killDiag(NSString *why, int ga, int running, int n) {
    long now = (long)(CFAbsoluteTimeGetCurrent() * 1000);
    if (now - lastKillDiag < 5000) return;
    lastKillDiag = now;
    TLog(@"[PVE] 🔎 杀怪诊断: %@（全球行动=%d 任务中=%d 目标数=%d）", why, ga, running, n);
}
static void killTick(void) {
    if (!cfg.autoKill) return;
    /* ★ 双重闸门：① 必须在全球行动关卡（控制器在）② 必须等任务正式开始（_running=1）
     *   少了 ② 会在准备阶段杀掉预置怪（不算分还扎眼）；少了 ① 会在别的模式乱杀人。 */
    void *ci = ctrlInst();
    if (!ci) { killDiag(@"控制器实例=空(get_Instance未绑定/未进关卡)→杀怪+封顶全失效", 0, 0, 0); return; }
    BOOL running = tournamentRunning();
    if (running && !gaWasRunning) killedN = 0;     /* 新一局：清空击杀去重（防对象池复用旧指针导致"杀着杀着就停"） */
    gaWasRunning = running;
    if (!running) { killDiag(@"任务未开始(_running=0)", 1, 0, 0); return; }
    @try {
        collectTargets();
        if (targetsN == 0) { killedN = 0; return; }     /* 换局/场上清空 → 清掉旧标记 */
        if (targetsN <= 3) { killDiag(@"目标数≤3(疑似大厅/菜单 或 敌人不是Person类型)", 1, 1, targetsN); return; }  /* 大厅/菜单不许开杀 */
        int n = 0;
        for (int i = 0; i < targetsN && n < cfg.killPerTick; i++) {
            void *p = targets[i];
            if (!p) continue;
            if (killedSeen(p)) continue;                /* 同一对象只杀一次 */
            killedPush(p);
            @try {
                inv(mKill1, p, (void *[]){ &gTrue }, 1);   /* Person.Kill(headshot=true) */
                n++; totalKilled++;
            } @catch (NSException *e) {}
        }
    } @catch (NSException *e) {}
}

/* 连击注入：2026-10-01 用户要求移除 —— 全球行动没有连击加分，僵尸那份才有。
 * （顺带说明：autohead.js 里它本来就只认僵尸控制器，全球行动无论开关都是空转） */

/* ================= w：刷怪加速（按类名分派偏移） ================= */
typedef struct { int cur, run, left; const char *tag; } SpSpec;
static BOOL specOf(void *cls, SpSpec *out) {
    if (!cls) return NO;
    if (K_spawnerH && cls == K_spawnerH) { out->cur = SP_HALLOW_CUR; out->run = SP_HALLOW_RUN; out->left = SP_HALLOW_LEFT; out->tag = "Halloween"; return YES; }
    if (K_spawnerX && cls == K_spawnerX) { out->cur = SP_HALLOW_CUR; out->run = SP_HALLOW_RUN; out->left = SP_HALLOW_LEFT; out->tag = "Christmas"; return YES; }
    if (K_spawnerG && cls == K_spawnerG) { out->cur = SP_TIMED_CUR;  out->run = SP_TIMED_RUN;  out->left = SP_TIMED_LEFT;  out->tag = "Timed"; return YES; }
    if (K_spawnerG5 && cls == K_spawnerG5) { out->cur = SP_T500_CUR; out->run = SP_T500_RUN;  out->left = SP_T500_LEFT;  out->tag = "Timed500"; return YES; }
    return NO;      /* 认不出就绝不写 */
}
static void spawnTick(void) {
    if (!cfg.spawn || cfg.spawnRate <= 0) return;
    if (!ctrlInst()) return;      /* ★ 只在全球行动关卡动手，别去改别的模式的刷怪器 */
    /* ★ v0.2.0 防闪退：必须**真在对局中**才写刷怪器。
     *   旧代码只要 get_Instance 非空就写，对局结束/结算界面/大厅照样 500ms 一次
     *   往已释放（或下一局还没创建）的 TimedSpawner 里写 7 个字段。 */
    if (!tournamentRunning()) return;
    @try {
        float itv = 1.0f / (float)cfg.spawnRate;
        int total = cfg.spawnTotal > 0 ? cfg.spawnTotal : 500;
        void *clsList[4] = { K_spawnerH, K_spawnerX, K_spawnerG, K_spawnerG5 };
        void *typeList[4] = { tSpawnerH, tSpawnerX, tSpawnerG, tSpawnerG5 };
        int hit = 0, foundN = 0, runningN = 0, skipN = 0;
        const char *hitTag = "-", *skipTag = "-";
        for (int k = 0; k < 4; k++) {
            if (!clsList[k] || !typeList[k]) continue;
            void *r = inv(mFOOAll, NULL, (void *[]){ typeList[k] }, 1);
            if (!r) continue;
            int n = *(int32_t *)((char *)r + 0x18);
            for (int i = 0; i < n && i < 30; i++) {
                void *s = *(void **)((char *)r + 0x20 + 8 * i);
                if (!s) continue;
                foundN++;
                SpSpec sp;
                if (!specOf(*(void **)s, &sp)) continue;      /* 按实例的实际类取偏移 */
                @try {
                    if (!*(uint8_t *)((char *)s + sp.run)) continue;   /* 只在波次进行中改 */
                    runningN++;
                    /* ★ v0.3.2：每拍只写**第一个**运行中的刷怪器（spawn_multi=false 默认）。
                     * 真机铁证：1 个刷怪器@20只/秒 = 连打 4 局稳定；2 个刷怪器各 20 只/秒
                     * = 全场 40 只/秒，Unity 引擎 4~6 秒内在渲染循环 SIGABRT（崩溃报告
                     * 逐帧相同，引擎主动 abort，与地图无关）。总怪量=配置值不变。 */
                    if (!cfg.spawnMulti && hit >= 1) { skipN++; skipTag = sp.tag; continue; }
                    *(float *)((char *)s + SP_TOTAL_MIN) = (float)total;
                    *(float *)((char *)s + SP_TOTAL_MAX) = (float)total;
                    *(float *)((char *)s + SP_ITV_MIN) = itv;
                    *(float *)((char *)s + SP_ITV_MAX) = itv;
                    *(int32_t *)((char *)s + SP_LIMIT) = cfg.spawnLimit;
                    *(float *)((char *)s + sp.cur) = itv;
                    *(int32_t *)((char *)s + sp.left) = total > 1 ? total : 1;
                    hit++;
                    hitTag = sp.tag;
                } @catch (NSException *e) {}
            }
        }
        if (hit && !spawnLogged) {
            spawnLogged = YES;
            /* ★ %@ 不是 %s：hitTag 是 C 串用 %s；skipN 提示是 NSString 字面量必须 %@（-Wformat/-Werror） */
            /* ★ 日志显示实际写入值：spawn_total=0 时内部写 500（此前打"总数 0"误导排查） */
            TLog(@"[PVE] 刷怪加速生效：%d 只/秒 · 同屏 %d · 总数 %d（已改写 %d 个[%s]%@）",
                 cfg.spawnRate, cfg.spawnLimit, cfg.spawnTotal > 0 ? cfg.spawnTotal : 500, hit, hitTag,
                 skipN > 0 ? @"；其余只改第一个（spawn_multi=false，防引擎 40只/秒 崩溃）" : @"");
        }
        /* ★ 刷怪诊断（10 秒一条）：四段数字能一次定位卡在哪一环
         *   全球行动=0  → ctrlInst() 拿不到（控制器类/方法没找到）⇒ 全部功能哑火
         *   实例=0      → 刷怪器类没找到，或当前不在可刷怪的关卡
         *   运行中=0    → _running 偏移不对，或波次还没开始
         *   已改写=0 但运行中>0 → spec 匹配失败（实例是子类，klass 比对不上） */
        static long lastSpawnDiag = 0;
        long nowD = (long)(CFAbsoluteTimeGetCurrent() * 1000);
        if (nowD - lastSpawnDiag > 10000) {
            lastSpawnDiag = nowD;
            TLog(@"[PVE] 🔎 刷怪诊断: 全球行动=%d 实例=%d 运行中=%d 已改写=%d[%s] 跳过=%d[%s]（spawn=%d rate=%d multi=%d）",
                 ctrlInst() ? 1 : 0, foundN, runningN, hit, hitTag, skipN, skipTag,
                 cfg.spawn ? 1 : 0, cfg.spawnRate, cfg.spawnMulti ? 1 : 0);
        }
    } @catch (NSException *e) {}
}

/* ================= p：分数封顶（恒定自愈写） =================
 * 结束判定：_points(+0x44) >= _targetPoints(+0x28) + (_useCapBonus(+0x54) ? _capBonus(+0x50) : 0)
 * ⇒ 把 _useCapBonus 置 0，封顶就等于 _targetPoints 本身；被游戏重设会自动再写。 */
static void targetTick(void) {
    if (cfg.targetPoints <= 0) return;
    @try {
        void *inst = ctrlInst();
        if (!inst) {
            static long tCap = 0; long now = (long)(CFAbsoluteTimeGetCurrent() * 1000);
            if (now - tCap > 8000) { tCap = now; TLog(@"[PVE] 🔎 封顶诊断: 控制器实例=空 → 封顶无法写入（get_Instance 未绑定或还没进全球行动关卡）"); }
            return;
        }
        /* ★ v0.2.0 防闪退：分两种情形
         *   (a) 对局中（_running=1）：对象确定活着 → 每拍自愈写（被游戏重设会自动再写）
         *   (b) 非对局中（准备阶段/结算界面/大厅）：**每个控制器实例只写一次**。
         *       旧代码是每秒无条件写，对局结束后控制器已释放还在写 ⇒ 每秒往死对象写 8 字节，
         *       攒几局把堆写坏 —— 这是"玩几把就闪退"最主要的来源。 */
        int running = 0;
        @try { running = *(uint8_t *)((char *)inst + TIC_RUNNING) ? 1 : 0; } @catch (NSException *e) {}
        if (!running) {
            if (capInstWrote == inst) return;      /* 本实例已经写过，不再碰 */
            capInstWrote = inst;
        }
        /* ★ 先关掉 capBonus 叠加 —— 之前是「cur==目标分就跳过」，
         *   若游戏默认目标分恰好=1000 会整拍跳过、永远不关 capBonus ⇒ 封顶=1000+capBonus≠1000。 */
        *(uint8_t *)((char *)inst + TIC_USECAP) = 0;
        int cur = *(int32_t *)((char *)inst + TIC_TARGET);
        if (cur != cfg.targetPoints) {
            *(int32_t *)((char *)inst + TIC_TARGET) = cfg.targetPoints;
            static long lastCapMsg = 0;
            long now = (long)(CFAbsoluteTimeGetCurrent() * 1000);
            if (now - lastCapMsg > 5000) {
                lastCapMsg = now;
                /* ★ %@ 不是 %s：这里传的是 NSString*（ObjC 对象），写 %s 会被 -Wformat 判为
                 *   "format specifies type 'char *'" 而 -Werror 直接编译失败（v0.2.0 踩过） */
                TLog(@"[PVE] 封顶: 目标分 %d → %d（已关 capBonus 叠加%@）", cur, cfg.targetPoints,
                     running ? @"；对局中，被游戏重设会自动再写" : @"；准备阶段，本实例只写一次");
            }
        }
    } @catch (NSException *e) {}
}

/* ═══ ★ v0.3.1 n：安全结算（拦截 ShowKillCam，复刻官方 FakeKillCam）═══════════
 * v0.3.0 的 1 字节补丁（+0x101=0 ⇒ Win(false) ⇒ else 分支立即 OnKillCamFinished）
 * 真机仍闪退：自动杀怪 1~2 秒清空目标 → 立即结算 → 进程消失（无 .ips）。
 * 而官方自己的"无弹结算" FakeKillCam（0x32B5BF8 / MoveNext 0x32B96D0）是：
 *   帧0: CharacterShooter.ShowFeedbacks(_player) + 读 get_KillDelay(_player) → WaitForSeconds
 *   帧1: 经 klass+0x338 vtable slot 调 OnKillCamFinished() —— 【隔了整整 KillDelay 秒】。
 * 我们提前了这一个镜头的时长，结算 UI 在死亡动画未清理时弹出 ⇒ 闪退（嫌疑 Y）；
 * 另 ReportLevelResult 的 MSHook 从未真机验证过（嫌疑 X，v0.3.1 起改为 equip_hook 默认关）。
 *
 * v0.3.1 做法：MSHook LevelController::ShowKillCam（无参，全二进制唯一调用点 = Win+0x63c，
 * 子弹镜头走的是 CharacterShooter::ShowKillCam（0x34F6098），互不相干 ⇒ 零副作用）。
 * 替换体：等 get_KillDelay 秒（缺省 2s，钳 [1,5]）→ 主线程 runtime_invoke
 * OnKillCamFinished → 之后全部是游戏原生结算/上报链。没开最后一枪也能正常结算。 */
static void (*orig_ShowKillCam)(void *self) = NULL;
static void *settleLc = NULL;           /* 防同关重复结算（双保险） */
static long  settleAt = 0;
static void my_ShowKillCam(void *self) {
    @try {
        /* ★ v0.4.0 模式门禁：只在全球行动关卡接管结算；别的模式（含 PVP）一律放行原版 KillCam，
         *   否则会劫持 PVP/其它模式的击杀镜头与结算链。 */
        if (!cfg.noKillCam || !gReady || !mOnKCF || !ctrlInst()) {
            if (orig_ShowKillCam) orig_ShowKillCam(self);   /* 开关关闭 / 不在全球行动 → 原生行为 */
            return;
        }
        long now = (long)(CFAbsoluteTimeGetCurrent() * 1000);
        if (settleLc == self && now - settleAt < 30000) return;   /* 同一关卡 30 秒内只排一次 */
        settleLc = self; settleAt = now;
        float kd = 2.0f;    /* FakeKillCam 用 get_KillDelay(_player)；拿不到就给保守默认值 */
        @try {
            void *player = *(void **)((char *)self + LC_PLAYER);
            if (player && mKillDelay) {
                void *boxed = inv(mKillDelay, player, NULL, 0);   /* get_KillDelay 返回装箱 float */
                if (boxed) kd = *(float *)((char *)boxed + 0x10);
            }
        } @catch (NSException *e) {}
        if (kd < 1.0f) kd = 1.0f;
        if (kd > 5.0f) kd = 5.0f;
        TLog(@"[PVE] 结算: 已拦截空命中慢动作 → %.1f 秒后安全结算（复刻 FakeKillCam，无 KillCam）", (double)kd);
        void *lc = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kd * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           @try {
                               if (mOnKCF) inv(mOnKCF, lc, NULL, 0);
                           } @catch (NSException *e) {}
                       });
    } @catch (NSException *e) {}
}

/* ═══ m：最后一发保护 —— v0.2.0 已【整段删除】════════════════════════════════
 * 删除原因（用户拍板 + 与 autohead.js v8.40 同步）：
 *   1) 写法本身就是错的：狙击是"松手开枪"（ShootUp 尾部才 TryNormalShoot），
 *      而 v0.1.0 的实现是【按下就不松手】⇒ 一枪都没打出去 ⇒ 它想防的终局空引用
 *      该崩还是崩（用户实测：保护触发了、日志有记录，照样闪退）。
 *   2) 8Hz 反复调 ShootDown 会把 CharacterShooter 的状态机搅乱（正常玩家不会这么按）。
 *   3) 它每拍都在读控制器 +0x44/+0x28/+0x40，是又一处跨局野句柄读写。
 * ⇒ 最后一发交给玩家自己开枪，脚本彻底不碰开火。
 * （配合上面的换局生命周期 + 对局门，全球行动的闪退源已经全部摘掉。） */

/* ================= 无限子弹 ================= */
static void refillAmmo(void) {
    if (!cfg.infiniteAmmo) return;
    /* ★ v0.2.0 防闪退：必须真在对局中才写弹药。
     *   旧代码是**每帧**写（60Hz），而 shooterInst 缓存 5 秒 ⇒ 换局后最多
     *   60×5 = 300 次往已释放的射手对象里写弹药，堆写坏得比谁都快。 */
    if (!tournamentRunning()) return;
    @try {
        if (!shooterInst) return;
        void *list = *(void **)((char *)shooterInst + CS_AMMO_LIST);
        if (!list) return;
        int n = *(int32_t *)((char *)list + 0x18);
        void *items = *(void **)((char *)list + 0x10);
        if (!items) return;
        for (int i = 0; i < n && i < 8; i++) {
            void *e = *(void **)((char *)items + 0x20 + 8 * i);
            if (!e) continue;
            int cur = *(int32_t *)((char *)e + AMMO_CUR);
            int max = *(int32_t *)((char *)e + AMMO_MAX);
            if (max > 0 && cur != max) *(int32_t *)((char *)e + AMMO_CUR) = max;
        }
    } @catch (NSException *e) {}
}

/* ================= 帧驱动 ================= */
static void frame(void) {
    @try {
        frames++;
        long now = (long)(CFAbsoluteTimeGetCurrent() * 1000);
        if (!gReady) return;
        /* ★ master 总开关：运行中热改成 false 也要立刻全部停手 */
        if (!cfg.master) return;

        /* ★ v0.2.0：换局探测放最前面（作废跨局句柄） */
        matchWatch();

        void *inst = ctrlInst();
        /* ★★★ 模式门禁（2026-10-03 用户要求：三份 deb 并存，只在各自模式开功能）：
         *   TournamentInGameController 实例在 = 真的在全球行动关卡；否则一律待机，
         *   无限子弹/杀怪/刷怪/封顶 一个都不启用（以前无限子弹在菜单/PVP/僵尸都在补弹）。 */
        if (!inst) {
            if (inHallLogged) {
                inHallLogged = NO;
                TLog(@"[PVE] 离开全球行动关卡 → 功能待机（无限子弹/杀怪/刷怪/封顶 全部停手；结算钩子也放行原版）");
            }
            shooterInst = NULL; shooterFindAt = 0;   /* 清掉跨模式句柄，防野指针 */
            return;
        }
        if (!inHallLogged) {
            inHallLogged = YES;
            TLog(@"[PVE] 进入全球行动关卡 → 常驻功能全部生效");
        }
        if (now - lastKillAt >= cfg.tickMs)   { lastKillAt = now; killTick(); }
        /* 连击注入已移除 */
        if (now - lastSpawnAt >= 1000)        { lastSpawnAt = now; spawnTick(); }  /* 500ms→1000ms（减负） */
        if (now - lastAmmoAt  >= 200)         { lastAmmoAt = now;                  /* 每帧→每200ms */
            if (!shooterInst || now - shooterFindAt > 5000) { shooterInst = findShooter(); shooterFindAt = now; }
            refillAmmo();
        }
        targetTick();                                                             /* 封顶自愈（内部自带对局门） */

        if (now - lastBeatAt > 10000) {
            lastBeatAt = now;
            TLog(@"[PVE] 心跳 帧=%ld 全球行动=%d 任务中=%d 累计击杀=%d 刷怪=%d只/秒 封顶=%d 局数=%d 无限子弹=%d 安全结算=%d",
                 frames, inst ? 1 : 0, tournamentRunning() ? 1 : 0, totalKilled,
                 cfg.spawn ? cfg.spawnRate : 0, cfg.targetPoints, matchId, cfg.infiniteAmmo ? 1 : 0,
                 cfg.noKillCam ? 1 : 0);
        }
    } @catch (NSException *e) { TLog(@"[PVE] frame 异常: %@", e); }
}

static void (*orig_LateUpdate)(void *self) = NULL;
static void my_LateUpdate(void *self) {
    @try {
        if (orig_LateUpdate) orig_LateUpdate(self);
        frame();
    } @catch (NSException *e) { TLog(@"[PVE] LateUpdate 异常（已吞，防连锁崩）: %@", e); }
}

/* ★ 装备/联赛得分加成：挂钩 TournamentClient.ReportLevelResult（对局结束一次性提交）。
 *   游戏在此把最终分 scoreDelta（已含自然装备加成 ~1.63）提交到 WorldOps.Reward。
 *   equip_bonus 是「再乘一个倍数」：1.0=不改；2.0=提交分×2。
 *   为不破坏服务器「scoreDelta ≤ kills×5」的每杀均分校验，kills/headshots 同比例放大
 *   （headshots 不超过 kills），这样均分比例不变、校验仍能过。 */
static void (*orig_ReportLevelResult)(void *self, int scoreDelta, int headshots, int kills,
                                      int roundType, BOOL won, void *weaponId, void *callback);
static void my_ReportLevelResult(void *self, int scoreDelta, int headshots, int kills,
                                 int roundType, BOOL won, void *weaponId, void *callback) {
    /* ★ v0.4.0 模式门禁：只在全球行动关卡生效（该钩子默认不安装：equip_hook=false） */
    if (cfg.master && cfg.equipBonus > 1.0001f && ctrlInst()) {
        double f = (double)cfg.equipBonus;
        int sd = (int)((double)scoreDelta * f);
        int k  = (int)((double)kills * f);
        int h  = (int)((double)headshots * f);
        if (h > k) h = k;
        TLog(@"[PVE] 🔧 装备加成 ×%.2f：score %d→%d，kills %d→%d，head %d→%d", f, scoreDelta, sd, kills, k, headshots, h);
        orig_ReportLevelResult(self, sd, h, k, roundType, won, weaponId, callback);
    } else {
        orig_ReportLevelResult(self, scoreDelta, headshots, kills, roundType, won, weaponId, callback);
    }
}

/* ================= 1 秒兜底（未进关卡时也能维护配置热重载 / 心跳） ================= */
static NSTimer *gTimer = nil;
static long lastCfgMtime = 0;
static void tick1s(NSTimer *t) {
    @try {
        (void)t;
        /* 配置热重载：每 5 秒 stat 一次（和 SniperPVP 同一套写法，不用 ObjC 字典，
         * 免得 id 链式发消息在 ObjC++ 下出类型歧义） */
        static long lastCfgChk = 0;
        long now1s = (long)(CFAbsoluteTimeGetCurrent() * 1000);
        if (now1s - lastCfgChk > 5000) {
            lastCfgChk = now1s;
            struct stat st;
            NSString *p = ConfigPath();
            if (stat([p UTF8String], &st) == 0) {
                long mt = (long)st.st_mtime;
                if (lastCfgMtime && mt != lastCfgMtime) { LoadConfig(); TLog(@"[PVE] 配置已热重载"); }
                lastCfgMtime = mt;
            }
        }
        if (!gReady) return;
        if (!cfg.master) return;                 /* master 关了就什么都不做 */
        /* ★ v0.2.0：1 秒定时器不再重复跑 frame() 里已有的活（旧代码每秒额外再写一遍
         *   弹药/刷怪器/封顶，等于把写入频率翻倍，也把野指针写入的机会翻倍）。
         *   这里只做两件事：换局探测 + 未进关卡时维护射手实例。 */
        matchWatch();
        /* ★ v0.4.0 模式门禁：非全球行动模式 → 只维护换局探测与配置热重载，不碰射手/不补弹 */
        if (!ctrlInst()) { shooterInst = NULL; return; }
        if (!shooterInst) shooterInst = findShooter();
    } @catch (NSException *e) {}
}
@interface ZBTimerTarget : NSObject
+ (instancetype)shared;
- (void)tick:(NSTimer *)t;
@end
@implementation ZBTimerTarget
+ (instancetype)shared { static ZBTimerTarget *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [self new]; }); return s; }
- (void)tick:(NSTimer *)t { tick1s(t); }
@end

/* ================= 启动：★ 全部在主线程，绝不起后台探测线程 =================
 * ⚠️ SniperPVP 的血泪教训（两份 .ips 实证）：后台 pthread 调 il2cpp 会撞 Unity
 *    初始化窗口 → 拿到半成品 domain → 内部 NULL+0x135 SIGSEGV。
 *    这里 %ctor 只排主队列，探测用 dispatch_after 单步重试。 */
static void setupStep(void);
static void retrySetup(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ setupStep(); });
}
static void setupStep(void) {
    if (!bindIl2cpp()) { retrySetup(); return; }
    if (!UFBase()) { retrySetup(); return; }               /* UnityFramework 还没映射 */
    void *dm = il2cpp_domain_get();
    if (!dm) { retrySetup(); return; }
    il2cpp_thread_attach(dm);
    if (!setupAll()) { retrySetup(); return; }             /* Assembly-CSharp 可能还没加载 */
    @try {
        gReady = YES;
        void *mLate = meth(clsFrom("Player", "CameraMovement"), "LateUpdate", 0);
        if (mLate && *(void **)mLate) {
            MSHookFunction(*(void **)mLate, (void *)my_LateUpdate, (void **)&orig_LateUpdate);
            if (orig_LateUpdate) TLog(@"[PVE] ✅ LateUpdate 已挂钩（杀怪/连击/刷怪/时长 全在此驱动）");
            else TLog(@"[PVE] ⚠️ LateUpdate 挂钩失败（功能改由 1 秒定时器维护）");
        } else {
            TLog(@"[PVE] ⚠️ 拿不到 CameraMovement.LateUpdate —— 600ms 后重试");
            retrySetup();
            return;
        }
        /* ★ v0.3.1 安全结算挂钩：LevelController.ShowKillCam（空命中的唯一入口，Win+0x63c） */
        if (mShowKC && *(void **)mShowKC) {
            MSHookFunction(*(void **)mShowKC, (void *)my_ShowKillCam, (void **)&orig_ShowKillCam);
            if (orig_ShowKillCam)
                TLog(@"[PVE] ✅ ShowKillCam 已挂钩（安全结算：不开最后一枪也能正常结算）");
            else
                TLog(@"[PVE] ⚠️ ShowKillCam 挂钩失败 → 不开最后一枪会卡结算（no_killcam 无效）");
        } else {
            TLog(@"[PVE] ⚠️ LevelController.ShowKillCam 未绑定 → 安全结算不可用（no_killcam 无效）");
        }
        /* ★ 装备加成挂钩：v0.3.1 起改为 equip_hook 默认关（v0.3.0 的 MSHook 涉嫌结算闪退，
         *   JS 侧同位置的 Frida attach 已实证无害，Substrate 跳板未验证过 —— 开了再试）。
         *   改 equip_hook / equip_bonus 后需重启游戏生效。 */
        if (mReport && *(void **)mReport) {
            if (cfg.equipHook && cfg.equipBonus > 1.0001f) {
                MSHookFunction(*(void **)mReport, (void *)my_ReportLevelResult, (void **)&orig_ReportLevelResult);
                if (orig_ReportLevelResult)
                    TLog(@"[PVE] ✅ ReportLevelResult 已挂钩（equip_hook=1，装备加成 ×%.2f）", (double)cfg.equipBonus);
                else
                    TLog(@"[PVE] ⚠️ ReportLevelResult 挂钩失败（装备加成选项无效，其余功能正常）");
            } else {
                TLog(@"[PVE] 装备加成钩子未启用（equip_hook=0 或 equip_bonus=1.0；v0.3.1 默认关闭）");
            }
        } else {
            TLog(@"[PVE] ⚠️ TournamentClient.ReportLevelResult 未绑定 → 装备加成选项无效");
        }
        /* ★ 绑定结果自检：哪一项是 0，就是那一环没找到（刷怪不生效先看这里） */
        TLog(@"[PVE] 🔎 类绑定: Person=%d 射手=%d 全球控制器=%d ｜刷怪器 僵尸=%d 圣诞=%d 通用=%d 500=%d",
             K_person ? 1 : 0, K_shooter ? 1 : 0, K_tic ? 1 : 0,
             K_spawnerH ? 1 : 0, K_spawnerX ? 1 : 0, K_spawnerG ? 1 : 0, K_spawnerG5 ? 1 : 0);
        TLog(@"[PVE] 🔎 方法绑定: 全量查找=%d Kill=%d 全球单例=%d 提交分=%d 安全结算=%d/%d/%d（开火方法已不再绑定：v0.2.0 删除最后一发保护）",
             mFOOAll ? 1 : 0, mKill1 ? 1 : 0, mTicInst ? 1 : 0, mReport ? 1 : 0,
             mShowKC ? 1 : 0, mOnKCF ? 1 : 0, mKillDelay ? 1 : 0);
        if (!mTicInst) TLog(@"[PVE] ⚠️ 全球行动控制器 get_Instance 未绑定！封顶/杀怪/刷怪 全部会失效（确认 IL2CPP 里 TournamentInGameController 存在且属性 getter 名为 get_Instance）");
        if (!mShowKC || !mOnKCF) TLog(@"[PVE] ⚠️ ShowKillCam/OnKillCamFinished 未绑定 → 安全结算不可用（no_killcam 无效，最后一发仍需你自己开枪）");
        gTimer = [NSTimer timerWithTimeInterval:1.0 target:[ZBTimerTarget shared] selector:@selector(tick:) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
        TLog(@"[PVE] 🎯 SniperPVEGA v%s 就绪（杀怪=%d 每%dms×%d个=每秒%.0f个｜刷怪=%d只/秒 同屏%d 总数%d｜封顶=%d分｜无限子弹=%d｜安全结算=%d）"
             @" —— 换局自动作废句柄 · 安全结算（不开最后一枪也能结算）· 日志: Documents/pvega_tweak.log",
             TWEAK_VERSION, cfg.autoKill ? 1 : 0, cfg.tickMs, cfg.killPerTick,
             (double)1000.0 / (double)cfg.tickMs * (double)cfg.killPerTick,
             cfg.spawn ? cfg.spawnRate : 0, cfg.spawnLimit, cfg.spawnTotal,
             cfg.targetPoints, cfg.infiniteAmmo ? 1 : 0, cfg.noKillCam ? 1 : 0);
    } @catch (NSException *e) { TLog(@"[PVE] 启动异常: %@", e); retrySetup(); }
}

%ctor {
    /* 只做一件事：把一切排到主队列。
     * dylib 构造期（main() 之前）Foundation/沙盒/ICU 都未必就绪 —— 这里一个都不碰。 */
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            @try {
                LoadConfig();
                NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
                if (![bid isEqualToString:@BUNDLE_SNIPER3D]) { TLog(@"[PVE] 非 Sniper3D（%@）→ 不启用", bid); return; }
                if (!cfg.master) { TLog(@"[PVE] master=false → 本轮不启用（改成 true 才工作；此刻不碰 il2cpp）"); return; }
                TLog(@"[PVE] [LOADED] target=%@ v%s（SniperPVEGA）", bid, TWEAK_VERSION);
                setupStep();
            } @catch (NSException *e) {}
        }
    });
}
