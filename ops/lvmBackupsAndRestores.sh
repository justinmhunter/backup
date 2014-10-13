#!/usr/bin/env bash

# how to utilize this script:
# * from a 'good' DB slave - cron your nightly backups. 
# * from a 'bad' DB slave - restores should just be wysiwyg.

# notes:
# * some clusters take 20+ hours to tar over the snapshot, so depending on when you cron things, it might skip a day 
#   since I'm not allowing this script to run on top of already running tar pipes.
# * everything is syslog'ed.

# adding comment to test GH

$(/bin/bash -n $0 >> /dev/null 2>&1)
if [ $? -ne 0 ]; then
   $(/bin/bash -n $0)
   echo
   echo "This script has syntax errors, try again!"
   echo
   exit 255
fi

trap 'logIt "caught a signal"; cleanupBackups; exit' 1 2 15
 
function usage()
{
  echo "usage: $0 -h | -backup | -restore"
  exit
}

function getBackupHost()
{
  case "$1" in
    'db-sa')
      buh='storage-s1'
      ;;
    'db-sb')
      buh='storage-s2'
      ;;
    'db-sc')
      buh='storage-s3'
      ;;
    'db-sd')
      buh='storage-s4'
      ;;
    'db-ia')
      buh='storage-s1'
      ;;
    'db-ib')
      buh='storage-s2'
      ;;
    'db-ic')
      buh='storage-s3'
      ;;
    'db-id')
      buh='storage-s4'
      ;;
  esac
  echo $buh
}

function isMySqlSlave()
{
  SLAVE_STATUS=$(/usr/bin/mysql -ulvmbackupuser -plvmbackuppass -h localhost -e "SHOW SLAVE STATUS;" | /usr/bin/wc -l) 
  if [ $SLAVE_STATUS -eq 0 ]; then
    echo "ERR: this script is only to be run on a MySQL slave. exiting."
    usage
  fi
}

function isMySqlRunning()
{
  MYSQL_STATUS=$(/bin/netstat -antp | /bin/grep 3306 | /bin/grep LISTEN | /usr/bin/wc -l)
  if [ $MYSQL_STATUS -gt 0 ]; then
    echo "ERR: MySQL appears to still be running. stop it and try again."
    exit
  fi
}

function isBackupDirPresent() 
{
  BACKUP_DIR=$(/usr/bin/ssh $1 ls /home/backup/ | /bin/grep $2)
  if [ ! $BACKUP_DIR ]; then
    echo "problems find backup dir matching '$2' on $1:/home/backup. exiting."
    exit
  fi
  echo "found backup dir '$BACKUP_DIR' on $1:/home/backup. proceeding."
}

function deletePidFile()
{
  rm -f $PID_FILE
  if [ -e $PID_FILE ]; then
    logIt "ERR: removal of $PID_FILE failed. exiting."
    exit
  else
    logIt "$PID_FILE removed."
  fi
}

function isThisScriptRunning()
{
  if [ -e $PID_FILE ]; then
    logIt "INFO: found $PID_FILE."
    PROC_COUNT=$(/bin/ps waux | /bin/grep tar | /bin/grep clusterBackups | /bin/grep -v grep | /usr/bin/wc -l)
    TAR_PID=$(/bin/ps waux | /bin/grep tar | /bin/grep clusterBackups | /bin/grep -v grep | awk '{print $2}')
    AGE=$(/usr/bin/stat -c %Z $PID_FILE)
    NOW=$(/bin/date +%s)
    DIFF=$(( $NOW - $AGE ))
    if [ $DIFF -gt 86400 ]; then
      logIt "$PID_FILE is older than 24h. assuming borked previous run. cleaning up." 
      if [ $PROC_COUNT -gt 0 ]; then
        logIt "found running tar proc. killing it."
        kill -9 $TAR_PID
      fi
      cleanupBackups
      deletePidFile
    else
      if [ $PROC_COUNT -gt 0 ]; then
        logIt "$PID_FILE is $DIFF seconds old. process is still running, so exiting for now."
        exit
      fi
      logIt "$PID_FILE is $DIFF seconds old, but not finding any running tar procs. botched previous run? cleaning up."
      cleanupBackups
      deletePidFile
    fi
  fi
}

function logIt() 
{
  logger -s "$1" -t mylvmbackup[$$]
}

function cleanupBackups()
{
  if [ -d $BACKUP_MOUNT_POINT ]; then
    logIt "found $BACKUP_MOUNT_POINT."
    if [ $(/bin/mount | /bin/grep mylvmbackup | /usr/bin/wc -l) -gt 0 ]; then
      logIt "unmounting $BACKUP_MOUNT_POINT."
      /bin/umount -f $BACKUP_MOUNT_POINT > /dev/null 2>&1
      if [ $? -ne 0 ]; then
        logIt "unmount of $BACKUP_MOUNT_POINT failed."
        exit
      fi
    fi
    logIt "removing $BACKUP_MOUNT_POINT."
    /bin/rm -rf $BACKUP_MOUNT_POINT
    if [ $? -ne 0 ]; then
      logIt "removal of $BACKUP_MOUNT_POINT failed."
      exit
    fi 
    logIt "$BACKUP_MOUNT_POINT umounted/removed."
  fi
  if [ -e $BACKUP_LOGICAL_VOLUME ]; then
    logIt "found $BACKUP_LOGICAL_VOLUME. removing."
    /sbin/lvremove -f $BACKUP_LOGICAL_VOLUME > /dev/null 2>&1
    if [ $? -ne -0 ]; then
      logIt "removal of $BACKUP_LOGICAL_VOLUME failed. "
      exit
    fi
    logIt "$BACKUP_LOGICAL_VOLUME removed."
  fi
}

function doBackup()
{
  NOW=$(date +%Y%m%d)
  THISHOST=$(hostname)
  BACKUP_HOST=$(getBackupHost $(echo $THISHOST | cut -c 1-5))

  BACKUP_MOUNT_POINT=/var/cache/mylvmbackup/mnt/backup
  BACKUP_LOGICAL_VOLUME=/dev/mapper/raid10-mysql_data_snapshot
  BACKUP_COMMAND="/usr/bin/mylvmbackup --user=lvmbackupuser --password=lvmbackuppass --host=localhost --vgname=raid10 --lvname=mysql_data --backuptype=none --lvsize=100G --keep_snapshot --keep_mount --log_method=syslog"
  TODAY_BACKUP_FOLDER=clusterBackups_$THISHOST"_"$NOW
  TAR_COMMAND_BACKUP="cd $BACKUP_MOUNT_POINT; /bin/tar zcf - . | /usr/bin/ssh -o StrictHostKeyChecking=no $BACKUP_HOST \"(cd /home/backup/; mkdir -p $TODAY_BACKUP_FOLDER; /bin/tar zxf - -C $TODAY_BACKUP_FOLDER --touch)\""

  NUM_OF_MOUNTED_FILES="/bin/ls $BACKUP_MOUNT_POINT | /usr/bin/wc -l"

  PID_FILE=/var/run/lvmBackups

  isMySqlSlave
  isThisScriptRunning

  [ -d $BACKUP_MOUNT_POINT ] && logIt "$BACKUP_MOUNT_POINT already found. botched previous run? attempting to clean up." && cleanupBackups
  [ -e $BACKUP_LOGICAL_VOLUME ] && logIt "$BACKUP_LOGICAL_VOLUME already found. botched previous run? attempting to clean up." && cleanupBackups

  logIt "beginning lvmbackup."
  touch $PID_FILE
  /usr/bin/mylvmbackup --user=lvmbackupuser --password=lvmbackuppass --host=localhost --vgname=raid10 --lvname=mysql_data --backuptype=none --lvsize=100G --keep_snapshot --keep_mount --log_method=syslog
  logIt "lvmbackup completed."

  # did mylvmbackup succeed at taking a snapshot? if so, do the tar pipe.
  if [ -d $BACKUP_MOUNT_POINT ]; then
    if [ $(eval $NUM_OF_MOUNTED_FILES) > 0 ]; then
      logIt "starting tar pipe to $BACKUP_HOST via the following:"
      logIt "$TAR_COMMAND_BACKUP"
      ($(eval $TAR_COMMAND_BACKUP) && logIt "tar pipe to $BACKUP_HOST completed successfully." && printf "$THISHOST\tMySQL_LVM_Backups\t0\tOK\n" | /usr/sbin/send_nsca -c /etc/nsca.cfg -H monitor-s3 >/dev/null 2>&1 ) || ( logIt "tar pipe to $BACKUP_HOST failed." && cleanupBackups && exit )
    else
      logIt "$BACKUP_MOUNT_POINT seems to be empty. mylvmbackup failed somehow. investigate further." 
      exit
    fi
  else
    logIt "not finding $BACKUP_MOUNT_POINT. mylvmbackup failed somehow. investigate further." true
    exit
  fi
  rm -f $PID_FILE
  cleanupBackups
  exit
}

function doRestore()
{
  
  PID_FILE=/var/run/lvmBackups
  MYSQL_DATA_DIR=/var/lib/mysql/data
  BACKUP_MOUNT_POINT=/var/cache/mylvmbackup/mnt/backup
  BACKUP_LOGICAL_VOLUME=/dev/mapper/raid10-mysql_data_snapshot

  isThisScriptRunning 

  echo "**NOTE** this restore script takes a while, and MUST take place inside of a screen session. are you currently inside of one? [y|n]"
  read RESPONSE
  if [ $RESPONSE != "y" ]; then
    exit
  fi 

  isMySqlRunning
  THISHOST=$(hostname)
  BACKUP_HOST=$(getBackupHost $(echo $THISHOST | cut -c 1-5))

  echo "enter date for restore: YYYYMMDD"
  read DATE
  isBackupDirPresent $BACKUP_HOST $DATE

  logIt "removing existing $MYSQL_DATA_DIR in 10s. speak now or forever hold your peace!"
  for i in {1..10}; do 
    echo -n "."
    sleep 1
  done
 
  touch $PID_FILE

  logIt "beginning $MYSQL_DATA_DIR removal."
  rm -rf $MYSQL_DATA_DIR
  if [ $? -ne 0 ]; then
    logIt "$MYSQL_DATA_DIR removal failed. exiting."
    exit
  else
    logIt "$MYSQL_DATA_DIR successfully removed."
  fi
  mkdir -p $MYSQL_DATA_DIR
  if [ $? -ne 0 ]; then
    logIt "recreation of $MYSQL_DATA_DIR failed. exiting."
    exit
  else
    logIt "$MYSQL_DATA_DIR successfully recreated."
  fi

  RESTORE_COMMAND="ssh $BACKUP_HOST 'cd /home/backup/$BACKUP_DIR; tar zcvf - *' | tar zxvf - -C $MYSQL_DATA_DIR"
  logIt "copying things back over via the following tar command:"
  logIt "$RESTORE_COMMAND"

  ($(eval $RESTORE_COMMAND) && logIt "tar from $BACKUP_HOST completed successfully.") || ( logIt "tar from $BACKUP_HOST failed." && exit )

  rm -f $PID_FILE
  logIt "restore complete. start mysql, issue a 'start slave' and take the appropriate steps to get things running again."
  exit
}

if [[ $EUID -ne 0 ]]; then
   echo "ERR: this script must be run as root." 
   exit 
fi

OPTS=$@
case "$OPTS" in
  '-h')
    usage
    ;;
  '-backup')
    doBackup
    ;;
  '-restore')
    doRestore
    ;;
  *)
    usage
    ;;
esac
