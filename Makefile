ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = infstam
infstam_FILES = InfinityStamina.m
infstam_FRAMEWORKS = Foundation UIKit
infstam_CFLAGS = -fobjc-arc
infstam_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
