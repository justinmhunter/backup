#!/bin/bash

$(/bin/bash -n $0 >> /dev/null 2>&1)
if [ $? -ne 0 ]; then
   $(/bin/bash -n $0)
   echo
   echo "This script has syntax errors, try again!"
   echo
   exit 255
fi

NAME=$1
SIZE=$2
RAM=$3
PR=$4

exit_check() {
    if [ $1 -ne 0 ]; then
    echo "ERROR: $2 ($1) failed. exiting."
    exit 1
    fi
}

XD="/data/xen/disks"
CD="/etc/xen/configs"
XC="/etc/xen/configs/xen_ks_list"

if [ "$NAME" == "" ] || [ "$SIZE" == "" ] || [ "$RAM" == "" ] || [ "$PR" == "" ]; then
    echo "usage: $0 <xen_name> <size_in_GB> <RAM_amt> <CentOS_pt_rel>"
    echo "ex: $0 slhx-lab-adm01 50 2 5.4"
    exit 1
fi

# point release validation
if [ "$PR" != "5.4" ] && [ "$PR" != "5.5" ]; then
    echo "ERROR: CentOS 5.4/5.5 are your only valid choices."
    exit 1
fi

# check if disk is present
if [ -e $XD/$NAME ]; then
    echo "ERROR: $XD/$NAME already present!"
    exit 1
fi

# map file check
if ! [ -e $XC ]; then
    echo "ERROR: $XC not found!"
    echo "file syntax should be: $NAME:00:41"
    exit 1
fi

# error if the host isn't present in the map
HP=$(/bin/grep -c "$NAME:" $XC)
if [ $HP -ne 1 ]; then
    echo "ERROR: $NAME absent from $XC. please doublecheck."
    exit 1
fi

# look up the host in the map (grab IP/MAC)
MAC=$(/bin/grep "$NAME:" $XC | awk -F: '{print $2}')
IP=$(/bin/grep "$NAME:" $XC | awk -F: '{print $3}')

# calculate size for RAM/disk
SIZE=$((SIZE * 1024))
RAM=$((RAM * 1024))

# write our disk
/bin/dd if=/dev/zero of=$XD/$NAME bs=1k seek=${SIZE}k count=1 > /dev/null 2>&1
exit_check $? dd

# create the symlink
ln -s $CD/$NAME /etc/xen/auto/$NAME
exit_check $? ln

# write the KS file
cat << XXX > $CD/$NAME-ks
name        = "$NAME-ks"
kernel      = "/etc/xen/kernel/centos$PR-x86_64/vmlinuz"
ramdisk     = "/etc/xen/kernel/centos$PR-x86_64/initrd.img"
vif         = [ 'mac=00:16:3e:00:00:$MAC, bridge=xenbr0' ]
extra       = "text ks=http://10.2.8.32/cgi-bin/xen_ks.cgi?$NAME?$IP?$PR ip=10.2.8.$IP netmask=255.255.255.0 gateway=10.2.8.1 dns=10.2.8.54"
disk        = [ 'tap:aio:$XD/$NAME,xvda,w' ]
memory      = "$RAM"
on_reboot   = 'destroy'
on_crash    = 'destroy'
XXX

# write the regular file
cat << XXX > $CD/$NAME
name        = "$NAME"
disk        = [ 'tap:aio:$XD/$NAME,xvda,w' ]
vif         = [ 'mac=00:16:3e:00:00:$MAC,bridge=xenbr0' ]
bootloader  = "/usr/bin/pygrub"
memory      = "$RAM"
vcpus       = 1
extra       = "4 enforcing=0"
on_reboot   = 'destroy'
on_crash    = 'destroy'
XXX

# exit check $?
