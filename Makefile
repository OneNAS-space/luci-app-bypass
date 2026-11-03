# Copyright (C) 2025  OneNAS-space <https://github.com/OneNAS-space/luci-app-bypass/>
#
# This is free software, licensed under the GPL-3 License
#

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/package.mk

PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=Jackie Han <jackie.han@gmail.com>
PKG_NAME:=luci-app-bypass
PKG_VERSION:=1.0.2
PKG_RELEASE:=1

define Package/$(PKG_NAME)
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=LuCI support for Bypass (PassWall2 bypass logic)
	DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-uci
	CONFLICTS:=luci-app-advanced luci-app-pw2-guard
	PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
	Bypass logic for PassWall2 routers: DHCP hosts tagged VPN (identified by
	MAC address) are handed to PassWall2, everything else goes direct, with
	optional Natmap (qBittorrent) port integration, plus a LuCI page with
	live counters.
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/bypass
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/bypass $(1)/etc/init.d/bypass

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/40_bypass $(1)/etc/uci-defaults/

	$(INSTALL_DIR) $(1)/usr/share/bypass/scripts
	$(INSTALL_BIN) ./root/usr/share/bypass/scripts/natmap_watch.sh $(1)/usr/share/bypass/scripts/natmap_watch.sh
	$(INSTALL_BIN) ./root/usr/share/bypass/scripts/stun_sync.sh $(1)/usr/share/bypass/scripts/stun_sync.sh

	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DATA) ./root/usr/share/rpcd/ucode/bypass.uc $(1)/usr/share/rpcd/ucode/bypass.uc

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-bypass.json $(1)/usr/share/rpcd/acl.d/

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-bypass.json $(1)/usr/share/luci/menu.d/

	$(INSTALL_DIR) $(1)/www
	cp -pR ./htdocs/* $(1)/www/
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	[ -f /etc/uci-defaults/40_bypass ] && sh /etc/uci-defaults/40_bypass && rm -f /etc/uci-defaults/40_bypass
	/etc/init.d/bypass enabled && /etc/init.d/bypass restart
	# a new rpcd ucode plugin is only picked up after a restart (web sessions are reset once)
	/etc/init.d/rpcd restart
fi
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
