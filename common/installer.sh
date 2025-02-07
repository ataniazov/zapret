GET_LIST_PREFIX=/ipset/get_

SYSTEMD_DIR=/lib/systemd
[ -d "$SYSTEMD_DIR" ] || SYSTEMD_DIR=/usr/lib/systemd
[ -d "$SYSTEMD_DIR" ] && SYSTEMD_SYSTEM_DIR="$SYSTEMD_DIR/system"

INIT_SCRIPT=/etc/init.d/zapret


exitp()
{
	echo
	echo press enter to continue
	read A
	exit $1
}

parse_var_checked()
{
	# $1 - file name
	# $2 - var name
	local sed="sed -nre s/^[[:space:]]*$2=[\\\"|\']?([^\\\"|\']*)[\\\"|\']?/\1/p"
	local v="$($sed <"$1" | tail -n 1)"
	eval $2=\"$v\"
}
parse_vars_checked()
{
	# $1 - file name
	# $2,$3,... - var names
	local f="$1"
	shift
	while [ -n "$1" ]; do
		parse_var_checked "$f" $1
		shift
	done	
}
edit_file()
{
	# $1 - file name
	local ed="$EDITOR"
	[ -n "$ed" ] || {
		for e in mcedit nano vi; do
			exists "$e" && {
				ed="$e"
				break
			}
		done
	}
	[ -n "$ed" ] && "$ed" "$1"
}
edit_vars()
{
	# $1,$2,... - var names
	local n=1 var v tmp="/tmp/zvars"
	rm -f "$tmp"
	while [ 1=1 ]; do
		eval var="\$$n"
		[ -n "$var" ] || break
		eval v="\$$var"
		echo $var=\"$v\" >>"$tmp"
		n=$(($n+1))
	done
	edit_file "$tmp" && parse_vars_checked "$tmp" "$@"
	rm -f "$tmp"
}

openrc_test()
{
	exists rc-update || return 1
	# some systems do not usse openrc-init but launch openrc from inittab
	[ "$INIT" = "openrc-init" ] || grep -qE "sysinit.*openrc" /etc/inittab 2>/dev/null
}
check_system()
{
	echo \* checking system

	SYSTEM=""
	SYSTEMCTL=$(whichq systemctl)

	get_fwtype
	OPENWRT_FW3=

	local info
	UNAME=$(uname)
	if [ "$UNAME" = "Linux" ]; then
		# do not use 'exe' because it requires root
		local INIT=$(sed 's/\x0/\n/g' /proc/1/cmdline | head -n 1)
		[ -L "$INIT" ] && INIT=$(readlink "$INIT")
		INIT=$(basename "$INIT")
		# some distros include systemctl without systemd
		if [ -d "$SYSTEMD_DIR" ] && [ -x "$SYSTEMCTL" ] && [ "$INIT" = "systemd" ]; then
			SYSTEM=systemd
		elif [ -f "/etc/openwrt_release" ] && exists opkg && exists uci && [ "$INIT" = "procd" ] ; then
		{
			SYSTEM=openwrt
			if openwrt_fw3 ; then
				OPENWRT_FW3=1
				info="openwrt firewall uses fw3"
				if is_ipt_flow_offload_avail; then
					info="$info. hardware flow offloading requires iptables."
				else
					info="$info. flow offloading unavailable."
				fi
			elif openwrt_fw4; then
				info="openwrt firewall uses fw4. flow offloading requires nftables."
			fi
		}
		elif openrc_test; then
			SYSTEM=openrc
		else
			echo system is not either systemd, openrc or openwrt based
			echo easy installer can set up config settings but can\'t configure auto start
			echo you have to do it manually. check readme.txt for manual setup info.
			if ask_yes_no N "do you want to continue"; then
			    SYSTEM=linux
			else
			    exitp 5
			fi
		fi
	elif [ "$UNAME" = "Darwin" ]; then
		SYSTEM=macos
	else
		echo easy installer only supports Linux and MacOS. check readme.txt for supported systems and manual setup info.
		exitp 5
	fi
	echo system is based on $SYSTEM
	[ -n "$info" ] && echo $info
}

get_free_space_mb()
{
    df -m $PWD | awk '/[0-9]%/{print $(NF-2)}'
}
get_ram_kb()
{
    grep MemTotal /proc/meminfo | awk '{print $2}'
}
get_ram_mb()
{
    local R=$(get_ram_kb)
    echo $(($R/1024))
}

crontab_del()
{
	exists crontab || return

	echo \* removing crontab entry

	CRONTMP=/tmp/cron.tmp
	crontab -l >$CRONTMP 2>/dev/null
	if grep -q "$GET_LIST_PREFIX" $CRONTMP; then
		echo removing following entries from crontab :
		grep "$GET_LIST_PREFIX" $CRONTMP
		grep -v "$GET_LIST_PREFIX" $CRONTMP >$CRONTMP.2
		crontab $CRONTMP.2
		rm -f $CRONTMP.2
	fi
	rm -f $CRONTMP
}
crontab_del_quiet()
{
	exists crontab || return

	CRONTMP=/tmp/cron.tmp
	crontab -l >$CRONTMP 2>/dev/null
	if grep -q "$GET_LIST_PREFIX" $CRONTMP; then
		grep -v "$GET_LIST_PREFIX" $CRONTMP >$CRONTMP.2
		crontab $CRONTMP.2
		rm -f $CRONTMP.2
	fi
	rm -f $CRONTMP
}
crontab_add()
{
	# $1 - hour min
	# $2 - hour max
	[ -x "$GET_LIST" ] &&	{
		echo \* adding crontab entry

		if exists crontab; then
			CRONTMP=/tmp/cron.tmp
			crontab -l >$CRONTMP 2>/dev/null
			if grep -q "$GET_LIST_PREFIX" $CRONTMP; then
				echo some entries already exist in crontab. check if this is corrent :
				grep "$GET_LIST_PREFIX" $CRONTMP
			else
				end_with_newline <"$CRONTMP" || echo >>"$CRONTMP"
				echo "$(random 0 59) $(random $1 $2) */2 * * $GET_LIST" >>$CRONTMP
				crontab $CRONTMP
			fi
			rm -f $CRONTMP
		else
			echo '!!! CRON IS ABSENT !!! LISTS AUTO UPDATE WILL NOT WORK !!!'
		fi
	}
}
cron_ensure_running()
{
	# if no crontabs present in /etc/cron openwrt init script does not launch crond. this is default
	[ "$SYSTEM" = "openwrt" ] && {
		/etc/init.d/cron enable
		/etc/init.d/cron start
	}
}


service_start_systemd()
{
	echo \* starting zapret service

	"$SYSTEMCTL" start zapret || {
		echo could not start zapret service
		exitp 30
	}
}
service_stop_systemd()
{
	echo \* stopping zapret service

	"$SYSTEMCTL" daemon-reload
	"$SYSTEMCTL" disable zapret
	"$SYSTEMCTL" stop zapret
}
service_remove_systemd()
{
	echo \* removing zapret service

	rm -f "$SYSTEMD_SYSTEM_DIR/zapret.service"
	"$SYSTEMCTL" daemon-reload
}
timer_remove_systemd()
{
	echo \* removing zapret-list-update timer

	"$SYSTEMCTL" daemon-reload
	"$SYSTEMCTL" disable zapret-list-update.timer
	"$SYSTEMCTL" stop zapret-list-update.timer
	rm -f "$SYSTEMD_SYSTEM_DIR/zapret-list-update.service" "$SYSTEMD_SYSTEM_DIR/zapret-list-update.timer"
	"$SYSTEMCTL" daemon-reload
}

install_sysv_init()
{
	# $1 - "0"=disable
	echo \* installing init script

	[ -x "$INIT_SCRIPT" ] && {
		"$INIT_SCRIPT" stop
		"$INIT_SCRIPT" disable
	}
	ln -fs "$INIT_SCRIPT_SRC" "$INIT_SCRIPT"
	[ "$1" != "0" ] && "$INIT_SCRIPT" enable
}
install_openrc_init()
{
	# $1 - "0"=disable
	echo \* installing init script

	[ -x "$INIT_SCRIPT" ] && {
		"$INIT_SCRIPT" stop
		rc-update del zapret
	}
	ln -fs "$INIT_SCRIPT_SRC" "$INIT_SCRIPT"
	[ "$1" != "0" ] && rc-update add zapret
}
service_remove_openrc()
{
	echo \* removing zapret service

	[ -x "$INIT_SCRIPT" ] && {
		rc-update del zapret
		"$INIT_SCRIPT" stop
	}
	rm -f "$INIT_SCRIPT"
}
service_start_sysv()
{
	[ -x "$INIT_SCRIPT" ] && {
		echo \* starting zapret service
		"$INIT_SCRIPT" start || {
			echo could not start zapret service
			exitp 30
		}
	}
}
service_stop_sysv()
{
	[ -x "$INIT_SCRIPT" ] && {
		echo \* stopping zapret service
		"$INIT_SCRIPT" stop
	}
}
service_remove_sysv()
{
	echo \* removing zapret service

	[ -x "$INIT_SCRIPT" ] && {
		"$INIT_SCRIPT" disable
		"$INIT_SCRIPT" stop
	}
	rm -f "$INIT_SCRIPT"
}

check_kmod()
{
	[ -f "/lib/modules/$(uname -r)/$1.ko" ]
}
check_package_exists_openwrt()
{
	[ -n "$(opkg list $1)" ]
}
check_package_openwrt()
{
	[ -n "$(opkg list-installed $1)" ] && return 0
	local what=$(opkg whatprovides $1 | tail -n +2 | head -n 1)
	[ -n "$what" ] || return 1
	[ -n "$(opkg list-installed $what)" ]
}
check_packages_openwrt()
{
	for pkg in $@; do
		check_package_openwrt $pkg || return
	done
}

install_openwrt_iface_hook()
{
	echo \* installing ifup hook
	
	ln -fs "$OPENWRT_IFACE_HOOK" /etc/hotplug.d/iface
}
remove_openwrt_iface_hook()
{
	echo \* removing ifup hook
	
	rm -f /etc/hotplug.d/iface/??-zapret
}
openwrt_fw_section_find()
{
	# $1 - fw include postfix
	# echoes section number
	
	i=0
	while true
	do
		path=$(uci -q get firewall.@include[$i].path)
		[ -n "$path" ] || break
		[ "$path" = "$OPENWRT_FW_INCLUDE$1" ] && {
	 		echo $i
	 		return 0
		}
		i=$(($i+1))
	done
	return 1
}
openwrt_fw_section_del()
{
	# $1 - fw include postfix

	local id=$(openwrt_fw_section_find $1)
	[ -n "$id" ] && {
		uci delete firewall.@include[$id] && uci commit firewall
		rm -f "$OPENWRT_FW_INCLUDE$1"
	}
}
openwrt_fw_section_add()
{
	openwrt_fw_section_find ||
	{
		uci add firewall include >/dev/null || return
		echo -1
	}
}
openwrt_fw_section_configure()
{
	local id=$(openwrt_fw_section_add $1)
	[ -z "$id" ] ||
	 ! uci set firewall.@include[$id].path="$OPENWRT_FW_INCLUDE" ||
	 ! uci set firewall.@include[$id].reload="1" ||
	 ! uci commit firewall &&
	{
		echo could not add firewall include
		exitp 50
	}
}
install_openwrt_firewall()
{
	echo \* installing firewall script $1
	
	[ -n "MODE" ] || {
		echo should specify MODE in $ZAPRET_CONFIG
		exitp 7
	}
	
	echo "linking : $FW_SCRIPT_SRC => $OPENWRT_FW_INCLUDE"
	ln -fs "$FW_SCRIPT_SRC" "$OPENWRT_FW_INCLUDE"
	
	openwrt_fw_section_configure $1
}
restart_openwrt_firewall()
{
	echo \* restarting firewall

	fw3 -q restart || {
		echo could not restart firewall
		exitp 30
	}
}
remove_openwrt_firewall()
{
	echo \* removing firewall script
	
	openwrt_fw_section_del
	# from old zapret versions. now we use single include
	openwrt_fw_section_del 6
}

clear_ipset()
{
	echo "* clearing ipset(s)"

	# free some RAM
	"$IPSET_DIR/create_ipset.sh" clear
}


service_install_macos()
{
	echo \* installing zapret service

	ln -fs "$ZAPRET_BASE/init.d/macos/zapret.plist" /Library/LaunchDaemons
}
service_start_macos()
{
	echo \* starting zapret service

	"$INIT_SCRIPT_SRC" start
}
service_stop_macos()
{
	echo \* stopping zapret service

	"$INIT_SCRIPT_SRC" stop
}
service_remove_macos()
{
	echo \* removing zapret service

	rm -f /Library/LaunchDaemons/zapret.plist
	zapret_stop_daemons
}

remove_macos_firewall()
{
	echo \* removing zapret PF hooks

	pf_anchors_clear
	pf_anchors_del
	pf_anchor_root_del
	pf_anchor_root_reload
}
