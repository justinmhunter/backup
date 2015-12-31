#!/usr/bin/env bash

set -e

# TODO: why doesn't this work? :P
trap cleanUp INT

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

function checkExit() {
  if [[ $1 -ne 0 ]]; then
    echo "ERR: $2 didn't exit cleanly. exiting."
    cleanUp
    exit 1
  fi
  echo "$2: done."
}

function cleanUp() {
  umount -f "$TEMP_MOUNT_DIR" > /dev/null 2>&1
  rm -f "$IMG_FULL_PATH"
}

function usage() {
  echo "USAGE: $(basename $0) IMG_HOSTNAME IMG_SIZE_IN_GB GB_OF_RAM IP_ADDRESS"
  echo "EX: $(basename $0) my-test-host 50 4 10.0.0.21"
  exit 1
}

function isNumber() {
  if ! [[ $1 =~ ^[0-9]+$ ]]; then
    echo "ERR: invalid input. exiting." && usage
  fi
}

TEMP_MOUNT_DIR="/var/tmp/kvmMount_$$"
IMG_DIR="/var/lib/libvirt/images"

IMG_HOSTNAME=$1
IMG_SIZE=$2
IMG_RAM=$3
IMG_IP=$4
IMG_IP_GW=$(echo "$IMG_IP" | cut -f1,2,3 -d.).1
IMG_FULL_PATH="$IMG_DIR/$IMG_HOSTNAME"
IMG_XML_CONFIG="/etc/libvirt/qemu/$IMG_HOSTNAME.xml"

if [ -z "$IMG_HOSTNAME" ] || [ -z "$IMG_SIZE" ] || [ -z "$IMG_RAM" ] || [ -z "$IMG_IP" ]; then
  usage
fi

# input validation
isNumber "$IMG_SIZE"
isNumber "$IMG_RAM"
if [[ $IMG_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  IPS=$(echo "$IMG_IP" | tr "." "\n")
  for IP in $IPS; do
    isNumber "$IP"
    ( [[ $IP -lt 0 ]] || [[ $IP -gt 255 ]] ) && echo "ERR: invalid input. exiting." && usage
    # gateway/broadcast IPs also pass for now, but oh well
  done
else
  echo "ERR: invalid input. exiting." && usage
fi

if [ -f "$IMG_FULL_PATH" ]; then
  echo "ERR: $IMG_FULL_PATH exists already. exiting."
  exit 1
fi

echo "INFO: creating $IMG_FULL_PATH ($IMG_SIZE GB)"
dd if=/dev/zero of="$IMG_FULL_PATH" bs=1000 count=0 seek=$((1024*1024*IMG_SIZE)) > /dev/null 2>&1
checkExit $? 'dd'

echo "INFO: mkfs.ext4'ing $IMG_FULL_PATH"
mkfs.ext4 -F "$IMG_FULL_PATH" > /dev/null 2>&1
checkExit $? 'mkfs'

echo "INFO: mounting up/bootstrapping $IMG_FULL_PATH"
mkdir "$TEMP_MOUNT_DIR"
checkExit $? 'temp mount mkdir'

mount "$IMG_FULL_PATH" "$TEMP_MOUNT_DIR"
checkExit $? 'img mount'

. /etc/lsb-release
debootstrap --include=linux-image-virtual,nfs-kernel-server,man-db,upstart,openssh-server,acpid,build-essential,wget,language-pack-en,aptitude,locales,debconf-utils --arch=amd64 "$DISTRIB_CODENAME" "$TEMP_MOUNT_DIR"
checkExit $? 'debootstrap'

# network stuff
cat << EOF > $TEMP_MOUNT_DIR/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
 address $IMG_IP
 netmask 255.255.255.0
 gateway $IMG_IP_GW
EOF

# VM console stuff
/bin/cat << EOF > $TEMP_MOUNT_DIR/etc/init/ttyS0.conf
start on stopped rc RUNLEVEL=[2345]
stop on runlevel [!2345]

respawn
exec /sbin/getty -L 57600 ttyS0 vt102
EOF

# to prevent MAC collisions, read all XMLs in the conf dir, grab the last 2 digits off the last available hex, and increment
LAST_HEX_IN_USE=$(grep -i 'mac address' /etc/libvirt/qemu/*.xml | awk -F: {'print $7'} | awk -F\' {'print $1'} | sort -n | tail -1)
if [ "$LAST_HEX_IN_USE" == "" ]; then
  LAST_HEX_IN_USE=A0
fi
NEXT_HOST_HEX=$(echo "obase=ibase=16; $LAST_HEX_IN_USE + 1" | bc)

# to prevent MAC collisions, generate a hex value <= 255 based on the hostname
ASCII_COUNT=0
HOSTNAME=$(hostname)
for LETTER in $(echo "$HOSTNAME" | fold -w1); do
  ASCII_COUNT=$((ASCII_COUNT + $(printf "%d\n" \'"$LETTER")))
done
ASCII_MOD=$((ASCII_COUNT % 255))
HOSTNAME_HEX=$(echo "ibase=10;obase=16; $ASCII_MOD" | bc)

IMG_RAM=$(((IMG_RAM * 1024) * 1024))
RANDOM_UUID=$(uuidgen)

# symlink back to our running kernels so things can ultimately boot
KVM_BOOT_DIR=/var/lib/libvirt/boot
if ! [ -f $KVM_BOOT_DIR/source ]; then
  echo "Missing source dir for KVM. Creating symlink in $KVM_BOOT_DIR"
  ln -s /boot $KVM_BOOT_DIR/source
  checkExit $? 'source dir symlink'
fi

# build the KVM XML config
RUNNING_KERNEL=$(uname -r)
/bin/cat << EOF > $IMG_XML_CONFIG
<domain type='kvm'>
  <name>$IMG_HOSTNAME</name>
  <uuid>$RANDOM_UUID</uuid>
  <memory>$IMG_RAM</memory>
  <currentMemory>$IMG_RAM</currentMemory>
  <vcpu>1</vcpu>
  <os>
    <type arch='x86_64' machine='pc-0.12'>hvm</type>
    <kernel>$KVM_BOOT_DIR/source/vmlinuz-$RUNNING_KERNEL</kernel> 
    <initrd>$KVM_BOOT_DIR/source/initrd.img-$RUNNING_KERNEL</initrd>
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
      <source file='$IMG_FULL_PATH'/>
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

# set up hosts/hostname
echo -e "$IMG_IP" '\t' "$IMG_HOSTNAME" >> $TEMP_MOUNT_DIR/etc/hosts
echo "$IMG_HOSTNAME" > $TEMP_MOUNT_DIR/etc/hostname

# set root's shadowed password to 'fai' by default and enable SSH
sed -i 's/root\:\*\:/root:\$1\$\/se2gGGk\$xW5z\/jrIpmpcY86T6e2OJ\.\:/g' $TEMP_MOUNT_DIR/etc/shadow
sed -i '0,/without-password/s//yes/' $TEMP_MOUNT_DIR/etc/ssh/sshd_config

umount "$TEMP_MOUNT_DIR"
checkExit $? 'img umount'

rm -rf "$TEMP_MOUNT_DIR"
checkExit $? 'temp mount rmdir'

echo "INFO: done. Starting $IMG_HOSTNAME.."

virsh create $IMG_XML_CONFIG
checkExit $? 'virsh create'

exit 0
