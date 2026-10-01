/* ============================================================================
 * SniperPVEZB — Sniper3D PVE【僵尸噩梦】tweak（autohead.js v8.38 的原生移植）
 * 注入方式：Dopamine 运行时注入（不动磁盘二进制，TNG 已验证的路线）
 *
 * 功能模块（对应 autohead.js 的模式 1 常驻项）：
 *   g  自动杀怪：每 tick_ms 杀 kill_per_tick 个，固定爆头
 *       僵尸用 HalloweenLiveEventPerson.TakeDamages(1e6, headshot, false)
 *       （实测 Person.Kill 对池化僵尸无效 —— 这是踩过的坑）
 *   c  连击注入：streakIndex 钉在配置表最高档（服务器按它查梯度表算加成）
 *   w  刷怪加速：写刷怪器的 间隔/总数/同屏上限（按类名分派偏移，认不出就不写）
 *   y  时长压缩：MatchTimer 压到目标秒数（走正常结束链，不硬跳）
 *   ∞  无限子弹：每把枪 currentAmmo 常驻写满 maxAmmo
 *
 * 配置：沙盒 Documents/pvezb_config.json（首次运行自动生成，改完 5 秒热重载）
 * 日志：沙盒 Documents/pvezb_tweak.log（[LOADED] = 注入成功铁证）
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
#define DEF_TICK_MS        200      /* 杀怪节奏：每 200ms 一拍 */
#define DEF_KILL_PER_TICK  5        /* 每拍杀 5 个 → 10 只/秒 */
#define DEF_KILL_CAP       0        /* 0 = 不限（用户 2026-10-01 要求放开 300 上限） */
#define DEF_STREAK_KILLS   300      /* 连击档位门槛（实际以运行时配置表为准） */
#define DEF_SPAWN_RATE     13       /* 每秒刷 13 只 */
#define DEF_SPAWN_LIMIT    20       /* 同屏上限（可自设） */
#define DEF_SPAWN_TOTAL    0        /* 0 = 不限（内部用 500） */
#define DEF_TIME_LIMIT     20       /* 对局时长压缩到 20 秒 */

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
/* 计分器 / 连击（PlayerScoreCounter +0x20 = HeadshotStreakCounter） */
#define SC_STREAK        0x20
#define ST_CONFIG        0x10      /* streakConfig */
#define ST_ONSTREAK      0x18      /* isOnStreak (u8) */
#define ST_MULT          0x1C      /* streakMultiplier (float) */
#define ST_INDEX         0x20      /* streakIndex (int) */
#define ST_KILLS         0x24      /* streakKills (int) */
#define ST_KILLS2        0x28
/* 连击配置表 */
#define CFG_NUMBERS      0x10      /* List<int> HeadshotNumber */
#define CFG_MULTIPLIERS  0x18      /* List<float> StreakMultiplier */
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
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/pvezb_tweak.log"];
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

/* ================= 配置（Documents/pvezb_config.json，5 秒热重载） ================= */
typedef struct {
    BOOL   master;
    BOOL   autoKill;       /* g 自动杀怪 */
    int    tickMs;         /* 节奏 */
    int    killPerTick;    /* 每拍杀几个 */
    int    killCap;        /* 击杀上限，0=不限 */
    BOOL   streak;         /* c 连击注入 */
    int    streakKills;    /* 配置表缺失时的兜底门槛 */
    BOOL   spawn;          /* w 刷怪加速 */
    int    spawnRate;      /* 每秒几只 */
    int    spawnLimit;     /* 同屏上限 */
    int    spawnTotal;     /* 总数，0=不限 */
    int    timeLimit;      /* y 时长压缩秒数，0=不干预 */
    BOOL   infiniteAmmo;   /* 无限子弹 */
} ZBConfig;
static ZBConfig cfg;

static NSString *ConfigPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/pvezb_config.json"];
}
static void ConfigDefaults(ZBConfig *c) {
    c->master = YES;
    c->autoKill = YES; c->tickMs = DEF_TICK_MS; c->killPerTick = DEF_KILL_PER_TICK; c->killCap = DEF_KILL_CAP;
    c->streak = YES; c->streakKills = DEF_STREAK_KILLS;
    c->spawn = YES; c->spawnRate = DEF_SPAWN_RATE; c->spawnLimit = DEF_SPAWN_LIMIT; c->spawnTotal = DEF_SPAWN_TOTAL;
    c->timeLimit = DEF_TIME_LIMIT;
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
static void ConfigFromDict(ZBConfig *c, NSDictionary *d) {
    c->master       = cfgBool(d, @"master", YES);
    c->autoKill     = cfgBool(d, @"auto_kill", YES);
    c->tickMs       = cfgInt(d, @"tick_ms", DEF_TICK_MS);
    c->killPerTick  = cfgInt(d, @"kill_per_tick", DEF_KILL_PER_TICK);
    c->killCap      = cfgInt(d, @"kill_cap", DEF_KILL_CAP);
    c->streak       = cfgBool(d, @"streak", YES);
    c->streakKills  = cfgInt(d, @"streak_kills", DEF_STREAK_KILLS);
    c->spawn        = cfgBool(d, @"spawn", YES);
    c->spawnRate    = cfgInt(d, @"spawn_rate", DEF_SPAWN_RATE);
    c->spawnLimit   = cfgInt(d, @"spawn_limit", DEF_SPAWN_LIMIT);
    c->spawnTotal   = cfgInt(d, @"spawn_total", DEF_SPAWN_TOTAL);
    c->timeLimit    = cfgInt(d, @"time_limit", DEF_TIME_LIMIT);
    c->infiniteAmmo = cfgBool(d, @"infinite_ammo", YES);
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
        @"  \"kill_per_tick\": 5,\n"
        @"  \"kill_cap\": 0,\n"
        @"  \"streak\": true,\n"
        @"  \"streak_kills\": 300,\n"
        @"  \"spawn\": true,\n"
        @"  \"spawn_rate\": 13,\n"
        @"  \"spawn_limit\": 20,\n"
        @"  \"spawn_total\": 0,\n"
        @"  \"time_limit\": 20,\n"
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
static void *K_halloween = NULL, *K_zombie = NULL, *K_hallPerson = NULL;
static void *K_spawnerH = NULL, *K_spawnerX = NULL, *K_spawnerG = NULL, *K_spawnerG5 = NULL;
static void *mFOOAll = NULL, *mKill1 = NULL, *mHallInst = NULL, *mHallScore = NULL, *mHallTD = NULL;
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
    K_halloween   = clsFrom("Game.HalloweenLiveEvent.Sniper3D", "HalloweenLiveEventLevelController");
    K_zombie      = clsFrom("Game.HalloweenLiveEvent.Sniper3D", "Zombie");
    K_hallPerson  = clsFrom("Game.HalloweenLiveEvent.Sniper3D", "HalloweenLiveEventPerson");
    K_spawnerH    = clsFrom("Game.HalloweenLiveEvent.Sniper3D", "HalloweenLiveEventTimedSpawner");
    K_spawnerX    = clsFrom("Game.ChristmasLiveEvent.Sniper3D", "ChristmasLiveEventTimedSpawner");
    K_spawnerG    = clsFrom("", "TimedSpawner");
    K_spawnerG5   = clsFrom("", "TimedSpawner500");
    if (!K_object || !K_person) return NO;
    mFOOAll    = meth(K_object, "FindObjectsOfTypeAll", 1);
    mKill1     = meth(K_person, "Kill", 1);
    mHallInst  = meth(K_halloween, "get_HalloweenInstance", 0);
    mHallScore = meth(K_halloween, "get_PlayerScoreCounter", 0);
    mHallTD    = meth(K_hallPerson, "TakeDamages", 3);
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
static double *gDmg = NULL;      /* TakeDamages(1e6, …) 的 double 参数要传指针 */
static uint8_t gTrue = 1, gFalse = 0;

/* ================= 运行时状态 ================= */
static BOOL gReady = NO;
static void *hallInstCached = NULL;
static long hallCacheAt = 0;
static void *shooterInst = NULL;
static long shooterFindAt = 0;
static int  realKills = 0;
static int  totalKilled = 0;
static long lastKillAt = 0, lastSpawnAt = 0, lastStreakAt = 0, lastTimeAt = 0, lastBeatAt = 0;
static long frames = 0;
static BOOL inHallLogged = NO;    /* "进入僵尸关卡"只报一次 */
static long hallNullSince = 0;    /* 在僵尸关=0 持续计时（用于提示是否真在关卡内） */
static BOOL spawnLogged = NO;     /* "刷怪加速生效"只报一次（别和上面共用同一个标志） */
static BOOL capReached = NO;

static void *hallInst(void) {
    long now = (long)(CFAbsoluteTimeGetCurrent() * 1000);
    if (hallInstCached && now - hallCacheAt < 400) return hallInstCached;
    hallInstCached = inv(mHallInst, NULL, NULL, 0);
    hallCacheAt = now;
    return hallInstCached;
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
/* 本局人头 = KilledZombieStorage 明细条数（控制器+0x350 → List@+0x18 → _size@+0x18） */
static int getZombiesKilled(void) {
    @try {
        void *inst = hallInst();
        if (!inst) return -1;
        void *st = *(void **)((char *)inst + HALL_STORAGE);
        if (!st) return -1;
        void *list = *(void **)((char *)st + 0x18);
        if (!list) return -1;
        return *(int32_t *)((char *)list + 0x18);
    } @catch (NSException *e) { return -1; }
}

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
    /* 僵尸噩梦：从 Zombie 包装类反向收集（+0x20 = person），
     * 池化僵尸的 Person._alive 未必按普通怪置位 —— 这是"杀不到"的老根因 */
    @try {
        void *t = typeObj(K_zombie);
        if (t) {
            void *r = inv(mFOOAll, NULL, (void *[]){ t }, 1);
            if (r) {
                int n = *(int32_t *)((char *)r + 0x18);
                for (int i = 0; i < n && targetsN < MAX_TARGETS; i++) {
                    void *z = *(void **)((char *)r + 0x20 + 8 * i);
                    if (!z) continue;
                    void *p = *(void **)((char *)z + 0x20);
                    if (p && !targetSeen(p)) targets[targetsN++] = p;   /* 绕过存活过滤 + 去重 */
                }
            }
        }
    } @catch (NSException *e) {}
}
static void killTick(void) {
    if (!cfg.autoKill) return;
    void *inst = hallInst();
    BOOL hallMode = (inst != NULL);
    /* ★★ 必须锁死：只有在**僵尸噩梦关卡**才动杀手。
     *   否则非僵尸关（普通关 / PVP）会走 Person.Kill(true) 分支 ——
     *   那会把场上的人一个个杀掉（PVP 里就是真人玩家），属于灾难级副作用。 */
    if (!hallMode) return;
    @try {
        int zk = getZombiesKilled();
        if (zk >= 0) realKills = zk;
        if (cfg.killCap > 0 && zk >= cfg.killCap) {
            if (!capReached) {
                capReached = YES;
                TLog(@"[PVE] 击杀 %d/%d 已达上限，停止杀怪", zk, cfg.killCap);
            }
            return;
        }
        capReached = NO;
        collectTargets();
        if (targetsN <= 3) return;          /* 大厅/菜单不许开杀 */
        if (!gDmg) gDmg = (double *)malloc(8);   /* ⚠️ .xm 按 ObjC++ 编译，void* 不会隐式转 double* */
        *gDmg = 1e6;
        int n = 0;
        for (int i = 0; i < targetsN && n < cfg.killPerTick; i++) {
            void *p = targets[i];
            if (!p) continue;
            @try {
                if (hallMode && mHallTD) {
                    inv(mHallTD, p, (void *[]){ gDmg, &gTrue, &gFalse }, 3);   /* TakeDamages(1e6, headshot=true, false) */
                } else {
                    inv(mKill1, p, (void *[]){ &gTrue }, 1);                    /* Kill(true) */
                }
                n++; totalKilled++;
            } @catch (NSException *e) {}
        }
    } @catch (NSException *e) {}
}

/* ================= c：连击注入 ================= */
static void streakTick(void) {
    if (!cfg.streak) return;
    @try {
        void *inst = hallInst();
        if (!inst || !mHallScore) return;
        void *sc = inv(mHallScore, inst, NULL, 0);
        if (!sc) return;
        void *st = *(void **)((char *)sc + SC_STREAK);
        if (!st) return;
        if (!gDmg) gDmg = (double *)malloc(8);   /* ⚠️ .xm 按 ObjC++ 编译，void* 不会隐式转 double* */
        /* 先读后写：已经钉在顶格就整段跳过（游戏自己也在动这些字段） */
        void *cfgO = *(void **)((char *)st + ST_CONFIG);
        if (cfgO) {
            void *ml = *(void **)((char *)cfgO + CFG_MULTIPLIERS);   /* List<float> */
            if (ml) {
                int mSize = *(int32_t *)((char *)ml + 0x18);
                void *mArr = *(void **)((char *)ml + 0x10);
                if (mSize > 0 && mArr) {
                    int last = mSize - 1;
                    float topMult = *(float *)((char *)mArr + 0x20 + 4 * last);
                    int need = cfg.streakKills;
                    void *nl = *(void **)((char *)cfgO + CFG_NUMBERS);   /* List<int> */
                    if (nl) {
                        int nSize = *(int32_t *)((char *)nl + 0x18);
                        void *nArr = *(void **)((char *)nl + 0x10);
                        if (nSize > 0 && nArr) need = *(int32_t *)((char *)nArr + 0x20 + 4 * last);
                    }
                    BOOL already = (*(uint8_t *)((char *)st + ST_ONSTREAK) == 1)
                                && (*(int32_t *)((char *)st + ST_INDEX) == last)
                                && (fabsf(*(float *)((char *)st + ST_MULT) - topMult) < 0.01f)
                                && (*(int32_t *)((char *)st + ST_KILLS) == need)
                                && (*(int32_t *)((char *)st + ST_KILLS2) == need);
                    if (already) return;
                    *(uint8_t *)((char *)st + ST_ONSTREAK) = 1;
                    *(int32_t *)((char *)st + ST_INDEX) = last;
                    *(float *)((char *)st + ST_MULT) = topMult;
                    *(int32_t *)((char *)st + ST_KILLS) = need;
                    *(int32_t *)((char *)st + ST_KILLS2) = need;
                    return;
                }
            }
        }
        /* 配置表缺失的兜底 */
        *(uint8_t *)((char *)st + ST_ONSTREAK) = 1;
        *(int32_t *)((char *)st + ST_INDEX) = 4;
        *(int32_t *)((char *)st + ST_KILLS) = cfg.streakKills;
        *(int32_t *)((char *)st + ST_KILLS2) = cfg.streakKills;
        *(float *)((char *)st + ST_MULT) = 5.0f;
    } @catch (NSException *e) {}
}

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
    void *hi = hallInst();
    if (!hi) {     /* 不在僵尸关：仍输出诊断，否则整段静默、看不出卡哪一环 */
        static long lastSD0 = 0; long nd = (long)(CFAbsoluteTimeGetCurrent() * 1000);
        if (nd - lastSD0 > 10000) { lastSD0 = nd;
            TLog(@"[PVE] 🔎 刷怪诊断: 在僵尸关=0（get_HalloweenInstance 返回空）刷怪器实例=0 运行中=0 已改写=0（spawn=%d rate=%d）",
                 cfg.spawn ? 1 : 0, cfg.spawnRate);
        }
        return;      /* ★ 只在僵尸关动手，别去改别的模式的刷怪器 */
    }
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
         *   在僵尸关=0  → hallInst() 拿不到（控制器类/方法没找到）⇒ 全部功能哑火
         *   实例=0      → 刷怪器类没找到，或当前不在可刷怪的关卡
         *   运行中=0    → _running 偏移不对，或波次还没开始
         *   已改写=0 但运行中>0 → spec 匹配失败（实例是子类，klass 比对不上） */
        static long lastSpawnDiag = 0;
        long nowD = (long)(CFAbsoluteTimeGetCurrent() * 1000);
        if (nowD - lastSpawnDiag > 10000) {
            lastSpawnDiag = nowD;
            TLog(@"[PVE] 🔎 刷怪诊断: 在僵尸关=%d 刷怪器实例=%d 运行中=%d 已改写=%d（spawn=%d rate=%d）",
                 hallInst() ? 1 : 0, foundN, runningN, hit, cfg.spawn ? 1 : 0, cfg.spawnRate);
        }
    } @catch (NSException *e) {}
}

/* ================= y：对局时长压缩 ================= */
static void timeTick(void) {
    if (cfg.timeLimit <= 0) return;
    @try {
        void *inst = hallInst();
        if (!inst) return;
        void *tm = *(void **)((char *)inst + HALL_MATCHTIMER);
        if (!tm) return;
        if (!*(uint8_t *)((char *)tm + MT_RUNNING)) return;      /* 计时未运行 */
        float left = *(float *)((char *)tm + MT_LEFT);
        if (left > (float)cfg.timeLimit) {
            *(float *)((char *)tm + MT_SECONDS) = (float)cfg.timeLimit;
            *(float *)((char *)tm + MT_LEFT) = (float)cfg.timeLimit;
            TLog(@"[PVE] 对局时长已压缩为 %d 秒", cfg.timeLimit);
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
        /* ★ master 总开关：运行中热改成 false 也要立刻全部停手（原来只在启动那一次检查，
         *   热重载改 false 后功能照样在跑 —— 和全球行动那份同一个坑，一起修）。 */
        if (!cfg.master) return;

        if (!shooterInst || now - shooterFindAt > 5000) { shooterInst = findShooter(); shooterFindAt = now; }
        refillAmmo();

        void *inst = hallInst();
        if (inst) {
            if (!inHallLogged) {
                inHallLogged = YES;
                TLog(@"[PVE] 进入僵尸噩梦关卡 → 常驻功能全部生效");
            }
            hallNullSince = 0;
        } else {
            if (inHallLogged) { inHallLogged = NO; TLog(@"[PVE] 离开僵尸噩梦关卡"); }
            if (hallNullSince == 0) hallNullSince = now;
            else if (now - hallNullSince > 30000) {
                hallNullSince = now;
                TLog(@"[PVE] 🔎 在僵尸关=0 已持续≥30s（帧=%ld）：若你此刻确实在【僵尸噩梦/Halloween Live Event】关卡内，说明 get_HalloweenInstance 返回空（事件未激活 或 不是该模式）；若只是在菜单/其它模式则属正常", frames);
            }
        }
        if (now - lastKillAt >= cfg.tickMs)   { lastKillAt = now; killTick(); }
        if (now - lastStreakAt >= 250)        { lastStreakAt = now; streakTick(); }
        if (now - lastSpawnAt >= 500)         { lastSpawnAt = now; spawnTick(); }
        if (now - lastTimeAt >= 1000)         { lastTimeAt = now; timeTick(); }

        if (now - lastBeatAt > 10000) {
            lastBeatAt = now;
            TLog(@"[PVE] 心跳 帧=%ld 在僵尸关=%d 本局人头=%d 累计击杀=%d 刷怪=%d只/秒 时长=%ds 连击=%d 无限子弹=%d",
                 frames, inst ? 1 : 0, realKills, totalKilled,
                 cfg.spawn ? cfg.spawnRate : 0, cfg.timeLimit, cfg.streak ? 1 : 0, cfg.infiniteAmmo ? 1 : 0);
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
        if (!cfg.master) return;      /* ★ 同上：master 关了就别刷怪/别压时长 */
        if (!shooterInst) shooterInst = findShooter();
        refillAmmo();
        spawnTick();
        timeTick();
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
        TLog(@"[PVE] 🔎 类绑定: Person=%d 射手=%d 僵尸控制器=%d Zombie=%d 僵尸本体=%d ｜刷怪器 僵尸=%d 圣诞=%d 通用=%d 500=%d",
             K_person ? 1 : 0, K_shooter ? 1 : 0, K_halloween ? 1 : 0, K_zombie ? 1 : 0, K_hallPerson ? 1 : 0,
             K_spawnerH ? 1 : 0, K_spawnerX ? 1 : 0, K_spawnerG ? 1 : 0, K_spawnerG5 ? 1 : 0);
        TLog(@"[PVE] 🔎 方法绑定: 全量查找=%d Kill=%d 僵尸单例=%d 计分器=%d 伤害入口=%d",
             mFOOAll ? 1 : 0, mKill1 ? 1 : 0, mHallInst ? 1 : 0, mHallScore ? 1 : 0, mHallTD ? 1 : 0);
        gTimer = [NSTimer timerWithTimeInterval:1.0 target:[ZBTimerTarget shared] selector:@selector(tick:) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
        TLog(@"[PVE] 🎯 SniperPVEZB v%s 就绪（杀怪=%d 每%dms×%d个 上限%d｜连击=%d｜刷怪=%d只/秒 同屏%d 总数%d｜时长=%ds｜无限子弹=%d）"
             @" —— 日志: Documents/pvezb_tweak.log",
             TWEAK_VERSION, cfg.autoKill ? 1 : 0, cfg.tickMs, cfg.killPerTick, cfg.killCap,
             cfg.streak ? 1 : 0, cfg.spawn ? cfg.spawnRate : 0, cfg.spawnLimit, cfg.spawnTotal,
             cfg.timeLimit, cfg.infiniteAmmo ? 1 : 0);
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
                TLog(@"[PVE] [LOADED] target=%@ v%s（SniperPVEZB）", bid, TWEAK_VERSION);
                setupStep();
            } @catch (NSException *e) {}
        }
    });
}
