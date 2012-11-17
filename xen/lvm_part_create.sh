#!/bin/bash

# $Id: lvm_part_create.sh 855 2010-02-17 00:46:40Z jhunter $
# $HeadURL: http://sfopsvn/iops/repo/cfe-config-tuk-prd/home/root/scripts/lvm_part_create.sh $

$(/bin/bash -n $0 >> /dev/null 2>&1)
if [ $? -ne 0 ]; then
   $(/bin/bash -n $0)
   echo
   echo "This script has syntax errors, try again!"
   echo
   exit 255
fi

usage() {
    echo "usage: $0 <volume_name> <size:10|24|50> <arch:32|64>"
    echo "ex: $0 sfo-ops-bastion01 10 64"
    echo "ex: $0 tuk-cdc-app02 24 32"
    exit 255
}

exit_check() {
    if [ $1 -ne 0 ]; then
    echo "disk partitioning failed. please check fdisk output/etc."
    exit 1
    fi
}
    
GB=0
NAME=$1
SIZE=$2
ARCH=$3
HOST=$(/bin/hostname)

# toggle true / false for debug info
DEBUG=false

# host/input verification
if ! [[ $HOST =~ "xen" ]]; then 
        echo "ERROR: this script must be run on a dom0 only."
        exit 9
    fi

if [ $# -lt 3 ] || [ $NAME == "" ] || [ $SIZE == "" ] || [ $ARCH == "" ]; then
    usage
fi

VN=$(/bin/echo $SIZE | /bin/egrep [[:alpha:]] | /usr/bin/wc -l)
VS=$(/bin/echo $SIZE | /bin/egrep '10|24|50' | /usr/bin/wc -l)
if [ $VN -gt 0 ] || [ $VS -eq 0 ]; then
    echo "ERROR: invalid size. please retry. (valid sizes: 10|24|50)"
    usage
fi

/bin/echo $ARCH | /bin/egrep '32|64' | /usr/bin/wc -l > /dev/null
if [ $? -ne 0 ]; then
    echo "$ARCH not valid. please try again."
    usage
fi

# is IPPlan up?
/usr/bin/mysql -B -s -h sfnetmon01.sfcolo.current.com -u iops -piops -e "SELECT version()" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "IPPlan not responsive. bailing out."
    exit 6
fi

# do we have valid host info in IPPlan?
HOSTCHECK=$(/usr/bin/mysql -B -s -h sfnetmon01.sfcolo.current.com -u iops -piops -e "SELECT hname, inet_ntoa(ipaddr) AS ip, macaddr FROM ipaddr WHERE hname LIKE '%$NAME%'" ipplan)
HNAME=$(echo $HOSTCHECK | awk '{print $1}')
INET=$(echo $HOSTCHECK | awk '{print $2}')
MAC=$(echo $HOSTCHECK | awk '{print $3}')

if [ "$HNAME" = "" ] || [ "$INET" = "" ] || [ "$MAC" = "" ]; then
    echo "ERROR: host/MAC/IP info not found for $HOST in IPPlan. please retry."
    exit 17
fi

# disk size (default = 24GB host)
ROOT=6144   # /     - 6GB
VAR=6144    # /var  - 6GB
OPT=10240   # /opt  - 10GB
SWAP=2048   # swap  - 2GB

# available disks on the system
DISKS_AVAIL=$(/sbin/fdisk -l | /bin/egrep ^Disk | /bin/awk '{print $2}' | /bin/sed 's/://')
TOT_DISKS=$(/bin/echo $DISKS_AVAIL | /usr/bin/wc -w)
LAST_DISK=$(/bin/echo $DISKS_AVAIL | /bin/awk '{print $'$TOT_DISKS'}')

# does this host already exist on this host?
/usr/sbin/vgdisplay $NAME > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -n "PV $NAME already present on this host. OK to reassign? [y/n] "
    read RESPONSE
    if [[ $RESPONSE =~ "n" ]] || [[ $RESPONSE =~ "N" ]]; then
        echo "exiting."
        exit 127
    fi 
fi 

# clean up existing disks of the same name
/usr/sbin/vgremove -f $NAME > /dev/null 2>&1

for this_disk in $DISKS_AVAIL; do

    # cylinders per GB
    if [ $SIZE == 24 ]; then
        END_CYL=3135    # 24GB
    elif [ $SIZE == 50 ]; then
        OPT=36864       # /opt  - 36GB
        END_CYL=6531    # 50GB
    elif [ $SIZE == 10 ]; then
        ROOT=2048       # /     - 2GB
        VAR=2048        # /var  - 2GB
        OPT=5120        # /opt  - 5GB
        SWAP=1024       # swap  - 1GB
        END_CYL=1307    # 10GB
    fi

    $DEBUG && echo "got: $this_disk"
    
    # is this the very first device created on the extended partition?
    # ie - let's start from the proper position on the disk.
    SETUP=$(/sbin/fdisk $this_disk -l | /bin/egrep '^/dev' | /usr/bin/tail -1)
    /bin/echo $SETUP | /bin/egrep -i 'extended' > /dev/null
    if [ $? -eq 0 ]; then
        START_CYL=$(/sbin/fdisk $this_disk -l | /bin/egrep '^/dev' | /usr/bin/tail -1 | /bin/awk '{print $2}')
    else
        START_CYL=$(/sbin/fdisk $this_disk -l | /bin/egrep '^/dev' | /usr/bin/tail -1 | /bin/awk '{print $3}')
        START_CYL=$((START_CYL + 1))
    fi

    # calculate end cylinder
    END_CYL=$(($START_CYL + $END_CYL))

    $DEBUG && echo "start cyl: $START_CYL"
    $DEBUG && echo "end cyl: $END_CYL"

    # make sure we're not going past the end of the disk
    END_OF_DISK=$(/sbin/fdisk $this_disk -l | /bin/egrep -i 'extended' | /bin/awk '{print $3}')
    if [ $END_CYL -ge $END_OF_DISK ]; then
        echo "INFO: $NAME: last cylinder ($END_CYL) for a ${SIZE}GB VG exceeds that of $this_disk ($END_OF_DISK)."
        echo "trying with the next available disk.."

        # use the next disk..  unless we're already on the last disk.
        if [ "$this_disk" = "$LAST_DISK" ]; then
            echo "ERROR: this host is full. no more disks/space available to write to. re-try with a smaller domU?"
            echo "exiting.."
            exit 9  
        else
            # jump to the next disk in $DISKS_AVAIL
            continue
        fi
    fi

    $DEBUG && echo "disk: $this_disk"
    $DEBUG && echo "setup: $SETUP"
    $DEBUG && echo "name: $NAME"
    $DEBUG && echo "size: $SIZE"
    $DEBUG && echo "start: $START_CYL"
    $DEBUG && echo "end: $END_CYL"

    # write out our new disk (no indent below.. heredocs require left justification)
    echo -n "writing out ${SIZE}GB disk to $this_disk.. "

    # fdisk on non-/dev/sda devices require an addt'l 'l' option.
    if [ "$this_disk" = "/dev/sda" ]; then
/sbin/fdisk $this_disk << XXX > /dev/null 2>&1
n
$START_CYL
$END_CYL
w
XXX
    else
/sbin/fdisk $this_disk << XXX > /dev/null 2>&1
n
l
$START_CYL
$END_CYL
w
XXX
    fi
    echo "done."

    # grab the name of the newly created /dev/sdaX device..
    NEXT_DEV=$(/sbin/fdisk -l $this_disk | /bin/egrep '^/dev' | /usr/bin/tail -1 | /bin/awk '{print $1}')

    # ..rescan the disk.. a few times. :P
    /bin/sync; /bin/sync
    /sbin/partprobe
    sleep 10     # for some reason these syncs need time? :(
    /bin/sync; /bin/sync
    /bin/ls -la $NEXT_DEV > /dev/null 2>&1

    # ..and add the HD partitions
    $DEBUG && echo "/usr/sbin/pvcreate -ff -y $NEXT_DEV"
    /usr/sbin/pvcreate -ff -y $NEXT_DEV 2> /dev/null
    exit_check $?

    $DEBUG && echo "/usr/sbin/vgcreate $NAME $NEXT_DEV 2> /dev/null"
    /usr/sbin/vgcreate $NAME $NEXT_DEV 2> /dev/null
    exit_check $?

    $DEBUG && echo "/usr/sbin/lvcreate -L${ROOT}M -n root $NAME 2> /dev/null"
    /usr/sbin/lvcreate -L${ROOT}M -n root $NAME 2> /dev/null
    exit_check $?

    $DEBUG && echo "/usr/sbin/lvcreate -L${VAR}M -n var $NAME 2> /dev/null"
    /usr/sbin/lvcreate -L${VAR}M -n var $NAME 2> /dev/null
    exit_check $?

    $DEBUG && echo "/usr/sbin/lvcreate -L${OPT}M -n opt $NAME 2> /dev/null"
    /usr/sbin/lvcreate -L${OPT}M -n opt $NAME 2> /dev/null
    exit_check $?

    $DEBUG && echo "/usr/sbin/lvcreate -L${SWAP}M -n swap $NAME 2> /dev/null"
    /usr/sbin/lvcreate -L${SWAP}M -n swap $NAME 2> /dev/null
    exit_check $?

    # just to be safe..
    /sbin/partprobe
    /bin/sync; /bin/sync

    # we wrote our disk. exiting our loop.
    echo "wrote PV $NAME to $NEXT_DEV."
    break

done

    echo "running '/root/scripts/xen_ks.pl $NAME $ARCH'. stand by.."
    /root/scripts/xen_ks.pl $NAME $ARCH
