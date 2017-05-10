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
#                              | Implemented retry of archivelog backup 
#                              | Added tmp and log cleanup function
#                              | Added force option to ignore running backups
#                              | Catalog operation are now evaluated
#  1.2.1 | 20170227| J.SARAIVA | Fixed bug on log validation
#                              | Modified the rerun backup log to have a .2
#  1.2.2 | 20170301| J.SARAIVA | Added feature to send email with log when error occurs
#  1.2.3 | 20170508| J.SARAIVA | Added validation to check if there are stuck sessions and kill them
#                              | Minor modification on how the backup retry is called
#                              | L1 added to retrial procedure, L0 still excluded
#                              | Added release channel procedure to backup operation
#  1.3   | 20170510| J.SARAIVA | Removed manual channel allocation, script will use database default configuration
#                              | Removed -o option to "Overrides default channel allocation"
#                              | Removed orachannel.cfg file
#                              | Added crosscheck and delete expired to catalog operations
#                              | Added -u option to create an unique execution
#                              | Added --block   to prevent further backups from a database
#                              | Added --unblock to remove backup restriction from a database
#######################################################################################################

SOURCE="${BASH_SOURCE[0]}" #JPS# the script is sourced so this have to be used instead of $0 below
PROGNAME=`basename ${SOURCE}` 
FILENAME="${PROGNAME%.*}"
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ABSOLUTE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

REVISION="1.2.3"
LASTUPDATE="2017-05-08"
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
		    -u            # Forces unique execution, no other sessions allowed
        -f            # Forces execution ignoring runnning backups
  --block             # Blocks further backups of the specified database
  --unblock           # Removes restriction on backups of specified database
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

 CATCONNECT="${CTLG_USER}/${CTLG_PASS}@\"${CTLG_TNS}\""

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

 RMANREG=`sqlplus -L -s ${CATCONNECT} <<!
set pages 0 feed off head off verify off lines 128 echo off term off
select count(1) from rc_database where dbid=${DBID};
exit;
!
`

 if [[ ${DBID} == *"ORA-"* ]]; then
  log "ERR : Error connecting to catalog database"
  exit 2
 fi

 #prepare backup 
 CATLOG=${BASEDIR}/log/catalog_${DATABASE}_${BACKUP_TYPE}_${DATA}.log
 CMDFILE=${BASEDIR}/tmp/catalog_${DATABASE}_${BACKUP_TYPE}_${DATA}.cmd
 
 touch ${CMDFILE}
 echo "connect target ${DBCONNECT}" >> ${CMDFILE}
 echo "connect catalog ${CATCONNECT}" >> ${CMDFILE}
 echo "run {" >> ${CMDFILE}

 #register database is not registered 
 if [[ "${RMANREG}" -eq 0 ]]; then
  log "INF : Database not registered on catalog ${CATALOG} - registering ..."
  echo "register database;" >> ${CMDFILE}
 else
  log "INF : Database registered on catalog ${CATALOG}"
 fi
 #resync catalog
 echo "resync catalog;" >> ${CMDFILE}  
 #crosscheck - mark as expired
 echo "crosscheck backup;" >> ${CMDFILE}  
 #delete expired backup pieces
 echo "delete noprompt expired backup;" >> ${CMDFILE}
 echo "}" >> ${CMDFILE}
 
 debug "rman cmdfile=${CMDFILE} log=${CATLOG}"
 log "INF : Starting catalog ${CATALOG} operations"
 log "INF : rman log at ${CATLOG}"
 rman cmdfile=${CMDFILE} log=${CATLOG} 2>&1 >>/dev/null  
  
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
  log "ERR : Catalog operations failed with ${ERRCOUNT} error(s)"
  return 2 #will allow for a rerun
 else
  log "INF : Catalog operations successfuly"
 fi
}

validate_backup() {
 #exclude from validation:
  # RMAN-08120: WARNING: archived log not deleted, not yet applied by standby
 ERRCOUNT=`egrep "ORA-|RMAN-" ${RMANLOG} | egrep -v "RMAN-08120" | wc -l`
 if [[ ERRCOUNT -gt 0 ]]; then
  log "ERR : Backup failed with ${ERRCOUNT} error(s)"
  if [[ ! -z ${EMAILIST} ]]; then #send email with errors if email is defined
	ERRORS=`sed -n "/RMAN-00571/,/Recovery Manager complete./p" ${RMANLOG}`
	echo "$ERRORS" | mailx -s "Backup ${BACKUP_TYPE}@${DATABASE} ended with error" -a ${RMANLOG} ${EMAILIST} 2>/dev/null 
  fi
  return 2 #will allow for a rerun
 else
  log "INF : Backup completed successfuly"
 fi
}

check_stuck() {
 RUNCOUNT=`sqlplus -L -s ${DBCONNECT} <<!
set pages 0 feed off head off verify off lines 128 echo off term off
select count(*) from gv\\$session where module like '%rman@%' and not exists (select count(1) from v\\$rman_status where status like '%RUNNING%');
exit;
!
`
 return ${RUNCOUNT}
}

validate_stuck() {
# checks if stuck sessions exist on the database
# stuck sessions may prevent further backups from completing sucessfully
 check_stuck 
 if [[ $? -gt 0 ]]; then
  log "INF : There are ${RUNCOUNT} rman sessions stuck on the database"
  KILLLOG=`sqlplus -L -s ${DBCONNECT} <<!
set pages 0 feed off head off verify off lines 128 echo off term off
begin
 for sess in ( select sid || ',' || serial# || ',@' || inst_id || '' sse from gv\\$session where module like '%rman@%' and not exists (select count(1) from v\\$rman_status where status like '%RUNNING%') )
 loop
    execute immediate  'alter system kill session ''' || sess.sse || ''' immediate';
 end loop;
end;
/
exit;
!
` 
  log "INF : ${RUNCOUNT} sessions killed"
 fi
}

validate_running() {
 #single execution?
 STILRUN=`sqlplus -L -s ${DBCONNECT} <<!
set pages 0 feed off head off verify off lines 128 echo off term off
select count(1) from v\\\$rman_backup_job_details where status='RUNNING';
exit;
!
`
 return ${STILRUN}
}

exec_backup_stage() {
 #identify stuck sessions and kill them
 validate_stuck
 #run backup
 run_backup
 #validate execution
 validate_backup
 return $?
}

exec_backup() {
  BACKUP_TYPE=${_BKTYPE}
  case ${BACKUP_TYPE} in
    l0) 
      RMANOP=`printf "%s\n%s\n%s\n%s\n%s\n" "${RMANARC}" "${RMANL0}" "${RMANSPF}" "${RMANCTL}" "${RMANARC}"`
      ;;
    l1)
      RMANOP=`printf "%s\n%s\n%s\n%s\n%s\n" "${RMANARC}" "${RMANL1}"  "${RMANSPF}" "${RMANCTL}" "${RMANARC}"`
      ;;
    arc|arch)
      BACKUP_TYPE=arc
      RMANOP=`printf "%s\n%s\n%s\n" "${RMANARC}"  "${RMANSPF}" "${RMANCTL}"`
      ;;
    *) 
      print_help
      return
      ;;
  esac
  
  #prepare backup 
  RMANLOG=${BASEDIR}/log/rman_${DATABASE}_${BACKUP_TYPE}_${DATA}.1.log
  CMDFILE=${BASEDIR}/tmp/bck_${DATABASE}_${BACKUP_TYPE}_${DATA}.cmd
  touch ${CMDFILE}
  echo "connect target ${DBCONNECT}" >> ${CMDFILE}
  echo "run {" >> ${CMDFILE}
  echo "${RMANOP}" >> ${CMDFILE}
  echo "}" >> ${CMDFILE}
  
  #run the backup 
  exec_backup_stage
  #retry failed arc
  if [[ ( $? -eq 2 ) ]]; then # if backup failed
    if [[ ${BACKUP_TYPE} = 'arc' || ${BACKUP_TYPE} = 'l1' ]]; then  # and it is arc or l1, retry
      log "INF : Retrying"
	  RMANLOG=${BASEDIR}/log/rman_${DATABASE}_${BACKUP_TYPE}_${DATA}.2.log # use new log
      exec_backup_stage
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

validate_unique() {
 UNIQFLAG=${BASEDIR}/tmp/uniq_${DATABASE}.flag
 if [[ ! -f ${UNIQFLAG} ]]; then
  return 0 # file does not exist
 else 
  return 1
 fi
}

set_unique() {
 UNIQFLAG=${BASEDIR}/tmp/uniq_${DATABASE}.flag
 touch ${UNIQFLAG}
 log "INF : Set backup restriction"
}

remove_unique() {
 UNIQFLAG=${BASEDIR}/tmp/uniq_${DATABASE}.flag
 if [[ -f ${UNIQFLAG} ]]; then
  rm ${UNIQFLAG}
 fi
 log "INF : Removed backup restriction"
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
   -f|-F)
    _FORCE=1
    ;;
   -u|-U)
    _UNIQUE=1    
    ;;
   --BLOCK|--block)
	  _BLOCK=1
	  ;;
   --UNBLOCK|--unblock)
    _UNBLOCK=1
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

if [[ ${_UNIQUE} -eq 1 ]]; then
  UNIQRUN=1
fi

if [[ ${_BLOCK} -eq 1 ]]; then
  BLOCK=1
fi

if [[ ${_UNBLOCK} -eq 1 ]]; then
  UNBLOCK=1
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
 log "ERR : unable to get proper configuration for database ${DB}"
 exit 2
fi
DBCONNECT="${USERNAME}/${PASSWORD}@\"${TNSNAMES}\""

SQLTEST=`sqlplus -v 2>/dev/null`
if [[ -z $SQLTEST ]]; then
 log "ERR : sqlplus not found"
 exit 2
fi

#set / removes flag to prevent other executions
if [[ ${BLOCK} -eq 1 ]]; then
 set_unique
 exit 0
fi
if [[ ${UNBLOCK} -eq 1 ]]; then 
 remove_unique
 exit 0
fi

export NLS_DATE_FORMAT='DD-MM-YYYY HH24:MI:SS'

#validate unique
validate_unique #checks if uniq flag already exists
if [[ $? -gt 0 ]]; then
 log "INF : Restricted backup for this database no sessions allowed!"
 log "INF :  to remove restriction run: orabackup.sh -d <database> --unblock"
 exit 0 # returns OK to batch job!!!
else
 if [[ ${UNIQRUN} -eq 1 ]]; then
  log "INF : This session will run in unique mode, no other sessions allowed!"
  set_unique #creates uniq flag for the current database
 fi
fi
 
#validate running
validate_running #checks if there are running rman on the database
if [[ $? -gt  0 ]]; then
 if [[ ${FORCERUN} -eq 1 ]]; then
  log "INF : backup still running but forcing execution"
 else
  log "ERR : there is a backup session still running"
  exit 1
 fi
fi

if [[ ! -z ${_BKTYPE} ]]; then
 exec_backup
fi

#_CATALOG="RMANCAT" # remove this to make it optional
if [[ ! -z ${_CATALOG} ]]; then
 exec_catalog
fi

#remove unique
if [[ ${UNIQRUN} -eq 1 ]]; then
 remove_unique #removes the uniq flag from the current database
fi
