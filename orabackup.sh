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
#                              | Moved channel allocation parameter to config file
#                              | Removed spfile and controlfile explicit backup and configured autobackup
#                              | Implemented retry of archivelog backup 
#                              | Added tmp and log cleanup function
#                              | Added force option to ignore running backups
#                              | Catalog operation are now evaluated
#  1.2.1 | 20170227| J.SARAIVA | Fixed bug on log validation
#                              | Modified the rerun backup log to have a .2
#  1.2.2 | 20170301| J.SARAIVA | Added feature to send email with log when error occurs
#  1.2.3 | 20170327| J.SARAIVA | Changed backup validation to consider only if error message stack exists
#######################################################################################################

SOURCE="${BASH_SOURCE[0]}" #JPS# the script is sourced so this have to be used instead of $0 below
PROGNAME=`basename ${SOURCE}` 
FILENAME="${PROGNAME%.*}"
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ABSOLUTE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

REVISION="1.2.3"
LASTUPDATE="2017-03-27"
DATA=`date "+%Y%m%d_%H%M%S"`

DEBUG=0

#constants
RMANARC="BACKUP ARCHIVELOG ALL FILESPERSET 10 FORMAT 'arch_%d_%T_%U' TAG 'archivelog' DELETE ALL INPUT;"
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
        -o [CHNNLDEF] # Overrides default channel allocation
        -f            # Forces execution ignoring runnning backups
  --cleanup           # Removes log and tmp files older than 30 days
  --help              # Displays the help menu
  --version           # Shows version information
HEREDOC
}

print_help() {
  print_revision
cat <<HEREDOC

  Executes backup on Oracle databases using:
	HP DataProtectorâ„¢

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

exec_catalog() {
CATALOG=${_CATALOG}
#check db conectivity
CTLG_DB=`grep -i ${CATALOG} ${BASEDIR}/orabackup.cfg | awk -F"|" '{print $1}'`
CTLG_USER=`grep -i ${CATALOG} ${BASEDIR}/orabackup.cfg | awk -F"|" '{print $2}'`
CTLG_PASS=`grep -i ${CATALOG} ${BASEDIR}/orabackup.cfg | awk -F"|" '{print $3}'`
CTLG_TNS=`grep -i ${CATALOG} ${BASEDIR}/tnsnames.ora | cut -d= -f2-`

if [[ -z ${CTLG_DB} ]]; then
  log "ERR : Unable to find catalog database in configuration file"
  exit 2
fi

if [[ -z ${CTLG_TNS} ]]; then
 log "ERR : Unable to find catalog in tnsnames.ora"
 exit 2
fi

RMANCONNECT="${CTLG_USER}/${CTLG_PASS}@\"${CTLG_TNS}\""

DBID=`sqlplus -L -s ${DBCONNECT} <<!
set pages 0 feed off head off verify off lines 128 echo off term off
select trim(dbid) from v\\$database;
exit;
!
`

if [[ ${DBID} == *"ORA-"* ]]; then
  log "ERR : Error obtaining dbid on target database"
  exit 2
fi

RMANREG=`sqlplus -L -s ${RMANCONNECT} <<!
set pages 0 feed off head off verify off lines 128 echo off term off
select count(1) from rc_database where dbid=${DBID};
exit;
!
`

if [[ ${DBID} == *"ORA-"* ]]; then
  log "ERR : Error connecting to catalog database"
  exit 2
fi

CATLOG=${BASEDIR}/log/catalog_${DATABASE}_${BACKUP_TYPE}_${DATA}.log

if [[ "${RMANREG}" -eq 0 ]]; then
  log "INF : Database not registered on catalog ${CATALOG}"
  log "INF : Registering and resyncing"
  rman target ${DBCONNECT} catalog ${RMANCONNECT} log=${CATLOG} 2>&1 >>/dev/null <<!
  register database;
  resync catalog;
  exit;
!
else
  log "INF : Database registered on catalog ${CATALOG}"
  log "INF : Resyncing"
  rman target ${DBCONNECT} catalog ${RMANCONNECT} log=${CATLOG} 2>&1 >>/dev/null <<!
  resync catalog;
  exit;
!
fi
  
 validate_catalog
 if [[ $? -ne 0 ]]; then
   exit 2
 fi
}

run_backup() {
 debug "rman cmdfile=${CMDFILE} log=${RMANLOG}"
 log "INF : Starting backup ${BACKUP_TYPE} on ${DATABASE}"
 log "INF : rman log at ${RMANLOG}"
 rman cmdfile=${CMDFILE} log=${RMANLOG} 2>&1 >>/dev/null 
}

validate_catalog() {
 ERRCOUNT=`egrep "ORA-|RMAN-" ${CATLOG} | wc -l`
 if [[ ERRCOUNT -gt 0 ]]; then
  log "ERR: Catalog operations failed with ${ERRCOUNT} error(s)"
  return 2 #will allow for a rerun
 else
  log "INF : Catalog operations  successfuly"
 fi
}

validate_backup() {
 ERRCOUNT=`egrep "ERROR MESSAGE STACK FOLLOWS" ${RMANLOG} | wc -l`
 if [[ ERRCOUNT -gt 0 ]]; then
  ERRORS=`sed -n "/RMAN-00571/,/Recovery Manager complete./p" ${RMANLOG}`
  log "ERR: Backup failed with errors:"
  log "${ERRORS}"
  if [[ ! -z ${EMAILIST} ]]; then #send email with errors if email is defined
	echo "$ERRORS" | mailx -s "Backup ${BACKUP_TYPE}@${DATABASE} ended with error" -a ${RMANLOG} ${EMAILIST} 2>/dev/null 
  fi
  return 2 #will allow for a rerun
 else
  log "INF : Backup completed successfuly"
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
      BACKUP_TYPE=arc
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
    
  #prepare backup 
  RMANLOG=${BASEDIR}/log/rman_${DATABASE}_${BACKUP_TYPE}_${DATA}.log
  CMDFILE=${BASEDIR}/tmp/${DATABASE}_${BACKUP_TYPE}_${DATA}.cmd
  touch ${CMDFILE}
  echo "connect target ${DBCONNECT}" >> ${CMDFILE}
  echo ${CONF_RMAN_RETENTION} >> ${CMDFILE}
  echo ${CONF_RMAN_CTL_AUTOBCK_ON} >> ${CMDFILE}
  echo "run {" >> ${CMDFILE}
  
  #configure channels
  RMAN_CH=`grep -i ${CHNNLDEF} ${BASEDIR}/orachannel.cfg | awk -F"|" '{print $2}'`
  for (( c=1; c<=${CHNNLNUM}; c++ ))
   do
   CHNUMBER=${c}
   echo "$RMAN_CH" | sed -e 's/_CHNUMBER/'"${CHNUMBER}"'/g' -e 's/_DATABASE/'"${DATABASE}"'/g' >> ${CMDFILE}
  done;
  
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
    if [[ ${FORCERUN} -eq 1 ]]; then
      log "INF: backup still running but forcing execution"
    else
      log "ERR: there is a backup session still running"
      exit 1
    fi
  fi
  
  #run backup
  run_backup
  #validate execution
  validate_backup
  
  #retry failed arc
  if [[ ( $? -eq 2 ) ]]; then # if backup failed
    if [[ ${BACKUP_TYPE} = 'arc' ]]; then  # and it is arc, retry
      log "INF : Retrying"
	  RMANLOG=${BASEDIR}/log/rman_${DATABASE}_${BACKUP_TYPE}_${DATA}.2.log # use new log
      run_backup
      validate_backup
      if [[ ( $? -eq 2 ) ]]; then            # if still fail after retrial, error; if not continue
        log "ERR : Backup failed after retrial"
        exit 2
      fi
    else                                     # if it is not arch, fail immediately
      exit 2
    fi    
  fi    
}

cleanup() {
 # remove log and tmp files older than 30 days silently
 find ${BASEDIR}/tmp -name "*.cmd" -mtime +30 -exec rm {} \;
 find ${BASEDIR}/log -name "*.log" -mtime +30 -exec rm {} \;
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
   -f)
    _FORCE=1
    ;;
   -o)
    _notdone=$2
    shift
    ;;
   --help|-h)
      print_help
      ;;
   --version|-V|-v)
      print_revision 
      ;;
   --cleanup)
      _CLEANUP=1 
      ;;
    *) 
      print_help
      exit
      ;;
	esac
  shift
done

# validation
if [[ ${_CLEANUP} -eq 1 ]]; then
  cleanup
fi

if [[ -z ${_DBNAME} ]]; then
  print_help
  exit
else
  DB=${_DBNAME}
fi

if [[ ${_FORCE} -eq 1 ]]; then
  FORCERUN=1
fi

if [ ! -d ${BASEDIR}/tmp ]; then
 mkdir ${BASEDIR}/tmp 
fi

if [ ! -d ${BASEDIR}/log ]; then
 mkdir ${BASEDIR}/log
fi

#set permissions
chmod 745 ${BASEDIR}/*.sh
chmod 744 ${BASEDIR}/tnsnames.ora

# Start doing stuff
LOGFILE=${BASEDIR}/log/exec_${DB}_${DATA}.log
log "INIT: ${ABSOLUTE_PATH} ${_PARAMS}"
log "INF : Execution log at ${LOGFILE}"

#check db conectivity
DATABASE=`grep -i ${DB} ${BASEDIR}/orabackup.cfg | awk -F"|" '{print $1}'`
USERNAME=`grep -i ${DB} ${BASEDIR}/orabackup.cfg | awk -F"|" '{print $2}'`
PASSWORD=`grep -i ${DB} ${BASEDIR}/orabackup.cfg | awk -F"|" '{print $3}'`
RTENTION=`grep -i ${DB} ${BASEDIR}/orabackup.cfg | awk -F"|" '{print $4}'`
CHNNLDEF=`grep -i ${DB} ${BASEDIR}/orabackup.cfg | awk -F"|" '{print $5}'`
CHNNLNUM=`grep -i ${DB} ${BASEDIR}/orabackup.cfg | awk -F"|" '{print $6}'`
EMAILIST=`grep -i ${DB} ${BASEDIR}/orabackup.cfg | awk -F"|" '{print $7}'`
TNSNAMES=`grep -i ${DB} ${BASEDIR}/tnsnames.ora | cut -d= -f2-`

if [[ -z ${USERNAME} || -z ${PASSWORD} || -z ${RTENTION} || -z ${CHNNLDEF} || -z ${CHNNLNUM} || -z ${TNSNAMES} ]]; then
 log "ERR: unable to get proper configuration for database ${DB}"
 exit 2
fi

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