#!/usr/bin/env bash

set -e

# TODO: add handler for unmounting on exit

function checkExit() {
  if [ $1 -ne 0 ]; then
    /bin/echo "ERR: $2 didn't exit cleanly. exiting."
    exit 256; 
  fi
}

function usage() {
  /bin/echo "USAGE: $(basename $0) IMG_HOSTNAME IMG_SIZE_IN_GB GB_OF_RAM IP_ADDRESS"
  /bin/echo "EX: $(basename $0) ops-test-s1 50 4 10.0.50.28"
  exit 255;
}

function isNumber() {
  [[ -n ${1//[0-9]/} ]] && /bin/echo "ERR: invalid input. exiting." && usage
}

LTS_VERSION="precise"

IMG_HOSTNAME=$1
IMG_SIZE=$2
IMG_RAM=$3
IMG_IP=$4

if [ -z $IMG_HOSTNAME ] || [ -z $IMG_SIZE ] || [ -z $IMG_RAM ] || [ -z $IMG_IP ]; then
  usage
fi

TEMP_MOUNT_DIR="/var/tmp/kvmMount_$$"
IMG_DIR="/var/lib/libvirt/images/"
IMG_IP_GW=$(/bin/echo $IMG_IP | cut -f1,2,3 -d.).1

# input validation
isNumber $IMG_SIZE
isNumber $IMG_RAM
if [[ $IMG_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  IPS=$(/bin/echo $IMG_IP | tr "." "\n")
  for IP in $IPS; do
    isNumber $IP
    ( [[ $IP -lt 0 ]] || [[ $IP -gt 255 ]] ) && /bin/echo "ERR: invalid input. exiting." && usage
    # gateway/broadcast IPs pass for now, but oh well
  done
else
  /bin/echo "ERR: invalid input. exiting." && usage
fi

if [ -f $IMG_DIR$IMG_HOSTNAME ]; then
  /bin/echo "ERR: $IMG_DIR$IMG_HOSTNAME exists already. exiting."
  exit 254;
fi

/bin/echo "INFO: creating $IMG_DIR$IMG_HOSTNAME ($IMG_SIZE GB)"
/bin/dd if=/dev/zero of=$IMG_DIR$IMG_HOSTNAME bs=1000 count=0 seek=$[1024*1024*$IMG_SIZE] > /dev/null 2>&1
checkExit $? 'dd'
/bin/echo "done."

/bin/echo "INFO: mkfs.ext4'ing $IMG_DIR$IMG_HOSTNAME"
/sbin/mkfs.ext4 -F $IMG_DIR$IMG_HOSTNAME > /dev/null 2>&1
checkExit $? 'mkfs'
/bin/echo "done."

/bin/echo "INFO: mounting up/bootstrapping $IMG_DIR$IMG_HOSTNAME"
/bin/mkdir $TEMP_MOUNT_DIR
checkExit $? 'temp mount mkdir'

/bin/mount $IMG_DIR$IMG_HOSTNAME $TEMP_MOUNT_DIR
checkExit $? 'img mount'

/usr/sbin/debootstrap --include=linux-image-virtual,nfs-kernel-server,man-db,upstart,openssh-server,acpid,build-essential,wget,language-pack-en,aptitude,locales,debconf-utils --arch=amd64 $LTS_VERSION $TEMP_MOUNT_DIR
checkExit $? 'debootstrap'

# network stuff
/bin/cat << EOF > $TEMP_MOUNT_DIR/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
 address $IMG_IP
 netmask 255.255.255.0
 gateway $IMG_IP_GW
EOF

# chef chroot install until we merge omnibus packages into our current chef frozen repo. 
# once we merge, this install can be done with debootstrap.
#/usr/sbin/chroot $TEMP_MOUNT_DIR /usr/bin/apt-get update
#/usr/sbin/chroot $TEMP_MOUNT_DIR /usr/bin/apt-get --allow-unauthenticated -y install chef

# console stuff
/bin/cat << EOF > $TEMP_MOUNT_DIR/etc/init/ttyS0.conf
start on stopped rc RUNLEVEL=[2345]
stop on runlevel [!2345]

respawn
exec /sbin/getty -L 57600 ttyS0 vt102
EOF

# set root's shadowed password to 'fai' by default
/bin/sed -i -e 's/root\:\*\:/root:\$1\$\/se2gGGk\$xW5z\/jrIpmpcY86T6e2OJ\.\:/g' $TEMP_MOUNT_DIR/etc/shadow

# in order to prevent MAC collisions, we read all xmls in the KVM conf dir, grab the last 2 digits off the last available hex, and increment
LAST_HEX_IN_USE=$(/bin/grep -i 'mac address' /etc/libvirt/qemu/*.xml | /usr/bin/awk -F: {'print $7'} | /usr/bin/awk -F\' {'print $1'} | /usr/bin/sort -n | /usr/bin/tail -1)
if [ "$LAST_HEX_IN_USE" == "" ]; then
  LAST_HEX_IN_USE=A0
fi
NEXT_HOST_HEX=$(/bin/echo "obase=ibase=16; $LAST_HEX_IN_USE + 1" | /usr/bin/bc)

# in order to prevent MAC collisions, we generate a hex value <= 255 off of the hostname
ASCII_COUNT=0
HOSTNAME=$(/bin/hostname)
for LETTER in $(/bin/echo $HOSTNAME | /usr/bin/fold -w1); do
  ASCII_COUNT=$((ASCII_COUNT + $(/usr/bin/printf "%d\n" \'$LETTER)))
done
ASCII_MOD=$(/usr/bin/expr $ASCII_COUNT % 255)
HOSTNAME_HEX=$(/bin/echo "ibase=10;obase=16; $ASCII_MOD" | /usr/bin/bc)

IMG_RAM=$(((IMG_RAM * 1024) * 1024))
RANDOM_UUID=$(/usr/bin/uuidgen)

# build the KVM XML config
/bin/cat << EOF > /etc/libvirt/qemu/$IMG_HOSTNAME.xml
<domain type='kvm'>
  <name>$IMG_HOSTNAME</name>
  <uuid>$RANDOM_UUID</uuid>
  <memory>$IMG_RAM</memory>
  <currentMemory>$IMG_RAM</currentMemory>
  <vcpu>1</vcpu>
  <os>
    <type arch='x86_64' machine='pc-0.12'>hvm</type>
    <kernel>/var/lib/libvirt/boot/vmlinuz-3.2.0-23-virtual</kernel> 
    <initrd>/var/lib/libvirt/boot/initrd.img-3.2.0-23-virtual</initrd>
    <cmdline>ro root=/dev/sda console=tty0 console=ttyS0,115200n8</cmdline>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
  </features>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/kvm</emulator>
    <disk type='file' device='disk'>
      <source file='$IMG_DIR$IMG_HOSTNAME'/>
      <target dev='hda'/>
    </disk>
    <interface type='bridge'>
      <mac address='52:54:00:3D:$HOSTNAME_HEX:$NEXT_HOST_HEX'/>
      <source bridge='br0'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target port='0'/>
    </console>
    <input type='mouse' bus='ps2'/>
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1' keymap='en-us'/>
    <video>
      <model type='cirrus' vram='9216' heads='1'/>
    </video>
  </devices>
</domain>
EOF

/bin/echo -e $IMG_IP '\t' $IMG_HOSTNAME >> $TEMP_MOUNT_DIR/etc/hosts
/bin/echo $IMG_HOSTNAME > $TEMP_MOUNT_DIR/etc/hostname

/bin/umount $TEMP_MOUNT_DIR
checkExit $? 'img umount'

/bin/rm -rf $TEMP_MOUNT_DIR
checkExit $? 'temp mount rmdir'

/bin/echo "INFO: done!"
exit 0
