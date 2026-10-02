THEOS_PACKAGE_SCHEME = rootless

TARGET = iphone:clang:latest:15.0
ARCHS = arm64

TWEAK_NAME = SniperPVEGA
SniperPVEGA_FILES = Tweak.xm
SniperPVEGA_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-varargs -Wno-unused-function
SniperPVEGA_LIBRARIES = substrate

# ★ 2026-10-02：身份硬校验（解析阶段即生效，不依赖 CI）
#   control 的 Package 必须与本目录 TWEAK_NAME 对应；plist 必须同名存在。
#   任一条不满足 → make 直接失败，绝不会编出"包里装着别人代码"的对调 deb。
EXPECT_PKG := com.sniper.pvega
PKG_ACTUAL := $(shell grep -m1 '^Package:' control 2>/dev/null | awk '{print $$2}')
ifneq ($(PKG_ACTUAL),$(EXPECT_PKG))
$(error 对调阻断: control 的 Package 是 '$(PKG_ACTUAL)'，但 TWEAK_NAME='SniperPVEGA' 要求 '$(EXPECT_PKG)' —— 极可能是把两个仓库的 control 传反了)
endif
ifeq ($(wildcard SniperPVEGA.plist),)
$(error 缺少 SniperPVEGA.plist（必须与 TWEAK_NAME 同名）)
endif

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS)/makefiles/master/rules.mk
