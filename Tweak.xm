/* ============================================================================
 * SniperPVEGA — Sniper3D PVE【全球行动】tweak（autohead.js v8.38 模式2 的原生移植）
 * 注入方式：Dopamine 运行时注入（不动磁盘二进制，TNG 已验证的路线）
 *
 * 功能模块（对应 autohead.js 的模式 2 常驻项）：
 *   g  自动杀怪：每 tick_ms 杀 kill_per_tick 个，固定爆头（Person.Kill(true)）
 *       ★ 必须等 _running=1（任务正式开始）才动手 —— 准备阶段的预置怪杀了不算数还扎眼
 *   p  分数封顶：TournamentInGameController._targetPoints 恒定写目标分，并关 capBonus
 *       ⇒ 到分就结算，被游戏重设会自动再写（自愈）
 *   m  最后一发保护：距满分 ≤ guard_margin 分时持续模拟开火键
 *       （实测：满分瞬间若没真实弹道记录，终局 KillCam 空引用会秒退）
 *   w  刷怪加速：写【通用 TimedSpawner】的 间隔/总数/同屏上限（按类名分派偏移）
 *   ∞  无限子弹：每把枪 currentAmmo 常驻写满 maxAmmo
 *   （连击注入已移除：全球行动没有连击加分，僵尸模式才有）
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

#define TWEAK_VERSION "0.1.0"
#define BUNDLE_SNIPER3D "com.fungames.sniper3d"

/* ★ 默认参数（会被配置覆盖）—— 必须定义在文件头，ConfigDefaults() 要用 */
/* ★ 2026-10-01 用户指定：节奏 200ms、每秒杀 20 个、刷怪常年 20 只/秒、保护段距满分 250 分 */
#define DEF_TICK_MS        200      /* 杀怪节奏：每 200ms 一拍 → 5 拍/秒 */
#define DEF_KILL_PER_TICK  4        /* 每拍杀 4 个 ⇒ 5 × 4 = **每秒 20 个**（用户要的目标值） */
#define DEF_SPAWN_RATE     20       /* 每秒刷 20 只（常驻 20） */
#define DEF_SPAWN_LIMIT    20       /* 同屏上限（可自设） */
#define DEF_SPAWN_TOTAL    0        /* 0 = 不限（内部用 500） */
#define DEF_TARGET_POINTS  1000     /* 分数封顶 = 1000（OPS_TARGET_POINTS） */
#define DEF_GUARD_MARGIN   250      /* 距满分还剩 250 分 → 进入保护段 */
#define DEF_GUARD_FIRE_MS  120      /* 保护段【按住连发】：每 120ms 补一次"按下"（全程不松手） */

/* 全球行动控制器 TournamentInGameController */
#define TIC_RUNNING     0x40        /* _running：StartCounting() 置 1，Finish() 清 0 */
#define TIC_TARGET      0x28        /* _targetPoints（封顶分） */
#define TIC_POINTS      0x44        /* _points（实时分，不是右上角 UI） */
#define TIC_CAPBONUS    0x50        /* _capBonus */
#define TIC_USECAP      0x54        /* _useCapBonus（置 0 = 不叠加，封顶就等于 _targetPoints） */
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
    BOOL   shotGuard;      /* m 最后一发保护（快满分时持续开火防秒退） */
    int    guardMargin;    /* 距满分还剩多少分进入保护段 */
    int    guardFireMs;    /* 保护段内多少毫秒点一次开火键 */
    BOOL   infiniteAmmo;   /* 无限子弹 */
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
    c->shotGuard = YES; c->guardMargin = DEF_GUARD_MARGIN; c->guardFireMs = DEF_GUARD_FIRE_MS;
    c->infiniteAmmo = YES;
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
    c->shotGuard    = cfgBool(d, @"shot_guard", YES);
    c->guardMargin  = cfgInt(d, @"guard_margin", DEF_GUARD_MARGIN);
    c->guardFireMs  = cfgInt(d, @"guard_fire_ms", DEF_GUARD_FIRE_MS);
    c->infiniteAmmo = cfgBool(d, @"infinite_ammo", YES);
    if (c->tickMs < 30) c->tickMs = 30;          /* 太快会压死主线程 */
    if (c->killPerTick < 1) c->killPerTick = 1;
    if (c->spawnLimit < 1) c->spawnLimit = 1;
    if (c->guardFireMs < 100) c->guardFireMs = 100;
}
static void WriteDefaultConfig(void) {
    NSString *body =
        @"{\n"
        @"  \"master\": true,\n"
        @"  \"auto_kill\": true,\n"
        @"  \"tick_ms\": 200,\n"
        @"  \"kill_per_tick\": 4,\n"
        @"  \"spawn\": true,\n"
        @"  \"spawn_rate\": 20,\n"
        @"  \"spawn_limit\": 20,\n"
        @"  \"spawn_total\": 0,\n"
        @"  \"target_points\": 1000,\n"
        @"  \"shot_guard\": true,\n"
        @"  \"guard_margin\": 250,\n"
        @"  \"guard_fire_ms\": 120,\n"
        @"  \"infinite_ammo\": true\n"
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
/* 开火（最后一发保护用）：走游戏自己的开火路径，换弹/弹药/冷却全部由游戏判断 */
static void *mShootD = NULL, *mShootU = NULL, *mForceD = NULL, *mForceU = NULL;
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
    /* 开火入口（狙击是"松手开枪"：ShootUp 尾部才 TryNormalShoot ⇒ 必须成对调） */
    mShootD    = meth(K_shooter, "ShootDown", 0);
    mShootU    = meth(K_shooter, "ShootUp", 0);
    mForceD    = meth(K_shooter, "ForceTouchShootDown", 0);
    mForceU    = meth(K_shooter, "ForceTouchShootUp", 0);
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
static long lastKillAt = 0, lastSpawnAt = 0, lastTimeAt = 0, lastBeatAt = 0;
static long frames = 0;
static BOOL inHallLogged = NO;    /* "进入全球行动关卡"只报一次 */
static BOOL spawnLogged = NO;     /* "刷怪加速生效"只报一次（别和上面共用同一个标志） */
/* 注：僵尸专属的 hallInst / 本局人头 / realKills 已全部移除 */
/* 全球行动控制器（同拍缓存，别每拍都 invoke） */
static void *ctrlInstCached = NULL;
static long ctrlCacheAt = 0;
static void *ctrlInst(void) {
    long now = (long)(CFAbsoluteTimeGetCurrent() * 1000);
    if (ctrlInstCached && now - ctrlCacheAt < 400) return ctrlInstCached;
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
static void killTick(void) {
    if (!cfg.autoKill) return;
    /* ★ 双重闸门：① 必须在全球行动关卡（控制器在）② 必须等任务正式开始（_running=1）
     *   少了 ② 会在准备阶段杀掉预置怪（不算分还扎眼）；少了 ① 会在别的模式乱杀人。 */
    if (!ctrlInst()) return;
    if (!tournamentRunning()) return;
    @try {
        collectTargets();
        if (targetsN == 0) { killedN = 0; return; }     /* 换局/场上清空 → 清掉旧标记 */
        if (targetsN <= 3) return;                      /* 大厅/菜单不许开杀 */
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
    @try {
        float itv = 1.0f / (float)cfg.spawnRate;
        int total = cfg.spawnTotal > 0 ? cfg.spawnTotal : 500;
        void *clsList[4] = { K_spawnerH, K_spawnerX, K_spawnerG, K_spawnerG5 };
        void *typeList[4] = { tSpawnerH, tSpawnerX, tSpawnerG, tSpawnerG5 };
        int hit = 0, foundN = 0, runningN = 0;
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
                    *(float *)((char *)s + SP_TOTAL_MIN) = (float)total;
                    *(float *)((char *)s + SP_TOTAL_MAX) = (float)total;
                    *(float *)((char *)s + SP_ITV_MIN) = itv;
                    *(float *)((char *)s + SP_ITV_MAX) = itv;
                    *(int32_t *)((char *)s + SP_LIMIT) = cfg.spawnLimit;
                    *(float *)((char *)s + sp.cur) = itv;
                    *(int32_t *)((char *)s + sp.left) = total > 1 ? total : 1;
                    hit++;
                } @catch (NSException *e) {}
            }
        }
        if (hit && !spawnLogged) {
            spawnLogged = YES;
            TLog(@"[PVE] 刷怪加速生效：%d 只/秒 · 同屏 %d · 总数 %d（命中 %d 个刷怪器）",
                 cfg.spawnRate, cfg.spawnLimit, cfg.spawnTotal > 0 ? cfg.spawnTotal : 0, hit);
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
            TLog(@"[PVE] 🔎 刷怪诊断: 全球行动=%d 刷怪器实例=%d 运行中=%d 已改写=%d（spawn=%d rate=%d）",
                 ctrlInst() ? 1 : 0, foundN, runningN, hit, cfg.spawn ? 1 : 0, cfg.spawnRate);
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
        if (!inst) return;
        int cur = *(int32_t *)((char *)inst + TIC_TARGET);
        if (cur == cfg.targetPoints) return;
        *(int32_t *)((char *)inst + TIC_TARGET) = cfg.targetPoints;
        *(uint8_t *)((char *)inst + TIC_USECAP) = 0;
        static long lastCapMsg = 0;
        long now = (long)(CFAbsoluteTimeGetCurrent() * 1000);
        if (now - lastCapMsg > 5000) {
            lastCapMsg = now;
            TLog(@"[PVE] 封顶: 目标分 %d → %d（已关 capBonus 叠加；被游戏重设会自动再写）", cur, cfg.targetPoints);
        }
    } @catch (NSException *e) {}
}

/* ================= m：最后一发保护（快满分 → 持续开火，防终局秒退） =================
 * 诊断结论（2026-09-21 用户 A/B 实测）：满分瞬间若人物全程没有"射击状态"的真实弹道，
 * 终局 KillCam / HighlightKiller 无可回放的开枪记录 → 空引用秒退。
 * ⇒ 距满分 ≤ guard_margin 分时按 guard_fire_ms 的节奏扣扳机（走游戏自己的开火路径）。 */
/* ★ 2026-10-01 用户要求：保护段改成【按住连发】—— 按下就不松手，由游戏按自己的射速连发。
 *   - 进入保护段：调 ShootDown（按下），**不再调 ShootUp**
 *   - 保持期间：每 guard_fire_ms 补一次 ShootDown（半自动武器靠这个才能连发，自动武器补按也无害）
 *   - 离开保护段 / 对局结束 / 开关关闭：调 ShootUp 松手，保证状态干净
 *   ⚠️ 狙击是"松手开枪"（ShootUp 尾部才 TryNormalShoot），所以离开时必须补一次 ShootUp。 */
static BOOL guardOn = NO, guardLogged = NO, holding = NO;
static long lastGuardAt = 0;
static int  realShots = 0;
static void pressDown(void) {
    @try {
        if (!shooterInst) return;
        if (mShootD) inv(mShootD, shooterInst, NULL, 0);   /* 正常扳机：按下 */
        if (mForceD) inv(mForceD, shooterInst, NULL, 0);   /* 双保险 */
        realShots++;
    } @catch (NSException *e) {}
}
static void releaseUp(void) {
    @try {
        if (!shooterInst) return;
        if (mShootU) inv(mShootU, shooterInst, NULL, 0);   /* 松手 */
        if (mForceU) inv(mForceU, shooterInst, NULL, 0);
    } @catch (NSException *e) {}
}
static void guardTick(void) {
    if (!cfg.shotGuard) {
        if (holding) { releaseUp(); holding = NO; }        /* 关掉开关也要松手 */
        guardOn = NO;
        return;
    }
    @try {
        void *inst = ctrlInst();
        if (!inst || !*(uint8_t *)((char *)inst + TIC_RUNNING)) {
            if (holding) { releaseUp(); holding = NO; }    /* 对局结束 → 松手 */
            guardOn = NO;
            return;
        }
        int pts = *(int32_t *)((char *)inst + TIC_POINTS);      /* 实时分（不是右上角 UI） */
        int eff = *(int32_t *)((char *)inst + TIC_TARGET);      /* 已关 capBonus ⇒ 封顶就是它 */
        if (pts >= eff - cfg.guardMargin) {
            guardOn = YES;
            if (!guardLogged) {
                guardLogged = YES;
                TLog(@"[PVE] 持续开火: 进入保护段（%d/%d）→ 【按住连发】每 %dms 补一次按下", pts, eff, cfg.guardFireMs);
            }
            long now = (long)(CFAbsoluteTimeGetCurrent() * 1000);
            if (now - lastGuardAt >= cfg.guardFireMs) { lastGuardAt = now; pressDown(); holding = YES; }
        } else if (guardOn) {
            guardOn = NO; guardLogged = NO;
            if (holding) { releaseUp(); holding = NO; }    /* ★ 离开时松手 */
            TLog(@"[PVE] 持续开火: 离开保护段（新对局/分数回退）→ 已松手");
        }
    } @catch (NSException *e) {}
}

/* ================= 无限子弹 ================= */
static void refillAmmo(void) {
    if (!cfg.infiniteAmmo) return;
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
        /* ★ master 总开关：运行中热改成 false 也要**立刻全部停手** ——
         *   尤其"按住连发"必须先松手，否则会一直扣着扳机不放（这个 bug 只有热重载才会暴露）。 */
        if (!cfg.master) {
            if (holding) { releaseUp(); holding = NO; }
            guardOn = NO;
            return;
        }

        if (!shooterInst || now - shooterFindAt > 5000) { shooterInst = findShooter(); shooterFindAt = now; }
        refillAmmo();

        void *inst = ctrlInst();
        if (inst && !inHallLogged) {
            inHallLogged = YES;
            TLog(@"[PVE] 进入全球行动关卡 → 常驻功能全部生效");
        }
        if (now - lastKillAt >= cfg.tickMs)   { lastKillAt = now; killTick(); }
        /* 连击注入已移除 */
        if (now - lastSpawnAt >= 500)         { lastSpawnAt = now; spawnTick(); }
        if (now - lastTimeAt >= 1000)         { lastTimeAt = now; targetTick(); }   /* 封顶自愈 */
        guardTick();                                                              /* 保护段开火 */

        if (now - lastBeatAt > 10000) {
            lastBeatAt = now;
            TLog(@"[PVE] 心跳 帧=%ld 全球行动=%d 任务中=%d 累计击杀=%d 刷怪=%d只/秒 封顶=%d 保护段=%d(按住中=%d) 触发次数=%d 无限子弹=%d",
                 frames, inst ? 1 : 0, tournamentRunning() ? 1 : 0, totalKilled,
                 cfg.spawn ? cfg.spawnRate : 0, cfg.targetPoints, guardOn ? 1 : 0,
                 holding ? 1 : 0, realShots, cfg.infiniteAmmo ? 1 : 0);
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
        if (!cfg.master) {                       /* ★ 同上：master 关了就别写封顶/别刷怪 */
            if (holding) { releaseUp(); holding = NO; }
            guardOn = NO;
            return;
        }
        if (!shooterInst) shooterInst = findShooter();
        refillAmmo();
        spawnTick();
        targetTick();
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
        /* ★ 绑定结果自检：哪一项是 0，就是那一环没找到（刷怪不生效先看这里） */
        TLog(@"[PVE] 🔎 类绑定: Person=%d 射手=%d 全球控制器=%d ｜刷怪器 僵尸=%d 圣诞=%d 通用=%d 500=%d",
             K_person ? 1 : 0, K_shooter ? 1 : 0, K_tic ? 1 : 0,
             K_spawnerH ? 1 : 0, K_spawnerX ? 1 : 0, K_spawnerG ? 1 : 0, K_spawnerG5 ? 1 : 0);
        TLog(@"[PVE] 🔎 方法绑定: 全量查找=%d Kill=%d 全球单例=%d 开火(ShootDown/Up)=%d/%d ForceTouch=%d/%d",
             mFOOAll ? 1 : 0, mKill1 ? 1 : 0, mTicInst ? 1 : 0,
             mShootD ? 1 : 0, mShootU ? 1 : 0, mForceD ? 1 : 0, mForceU ? 1 : 0);
        gTimer = [NSTimer timerWithTimeInterval:1.0 target:[ZBTimerTarget shared] selector:@selector(tick:) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
        TLog(@"[PVE] 🎯 SniperPVEGA v%s 就绪（杀怪=%d 每%dms×%d个=每秒%.0f个｜刷怪=%d只/秒 同屏%d 总数%d｜封顶=%d分｜保护段=距满分%d分【按住连发】｜无限子弹=%d）"
             @" —— 日志: Documents/pvega_tweak.log",
             TWEAK_VERSION, cfg.autoKill ? 1 : 0, cfg.tickMs, cfg.killPerTick,
             (double)1000.0 / (double)cfg.tickMs * (double)cfg.killPerTick,
             cfg.spawn ? cfg.spawnRate : 0, cfg.spawnLimit, cfg.spawnTotal,
             cfg.targetPoints, cfg.guardMargin, cfg.infiniteAmmo ? 1 : 0);
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
