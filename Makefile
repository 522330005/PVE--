THEOS_PACKAGE_SCHEME = rootless

TARGET = iphone:clang:latest:15.0
ARCHS = arm64

TWEAK_NAME = SniperPVEGA
SniperPVEGA_FILES = Tweak.xm
SniperPVEGA_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-varargs -Wno-unused-function
SniperPVEGA_LIBRARIES = substrate

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS)/makefiles/master/rules.mk
