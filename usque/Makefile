# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=usque
PKG_VERSION:=4.2.1
PKG_RELEASE:=3

PKG_SOURCE:=usque-src-4.2.1-04ef749a7ca3.tar.gz
PKG_SOURCE_URL:=https://github.com/zjfjm/openwrt-daede/releases/download/usque-src
PKG_SOURCE_SUBDIR:=$(PKG_NAME)-$(PKG_VERSION)
PKG_HASH:=04ef749a7ca3505301848e296e9bc519bf243086ca84948950256c0cbf9d6ea3

PKG_LICENSE:=MIT
PKG_MAINTAINER:=zjfjm

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/Diniboy1123/usque
GO_PKG_LDFLAGS:= \
	-s -w -buildid=

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/usque
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=Cloudflare WARP MASQUE client
  URL:=https://github.com/Diniboy1123/usque
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle
endef

define Package/usque/description
  Usque is an open-source reimplementation of the Cloudflare WARP client's
  MASQUE mode (Connect-IP). It exposes WARP as a local SOCKS5 proxy that
  dae/daed can use as a socks5:// outbound node.
endef

define Package/usque/conffiles
/etc/config/usque
/etc/usque/config.json
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(TAR) --strip-components=1 -C $(PKG_BUILD_DIR) -xzf $(DL_DIR)/$(PKG_SOURCE)
endef

define Build/Compile
	$(call GoPackage/Build/Compile)
endef

define Package/usque/install
	$(call GoPackage/Package/Install/Bin,$(PKG_INSTALL_DIR))
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/usque $(1)/usr/bin/usque

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/usque.config $(1)/etc/config/usque

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/usque.init $(1)/etc/init.d/usque
endef

$(eval $(call GoBinPackage,usque))
$(eval $(call BuildPackage,usque))
