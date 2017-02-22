#!/bin/bash
#######################################################################################################
#  NAME               : orabackup.sh
#  Summary            : Runs the backup locally by connecting via SSH to the instance host
#  Created by         : jpsaraiva
#  Usage              : orabackup.sh -h	 ..............    # Displays the help menu
#  Exit Codes         : 0 OK; 1 Recoverable error; 2 User intervention required
#--------------------------------------------------------------------------
#
#--------------------------------------------------------------------------
# Revision History
#
#Revision|Date_____|By_________|_Object______________________________________
#  1.0   |         | J.SARAIVA | Creation
#  1.1   | 20170126| J.SARAIVA | Added tee to execution log
#  1.2   | 20170222| J.SARAIVA | Removed TNS from orabackup.cfg, get it from tnsnames.ora
#							   | Moved channel allocation parameter to config file
#							   | Removed spfile and controlfile explicit backup and configured autobackup
#							   | Implemented retry of archivelog backup 
#							   | Added tmp and log cleanup function
#######################################################################################################

SOURCE="${BASH_SOURCE[0]}" #JPS# the script is sourced so this have to be used instead of $0 below
PROGNAME=`basename ${SOURCE}` 
FILENAME="${PROGNAME%.*}"
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ABSOLUTE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

REVISION="1.1"
LASTUPDATE="2017-02-22"
DATA=`date "+%Y%m%d_%H%M%S"`

DEBUG=0

#constants
RMANARC="BACKUP ARCHIVELOG ALL FILESPERSET 10 FORMAT 'ARCH_%d_%T_%U' TAG 'ARCHIVELOG' DELETE ALL INPUT;"
RMANL0="BACKUP INCREMENTAL LEVEL 0 FILESPERSET 10 FORMAT 'l0inc_%d_%T_%U' TAG 'l0inc' DATABASE;"
RMANL1="BACKUP INCREMENTAL LEVEL 1 FILESPERSET 10 FORMAT 'l1inc_%d_%T_%U' TAG 'l1inc' DATABASE;"
RMANSPF="BACKUP SPFILE FORMAT 'spf_%d_%T_%U' TAG 'spfile';"
RMANCTL="BACKUP CURRENT CONTROLFILE FORMAT 'ctl_%d_%T_%U' TAG 'controlfile';"

print_revision() {
	echo "${PROGNAME}: v${REVISION} (${LASTUPDATE})"
}

print_usage() {
cat <<HEREDOC
Usage:
 orabackup.sh         # Displays the help menu
 Parameters:          #
        -d [DB_NAME]  # Runs the backup for the specified database
        -t [BCK_TYPE] #  l0, l1 , arc
        -c [CATALOG]  #  Resyncs with specified catalog
HEREDOC
}

print_help() {
  print_revision
cat <<HEREDOC

  Executes backup on MMK databases using HP DataProtectorâ„¢

HEREDOC
  print_usage
}

debug() {
  if [[ ${DEBUG} -eq 1 ]]; then
    log $1
  fi  
}

log() {
  echo `date "+%Y-%m-%d %H:%M:%S"`" $1" | tee -a $LOGFILE
}


construct_channels() {
RMAN_CH=`grep -i ${CHNNLDEF} ${BASEDIR}/orachannel.cfg | awk -F"|" '{print $2}'`
for i in {1..${CHNNLNUM}};
do 
CHNUMBER=${i}
echo ${RMAN_CH}
done;
}

#todo: action not being validated
exec_catalog() {
CATALOG=${_CATALOG}
#check db conectivity
CTLG_DB=`grep -i ${CATALOG} ${BASEDIR}/${FILENAME}.cfg | awk -F"|" '{print $1}'`
CTLG_USER=`grep -i ${CATALOG} ${BASEDIR}/${FILENAME}.cfg | awk -F"|" '{print $2}'`
CTLG_PASS=`grep -i ${CATALOG} ${BASEDIR}/${FILENAME}.cfg | awk -F"|" '{print $3}'`
CTLG_PASS=`grep -i ${CATALOG} ${BASEDIR}/${FILENAME}.cfg | awk -F"|" '{print $3}'`
CTLG_TNS=`grep -i ${CATALOG} ${BASEDIR}/tnsnames.ora | cut -d= -f2-`

RMANCONNECT="${CTLG_USER}/${CTLG_PASS}@\"${CTLG_TNS}\""

DBID=`sqlplus -L -s ${DBCONNECT} <<!
set pages 0 feed off head off verify off lines 128 echo off term off
select trim(dbid) from v\\$database;
exit;
!
`
RMANREG=`sqlplus -L -s ${RMANCONNECT} <<!
set pages 0 feed off head off verify off lines 128 echo off term off
select count(1) from rc_database where dbid=${DBID};
exit;
!
`
if [[ "${RMANREG}" -eq 0 ]]; then
  log "INF : Database not registered on catalog ${CATALOG}"
  log "INF : Register in progress ..."
  rman target ${DBCONNECT} catalog ${RMANCONNECT} 2>&1 >>/dev/null <<!
  register database;
  exit;
!
  log "INF : Registration completed"
else
  log "INF : Database registered on catalog ${CATALOG}"
  log "INF : Resync in progress ..."
  rman target ${DBCONNECT} catalog ${RMANCONNECT} 2>&1 >>/dev/null <<!
  resync catalog;
  exit;
!
  log "INF : Resync completed"
fi
}

exec_backup() {
  BACKUP_TYPE=${_BKTYPE}
  case ${BACKUP_TYPE} in
    l0) 
      RMANOP=`printf "%s\n%s\n%s\n%s\n%s\n" "${RMANARC}" "${RMANL0}" "${RMANARC}"`
      ;;
    l1)
      RMANOP=`printf "%s\n%s\n%s\n%s\n%s\n" "${RMANARC}" "${RMANL1}" "${RMANARC}"`
      ;;
    arc|arch)
      RMANOP=`printf "%s\n%s\n%s\n" "${RMANARC}"`
      ;;
    *) 
      print_help
      return
      ;;
  esac
  
  #variables
  DBCONNECT="${USERNAME}/${PASSWORD}@\"${TNSNAMES}\""
  CONF_RMAN_RETENTION="CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${RTENTION} DAYS;"
  CONF_RMAN_CTL_AUTOBCK_ON="CONFIGURE CONTROLFILE AUTOBACKUP ON;"
  
  #configure channels
  RMANCHANNELS
  
  #RMANCH0="allocate channel 'ch0' type 'sbt_tape' parms 'SBT_LIBRARY=/opt/omni/lib/libob2oracle8_64bit.so,ENV=(OB2BARTYPE=Oracle8,OB2APPNAME=${DATABASE},OB2BARLIST=H_FULL_ORA_RACPRD05_${DATABASE})';"
  #RMANCH1="allocate channel 'ch1' type 'sbt_tape' parms 'SBT_LIBRARY=/opt/omni/lib/libob2oracle8_64bit.so,ENV=(OB2BARTYPE=Oracle8,OB2APPNAME=${DATABASE},OB2BARLIST=H_FULL_ORA_RACPRD05_${DATABASE})';"
  #RMANCH2="allocate channel 'ch2' type 'sbt_tape' parms 'SBT_LIBRARY=/opt/omni/lib/libob2oracle8_64bit.so,ENV=(OB2BARTYPE=Oracle8,OB2APPNAME=${DATABASE},OB2BARLIST=H_FULL_ORA_RACPRD05_${DATABASE})';"
  #RMANCH3="allocate channel 'ch3' type 'sbt_tape' parms 'SBT_LIBRARY=/opt/omni/lib/libob2oracle8_64bit.so,ENV=(OB2BARTYPE=Oracle8,OB2APPNAME=${DATABASE},OB2BARLIST=H_FULL_ORA_RACPRD05_${DATABASE})';"
  
  #prepare backup 
  RMANLOG=${BASEDIR}/log/rman_${DATABASE}_${BACKUP_TYPE}_${DATA}.log
  CMDFILE=${BASEDIR}/tmp/${DATABASE}_${BACKUP_TYPE}_${DATA}.cmd
  touch ${CMDFILE}
  echo "connect target ${DBCONNECT}" >> ${CMDFILE}
  echo ${CONF_RMAN_RETENTION} >> ${CMDFILE}
  echo ${CONF_RMAN_CTL_AUTOBCK_ON} >> ${CMDFILE}
  echo "run {" >> ${CMDFILE}
  echo ${RMANCH0} >> ${CMDFILE}
  echo ${RMANCH1} >> ${CMDFILE}
  echo ${RMANCH2} >> ${CMDFILE}
  echo ${RMANCH3} >> ${CMDFILE}
  echo "${RMANOP}" >> ${CMDFILE}
  echo "}" >> ${CMDFILE}

  #single execution?
  STILRUN=`sqlplus -L -s ${DBCONNECT} <<!
  set pages 0 feed off head off verify off lines 128 echo off term off
  select count(1) from v\\\$rman_backup_job_details where status='RUNNING';
  exit;
!
`
  if [[ "${STILRUN}" -gt  0 ]]; then
    log "ERR: there is a backup session still running"
    exit 1
  fi

  #run backup
  debug "rman cmdfile=${CMDFILE} log=${RMANLOG}"
  log "INF : Starting backup ${BACKUP_TYPE} on ${DATABASE}"
  log "INF : rman log at ${RMANLOG}"
  rman cmdfile=${CMDFILE} log=${RMANLOG} 2>&1 >>/dev/null 
  #validate execution
    #exclude from validation:
    # RMAN-08120: WARNING: archived log not deleted, not yet applied by standby
  ERRCOUNT=`egrep "ORA-|RMAN-" ${RMANLOG} | egrep -v "RMAN-08120" | wc -l`
  if [[ ERRCOUNT -gt 0 ]]; then
   log "ERR: Backup failed with ${ERRORCOUNT} error(s)"
   exit 2
  else
   log "INF : Backup completed successfuly"
  fi
}

#main(int argc, char *argv[]) #JPS# Start here
_PARAMS=$@
while test -n "$1"; do
	case $1 in
   -d|-db|-database)
    _DBNAME=$2
	  shift
    ;;
   -t|-type)
    _BKTYPE=$2
    shift
    ;;
   -c|-catalog)
    _CATALOG=$2
    shift
    ;;
   --help|-h)
      print_help
      ;;
   --version|-V|-v)
      print_revision 
      ;;
    *) 
      print_help
      exit
      ;;
	esac
  shift
done

# validation
if [[ -z ${_DBNAME} ]]; then
  print_help
  exit
else
  DB=${_DBNAME}
fi

LOGFILE=${BASEDIR}/log/exec_${DB}_${DATA}.log
log "INIT: ${ABSOLUTE_PATH} ${_PARAMS}"
log "INF : Execution log at ${LOGFILE}"

#check db conectivity
DATABASE=`grep -i ${DB} ${BASEDIR}/${FILENAME}.cfg | awk -F"|" '{print $1}'`
USERNAME=`grep -i ${DB} ${BASEDIR}/${FILENAME}.cfg | awk -F"|" '{print $2}'`
PASSWORD=`grep -i ${DB} ${BASEDIR}/${FILENAME}.cfg | awk -F"|" '{print $3}'`
RTENTION=`grep -i ${DB} ${BASEDIR}/${FILENAME}.cfg | awk -F"|" '{print $4}'`
CHNNLDEF=`grep -i ${DB} ${BASEDIR}/${FILENAME}.cfg | awk -F"|" '{print $5}'`
CHNNLNUM=`grep -i ${DB} ${BASEDIR}/${FILENAME}.cfg | awk -F"|" '{print $6}'`
TNSNAMES=`grep -i ${DB} ${BASEDIR}/tnsnames.ora | cut -d= -f2-`

SQLTEST=`sqlplus -v 2>/dev/null`
if [[ -z $SQLTEST ]]; then
  log "ERR: sqlplus not found"
  exit 2
fi

export NLS_DATE_FORMAT='DD-MM-YYYY HH24:MI:SS'

if [[ ! -z ${_BKTYPE} ]]; then
  exec_backup
fi

#_CATALOG="RMANCAT" # remove this to make it optional
if [[ ! -z ${_CATALOG} ]]; then
    exec_catalog
fi
