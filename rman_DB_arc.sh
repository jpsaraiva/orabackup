BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
${BASEDIR}/orabackup.sh -d $1 -t arc -c RMANCAT
