#!/bin/bash
#
# iptables	Start iptables firewall
#
# chkconfig: 2345 08 92
# description:	Starts, stops and saves iptables firewall
#
# config: /etc/sysconfig/iptables
# config: /etc/sysconfig/iptables-config
#
### BEGIN INIT INFO
# Provides: iptables
# Required-Start:
# Required-Stop:
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: start and stop iptables firewall
# Description: Start, stop and save iptables firewall
### END INIT INFO

# Source function library.
. /etc/init.d/functions

IPTABLES=iptables
IPTABLES_DATA=/etc/sysconfig/$IPTABLES
IPTABLES_FALLBACK_DATA=${IPTABLES_DATA}.fallback
IPTABLES_CONFIG=/etc/sysconfig/${IPTABLES}-config
IPV=${IPTABLES%tables} # ip for ipv4 | ip6 for ipv6
[ "$IPV" = "ip" ] && _IPV="ipv4" || _IPV="ipv6"
PROC_IPTABLES_NAMES=/proc/net/${IPV}_tables_names
VAR_SUBSYS_IPTABLES=/var/lock/subsys/$IPTABLES
RESTORECON=$(which restorecon 2>/dev/null)
[ ! -x "$RESTORECON" ] && RESTORECON=/bin/true

# only usable for root
if [ $EUID != 0 ]; then
    echo -n $"${IPTABLES}: Only usable by root."; warning; echo
    exit 4
fi

if [ ! -x /sbin/$IPTABLES ]; then
    echo -n $"${IPTABLES}: /sbin/$IPTABLES does not exist."; warning; echo
    exit 5
fi

# Default firewall configuration:
IPTABLES_MODULES=""
IPTABLES_SAVE_ON_STOP="no"
IPTABLES_SAVE_ON_RESTART="no"
IPTABLES_SAVE_COUNTER="no"
IPTABLES_STATUS_NUMERIC="yes"
IPTABLES_STATUS_VERBOSE="no"
IPTABLES_STATUS_LINENUMBERS="yes"
IPTABLES_SYSCTL_LOAD_LIST=""
IPTABLES_RESTORE_WAIT=600
IPTABLES_RESTORE_WAIT_INTERVAL=1000000

# Load firewall configuration.
[ -f "$IPTABLES_CONFIG" ] && . "$IPTABLES_CONFIG"

# Get active tables
NF_TABLES=$(cat "$PROC_IPTABLES_NAMES" 2>/dev/null)

# Prepare commands for wait options
IPTABLES_CMD="$IPTABLES"
IPTABLES_RESTORE_CMD="$IPTABLES-restore"
if [ $IPTABLES_RESTORE_WAIT -ne 0 ]; then
	OPT="--wait ${IPTABLES_RESTORE_WAIT}"
	if [ $IPTABLES_RESTORE_WAIT_INTERVAL -lt 1000000 ]; then
	    OPT+=" --wait-interval ${IPTABLES_RESTORE_WAIT_INTERVAL}"
	fi
	IPTABLES_CMD+=" $OPT"
	IPTABLES_RESTORE_CMD+=" $OPT"
fi

flush_n_delete() {
    local ret=0

    # Flush firewall rules and delete chains.
    [ ! -e "$PROC_IPTABLES_NAMES" ] && return 0

    # Check if firewall is configured (has tables)
    [ -z "$NF_TABLES" ] && return 1

    echo -n $"${IPTABLES}: Flushing firewall rules: "
    # For all tables
    for i in $NF_TABLES; do
        # Flush firewall rules.
	$IPTABLES_CMD -t $i -F;
	let ret+=$?;

        # Delete firewall chains.
	$IPTABLES_CMD -t $i -X;
	let ret+=$?;

	# Set counter to zero.
	$IPTABLES_CMD -t $i -Z;
	let ret+=$?;
    done

    [ $ret -eq 0 ] && success || failure
    echo
    return $ret
}

set_policy() {
    local ret=0

    # Set policy for configured tables.
    policy=$1

    # Check if iptable module is loaded
    [ ! -e "$PROC_IPTABLES_NAMES" ] && return 0

    # Check if firewall is configured (has tables)
    tables=$(cat "$PROC_IPTABLES_NAMES" 2>/dev/null)
    [ -z "$tables" ] && return 1

    echo -n $"${IPTABLES}: Setting chains to policy $policy: "
    for i in $tables; do
	echo -n "$i "
	case "$i" in
	    raw)
		$IPTABLES_CMD -t raw -P PREROUTING $policy \
		    && $IPTABLES_CMD -t raw -P OUTPUT $policy \
		    || let ret+=1
		;;
	    filter)
                $IPTABLES_CMD -t filter -P INPUT $policy \
		    && $IPTABLES_CMD -t filter -P OUTPUT $policy \
		    && $IPTABLES_CMD -t filter -P FORWARD $policy \
		    || let ret+=1
		;;
	    nat)
		$IPTABLES_CMD -t nat -P PREROUTING $policy \
		    && $IPTABLES_CMD -t nat -P POSTROUTING $policy \
		    && $IPTABLES_CMD -t nat -P OUTPUT $policy \
		    || let ret+=1
		;;
	    mangle)
	        $IPTABLES_CMD -t mangle -P PREROUTING $policy \
		    && $IPTABLES_CMD -t mangle -P POSTROUTING $policy \
		    && $IPTABLES_CMD -t mangle -P INPUT $policy \
		    && $IPTABLES_CMD -t mangle -P OUTPUT $policy \
		    && $IPTABLES_CMD -t mangle -P FORWARD $policy \
		    || let ret+=1
		;;
	    security)
	        # Ignore the security table
	        ;;
	    *)
	        let ret+=1
		;;
        esac
    done

    [ $ret -eq 0 ] && success || failure
    echo
    return $ret
}

load_sysctl() {
    local ret=0

    # load matched sysctl values
    if [ -n "$IPTABLES_SYSCTL_LOAD_LIST" ]; then
        echo -n $"Loading sysctl settings: "
        for item in $IPTABLES_SYSCTL_LOAD_LIST; do
            fgrep -hs $item /etc/sysctl.d/* | sysctl -p - >/dev/null
            let ret+=$?;
        done
        [ $ret -eq 0 ] && success || failure
        echo
    fi
    return $ret
}

start() {
    local ret=0

    # Do not start if there is no config file.
    if [ ! -f "$IPTABLES_DATA" ]; then
	echo -n $"${IPTABLES}: No config file."; warning; echo
	return 6
    fi

    # check if ipv6 module load is deactivated
    if [ "${_IPV}" = "ipv6" ] \
	&& grep -qIsE "^install[[:space:]]+${_IPV}[[:space:]]+/bin/(true|false)" /etc/modprobe.conf /etc/modprobe.d/* ; then
	echo $"${IPTABLES}: ${_IPV} is disabled."
	return 150
    fi

    echo -n $"${IPTABLES}: Applying firewall rules: "

    OPT=
    [ "x$IPTABLES_SAVE_COUNTER" = "xyes" ] && OPT="-c"

    $IPTABLES_RESTORE_CMD $OPT $IPTABLES_DATA
    if [ $? -eq 0 ]; then
	success; echo
    else
	failure; echo;
	if [ -f "$IPTABLES_FALLBACK_DATA" ]; then
	    echo -n $"${IPTABLES}: Applying firewall fallback rules: "
	    $IPTABLES_RESTORE_CMD $OPT $IPTABLES_FALLBACK_DATA
	    if [ $? -eq 0 ]; then
		success; echo
	    else
		failure; echo; return 1
	    fi
	else
	    return 1
	fi
    fi

    # Load additional modules (helpers)
    if [ -n "$IPTABLES_MODULES" ]; then
	echo -n $"${IPTABLES}: Loading additional modules: "
	for mod in $IPTABLES_MODULES; do
	    echo -n "$mod "
	    modprobe $mod > /dev/null 2>&1
	    let ret+=$?;
	done
	[ $ret -eq 0 ] && success || failure
	echo
    fi

    # Load sysctl settings
    load_sysctl

    touch $VAR_SUBSYS_IPTABLES
    return $ret
}

stop() {
    local ret=0

    # Do not stop if iptables module is not loaded.
    [ ! -e "$PROC_IPTABLES_NAMES" ] && return 0

    # Set default chain policy to ACCEPT, in order to not break shutdown
    # on systems where the default policy is DROP and root device is
    # network-based (i.e.: iSCSI, NFS)
    set_policy ACCEPT
    let ret+=$?
    # And then, flush the rules and delete chains
    flush_n_delete
    let ret+=$?

    rm -f $VAR_SUBSYS_IPTABLES
    return $ret
}

save() {
    local ret=0

    # Check if iptable module is loaded
    if [ ! -e "$PROC_IPTABLES_NAMES" ]; then
	echo -n $"${IPTABLES}: Nothing to save."; warning; echo
	return 0
    fi

    # Check if firewall is configured (has tables)
    if [ -z "$NF_TABLES" ]; then
	echo -n $"${IPTABLES}: Nothing to save."; warning; echo
	return 6
    fi

    echo -n $"${IPTABLES}: Saving firewall rules to $IPTABLES_DATA: "

    OPT=
    [ "x$IPTABLES_SAVE_COUNTER" = "xyes" ] && OPT="-c"

    TMP_FILE=$(/bin/mktemp -q $IPTABLES_DATA.XXXXXX) \
	&& chmod 600 "$TMP_FILE" \
	&& $IPTABLES-save $OPT > $TMP_FILE 2>/dev/null \
	&& size=$(stat -c '%s' $TMP_FILE) && [ $size -gt 0 ] \
	|| ret=1
    if [ $ret -eq 0 ]; then
	if [ -e $IPTABLES_DATA ]; then
	    cp -f $IPTABLES_DATA $IPTABLES_DATA.save \
		&& chmod 600 $IPTABLES_DATA.save \
		&& $RESTORECON $IPTABLES_DATA.save \
		|| ret=1
	fi
	if [ $ret -eq 0 ]; then
	    mv -f $TMP_FILE $IPTABLES_DATA \
		&& chmod 600 $IPTABLES_DATA \
		&& $RESTORECON $IPTABLES_DATA \
	        || ret=1
	fi
    fi
    rm -f $TMP_FILE
    [ $ret -eq 0 ] && success || failure
    echo
    return $ret
}

status() {
    if [ ! -f "$VAR_SUBSYS_IPTABLES" ] && [ -z "$NF_TABLES" ]; then
	echo $"${IPTABLES}: Firewall is not running."
	return 3
    fi

    # Do not print status if lockfile is missing and iptables modules are not
    # loaded.
    # Check if iptable modules are loaded
    if [ ! -e "$PROC_IPTABLES_NAMES" ]; then
	echo $"${IPTABLES}: Firewall modules are not loaded."
	return 3
    fi

    # Check if firewall is configured (has tables)
    if [ -z "$NF_TABLES" ]; then
	echo $"${IPTABLES}: Firewall is not configured. "
	return 3
    fi

    NUM=
    [ "x$IPTABLES_STATUS_NUMERIC" = "xyes" ] && NUM="-n"
    VERBOSE=
    [ "x$IPTABLES_STATUS_VERBOSE" = "xyes" ] && VERBOSE="--verbose"
    COUNT=
    [ "x$IPTABLES_STATUS_LINENUMBERS" = "xyes" ] && COUNT="--line-numbers"

    for table in $NF_TABLES; do
	echo $"Table: $table"
	$IPTABLES -t $table --list $NUM $VERBOSE $COUNT && echo
    done

    return 0
}

reload() {
    local ret=0

    # Do not reload if there is no config file.
    if [ ! -f "$IPTABLES_DATA" ]; then
	echo -n $"${IPTABLES}: No config file."; warning; echo
	return 6
    fi

    # check if ipv6 module load is deactivated
    if [ "${_IPV}" = "ipv6" ] \
	&& grep -qIsE "^install[[:space:]]+${_IPV}[[:space:]]+/bin/(true|false)" /etc/modprobe.conf /etc/modprobe.d/* ; then
	echo $"${IPTABLES}: ${_IPV} is disabled."
	return 150
    fi

    echo -n $"${IPTABLES}: Trying to reload firewall rules: "

    OPT=
    [ "x$IPTABLES_SAVE_COUNTER" = "xyes" ] && OPT="-c"

    $IPTABLES_RESTORE_CMD $OPT $IPTABLES_DATA
    if [ $? -eq 0 ]; then
	success; echo
    else
	failure; echo; echo "Firewall rules are not changed."; return 1
    fi

    # Load additional modules (helpers)
    if [ -n "$IPTABLES_MODULES" ]; then
	echo -n $"${IPTABLES}: Loading additional modules: "
	for mod in $IPTABLES_MODULES; do
	    echo -n "$mod "
	    modprobe $mod > /dev/null 2>&1
	    let ret+=$?;
	done
	[ $ret -eq 0 ] && success || failure
	echo
    fi

    # Load sysctl settings
    load_sysctl

    return $ret
}

restart() {
    [ "x$IPTABLES_SAVE_ON_RESTART" = "xyes" ] && save
    stop
    start
}


case "$1" in
    start)
	[ -f "$VAR_SUBSYS_IPTABLES" ] && exit 0
	start
	RETVAL=$?
	;;
    stop)
	[ "x$IPTABLES_SAVE_ON_STOP" = "xyes" ] && save
	stop
	RETVAL=$?
	;;
    restart|force-reload)
	restart
	RETVAL=$?
	;;
    reload)
	[ -e "$VAR_SUBSYS_IPTABLES" ] && reload
	RETVAL=$?
	;;
    condrestart|try-restart)
	[ ! -e "$VAR_SUBSYS_IPTABLES" ] && exit 0
	restart
	RETVAL=$?
	;;
    status)
	status
	RETVAL=$?
	;;
    panic)
	set_policy DROP
	RETVAL=$?
        ;;
    save)
	save
	RETVAL=$?
	;;
    *)
	echo $"Usage: ${IPTABLES} {start|stop|reload|restart|condrestart|status|panic|save}"
	RETVAL=2
	;;
esac

exit $RETVAL
