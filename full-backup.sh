#!/bin/bash

# version: 3.2.0

# changelog
# version: 3.2.0
#   - date: 2021-03-27
#   - improve naming scheme.
# changelog
# version: 3.1.1
#   - date: 2020-11-24
#   - improve documentation
# version: 3.1.0
#   - delete old backups in $ENCRYPTED_BACKUP_PATH only if this directory / path exists

# this script is basically
#   files-backup-without-uploads.sh script + part of db-backup.sh script
#   from files-backup-without-uploads.sh script, we do not exclude uploads directory - just removed the line from it

### Variables ###

# a passphrase for encryption, in order to being able to use almost any special characters use ""
PASSPHRASE=

# auto delete older backups after certain number days - default 30. YMMV
AUTODELETEAFTER=30

# the script assumes your sites are stored like ~/sites/example.com, ~/sites/example.net, ~/sites/example.org and so on.
# if you have a different pattern, such as ~/app/example.com, please change the following to fit the server environment!
SITES_PATH=${HOME}/sites

# if WP is in a sub-directory, please leave this empty!
PUBLIC_DIR=public

### Variables
# You may hard-code the domain name and AWS S3 Bucket Name here
DOMAIN=
BUCKET_NAME=

#-------- Do NOT Edit Below This Line --------#

# create log directory if it doesn't exist
[ ! -d ${HOME}/log ] && mkdir ${HOME}/log

LOG_FILE=${HOME}/log/backups.log
exec > >(tee -a ${LOG_FILE} )
exec 2> >(tee -a ${LOG_FILE} >&2)

echo "Script started on... $(date +%c)"

export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/local/sbin

declare -r wp_cli=`which wp`
which aws &> /dev/null && declare -r aws_cli=`which aws`
declare -r timestamp=$(date +%F_%H-%M-%S)
declare -r script_name=$(basename "$0")

let AUTODELETEAFTER--

# check if log directory exists
if [ ! -d "${HOME}/log" ] && [ "$(mkdir -p ${HOME}/log)" ]; then
    echo "Log directory not found. The script can't create it, either!"
    echo "Please create it manually at $HOME/log and then re-run this script"
    exit 1
fi

# source the envrc files if found
[ -f "$HOME/.envrc"  ] && source ~/.envrc
[ -f "$HOME/.env"  ] && source ~/.env

# check for the variable/s in three places
# 1 - hard-coded value
# 2 - optional parameter while invoking the script
# 3 - environment files

if [ "$DOMAIN" == ""  ]; then
    if [ "$1" == "" ]; then
        if [ "$WP_DOMAIN" != "" ]; then
            DOMAIN=$WP_DOMAIN
        else
            echo "Usage $script_name example.com (S3 bucket name)"; exit 1
        fi
    else
        DOMAIN=$1
    fi
fi

if [ "$BUCKET_NAME" == ""  ]; then
    if [ "$2" != "" ]; then
        BUCKET_NAME=$2
    elif [ "$AWS_S3_BUCKET_NAME" != "" ]; then
        BUCKET_NAME=$AWS_S3_BUCKET_NAME
    fi
fi

# path to backup
WP_PATH=${SITES_PATH}/${DOMAIN}/${PUBLIC_DIR}
if [ ! -d "$WP_PATH" ]; then
    echo "$WP_PATH is not found. Please check the paths and adjust the variables in the script. Exiting now..."
    exit 1
fi

# where to store the backup file/s
BACKUP_PATH=${HOME}/backups/full-backups
if [ ! -d "$BACKUP_PATH" ] && [ "$(mkdir -p $BACKUP_PATH)" ]; then
    echo "BACKUP_PATH is not found at $BACKUP_PATH. The script can't create it, either!"
    echo 'You may want to create it manually'
    exit 1
fi
ENCRYPTED_BACKUP_PATH=${HOME}/backups/encrypted-full-backups
if [ -n "$PASSPHRASE" ] && [ ! -d "$ENCRYPTED_BACKUP_PATH" ] && [ "$(mkdir -p $ENCRYPTED_BACKUP_PATH)" ]; then
    echo "ENCRYPTED_BACKUP_PATH is not found at $ENCRYPTED_BACKUP_PATH. The script can't create it, either!"
    echo 'You may want to create it manually'
    exit 1
fi

# path to be excluded from the backup
# no trailing slash, please
EXCLUDE_BASE_PATH=${DOMAIN}
if [ "$PUBLIC_DIR" != "" ]; then
    EXCLUDE_BASE_PATH=${EXCLUDE_BASE_PATH}/${PUBLIC_DIR}
fi

declare -A EXC_PATH
EXC_PATH[1]=${EXCLUDE_BASE_PATH}/wp-content/cache
EXC_PATH[2]=${EXCLUDE_BASE_PATH}/wp-content/debug.log
EXC_PATH[3]=${EXCLUDE_BASE_PATH}/.git
# need more? - just use the above format

EXCLUDES=''
for i in "${!EXC_PATH[@]}" ; do
    CURRENT_EXC_PATH=${EXC_PATH[$i]}
    EXCLUDES=${EXCLUDES}'--exclude='$CURRENT_EXC_PATH' '
    # remember the trailing space; we'll use it later
done

#------------- from db-script.sh --------------#
DB_OUTPUT_FILE_NAME=${SITES_PATH}/${DOMAIN}/db-$timestamp.sql

# take actual DB backup
if [ -f "$wp_cli" ]; then
    $wp_cli --path=${WP_PATH} transient delete --all
    $wp_cli --path=${WP_PATH} db export --add-drop-table $DB_OUTPUT_FILE_NAME
    if [ "$?" != "0" ]; then
        echo; echo 'Something went wrong while taking local backup!'
        # remove the empty backup file
        rm -f $DB_OUTPUT_FILE_NAME &> /dev/null
    fi
else
    echo 'Please install wp-cli and re-run this script'; exit 1;
fi
#------------- end of snippet from db-script.sh --------------#

FULL_BACKUP_FILE_NAME=${BACKUP_PATH}/full-backup-${DOMAIN}-$timestamp.tar.gz

# let's encrypt everything with a passphrase before sending to AWS 
# this is a simple encryption using gpg
ENCRYPTED_FULL_BACKUP_FILE_NAME=${ENCRYPTED_BACKUP_PATH}/full-backup-${DOMAIN}-$timestamp.tar.gz.gpg
LATEST_FULL_BACKUP_FILE_NAME=${BACKUP_PATH}/full-backup-${DOMAIN}-latest.tar.gz

if [ ! -z "$PASSPHRASE" ]; then
    # using symmetric encryption
    # option --batch to avoid passphrase prompt
    # encrypting database dump
    tar hcz -C ${SITES_PATH} ${EXCLUDES} ${DOMAIN} | gpg --symmetric --passphrase $PASSPHRASE --batch -o ${ENCRYPTED_FULL_BACKUP_FILE_NAME}
    if [ "$?" != "0" ]; then
        echo; echo 'Something went wrong while taking *encrypted* full backup'; echo
        echo "Check $LOG_FILE for any log info"; echo
    else
        echo; echo '(Encrypted) Backup is successfully taken locally.'; echo
    fi
    [ -f $LATEST_FULL_BACKUP_FILE_NAME ] && rm $LATEST_FULL_BACKUP_FILE_NAME
    ln -s ${ENCRYPTED_FULL_BACKUP_FILE_NAME} $LATEST_FULL_BACKUP_FILE_NAME
else
    # let's do it using tar
    # Create a fresh backup
    tar hczf ${FULL_BACKUP_FILE_NAME} -C ${SITES_PATH} ${EXCLUDES} ${DOMAIN} &> /dev/null
    if [ "$?" != "0" ]; then
        echo; echo 'Something went wrong while takin full backup'; echo
        echo "Check $LOG_FILE for any log info"; echo
    else
        echo; echo 'Backup is successfully taken locally.'; echo
    fi

    echo "No PASSPHRASE provided!"
    echo "You may want to encrypt your backup before storing them offsite."
    echo "[WARNING]"
    echo "If your data came from Europe, please check GDPR compliance."

    [ -f $LATEST_FULL_BACKUP_FILE_NAME ] && rm $LATEST_FULL_BACKUP_FILE_NAME
    ln -s ${FULL_BACKUP_FILE_NAME} $LATEST_FULL_BACKUP_FILE_NAME
fi

# remove the reduntant DB backup
rm $DB_OUTPUT_FILE_NAME

# send backup to AWS S3 bucket
if [ "$BUCKET_NAME" != "" ]; then
    if [ ! -e "$aws_cli" ] ; then
        echo; echo 'Did you run "pip install aws && aws configure"'; echo;
    fi

    if [ -z "$PASSPHRASE" ]; then
        $aws_cli s3 cp ${FULL_BACKUP_FILE_NAME} s3://$BUCKET_NAME/${DOMAIN}/full-backups/
    else
        $aws_cli s3 cp ${ENCRYPTED_FULL_BACKUP_FILE_NAME} s3://$BUCKET_NAME/${DOMAIN}/encrypted-full-backups/
    fi

    if [ "$?" != "0" ]; then
        echo; echo 'Something went wrong while taking offsite backup.'; echo
        echo "Check $LOG_FILE for any log info"; echo
    else
        echo; echo 'Offsite backup successful.'; echo
    fi
fi

# Auto delete backups 
find $BACKUP_PATH -type f -mtime +$AUTODELETEAFTER -exec rm {} \;
[ -d $ENCRYPTED_BACKUP_PATH ] && find $ENCRYPTED_BACKUP_PATH -type f -mtime +$AUTODELETEAFTER -exec rm {} \;

if [ -z "$PASSPHRASE" ]; then
    echo 'Full backup is done; please check the latest backup in '${BACKUP_PATH}'.';
    echo "Latest backup is at ${FULL_BACKUP_FILE_NAME}"
else
    echo 'Full backup is done; please check the latest backup in '${ENCRYPTED_BACKUP_PATH}'.';
    echo "Latest backup is at ${ENCRYPTED_FULL_BACKUP_FILE_NAME}"
fi

echo "Script ended on... $(date +%c)"
echo
