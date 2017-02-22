BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
${BASEDIR}/orabackup.sh -d $1 -t l0 -c RMANCAT
