#!/bin/bash -e
set -o pipefail

# set -x (bash debug) if log level is trace
# https://github.com/osixia/docker-light-baseimage/blob/stable/image/tool/log-helper
log-helper level eq trace && set -x

# Reduce maximum number of number of open file descriptors to 1024
# otherwise slapd consumes two orders of magnitude more of RAM
# see https://github.com/docker/docker/issues/8231
ulimit -n 1024

# create dir if they not already exists
[ -d /var/lib/ldap ] || mkdir -p /var/lib/ldap
[ -d /etc/ldap/slapd.d ] || mkdir -p /etc/ldap/slapd.d

# fix file permissions
chown -R openldap:openldap /var/lib/ldap
chown -R openldap:openldap /etc/ldap
chown -R openldap:openldap ${CONTAINER_SERVICE_DIR}/slapd

FIRST_START_DONE="${CONTAINER_STATE_DIR}/slapd-first-start-done"
WAS_STARTED_WITH_TLS="/etc/ldap/slapd.d/docker-openldap-was-started-with-tls"
WAS_STARTED_WITH_TLS_ENFORCE="/etc/ldap/slapd.d/docker-openldap-was-started-with-tls-enforce"
WAS_STARTED_WITH_REPLICATION="/etc/ldap/slapd.d/docker-openldap-was-started-with-replication"

LDAP_TLS_CA_CRT_PATH="${CONTAINER_SERVICE_DIR}/slapd/assets/certs/$LDAP_TLS_CA_CRT_FILENAME"
LDAP_TLS_CRT_PATH="${CONTAINER_SERVICE_DIR}/slapd/assets/certs/$LDAP_TLS_CRT_FILENAME"
LDAP_TLS_KEY_PATH="${CONTAINER_SERVICE_DIR}/slapd/assets/certs/$LDAP_TLS_KEY_FILENAME"
LDAP_TLS_DH_PARAM_PATH="${CONTAINER_SERVICE_DIR}/slapd/assets/certs/dhparam.pem"


# CONTAINER_SERVICE_DIR and CONTAINER_STATE_DIR variables are set by
# the baseimage run tool more info : https://github.com/osixia/docker-light-baseimage

# container first start
if [ ! -e "$FIRST_START_DONE" ]; then

  #
  # Helpers
  #
  function get_ldap_base_dn() {
    # if LDAP_BASE_DN is empty set value from LDAP_DOMAIN
    if [ -z "$LDAP_BASE_DN" ]; then
      IFS='.' read -ra LDAP_BASE_DN_TABLE <<< "$LDAP_DOMAIN"
      for i in "${LDAP_BASE_DN_TABLE[@]}"; do
        EXT="dc=$i,"
        LDAP_BASE_DN=$LDAP_BASE_DN$EXT
      done

      LDAP_BASE_DN=${LDAP_BASE_DN::-1}
    fi

  }

  function get_samba_domain() {
    if [ -z "$SAMBA_DOMAIN" ]; then
      IFS='.' read -ra SAMBA_DOMAIN_TABLE <<< "$LDAP_DOMAIN"
      SAMBA_DOMAIN=$(echo ${SAMBA_DOMAIN_TABLE[0]} | awk '{print toupper($0)}')
    fi
  }

  function is_new_schema() {
    local COUNT=$(ldapsearch -Q -Y EXTERNAL -H ldapi:/// -b cn=schema,cn=config cn | grep -c $1)
    if [ "$COUNT" -eq 0 ]; then
      echo 1
    else
      echo 0
    fi
  }

  function ldap_add_or_modify (){
    local LDIF_FILE=$1
    log-helper debug "Processing file ${LDIF_FILE}"
    sed -i "s|{{ LDAP_BASE_DN }}|${LDAP_BASE_DN}|g" $LDIF_FILE
    sed -i "s|{{ LDAP_BACKEND }}|${LDAP_BACKEND}|g" $LDIF_FILE
    if [ "${LDAP_READONLY_USER,,}" == "true" ]; then
      sed -i "s|{{ LDAP_READONLY_USER_USERNAME }}|${LDAP_READONLY_USER_USERNAME}|g" $LDIF_FILE
      sed -i "s|{{ LDAP_READONLY_USER_PASSWORD_ENCRYPTED }}|${LDAP_READONLY_USER_PASSWORD_ENCRYPTED}|g" $LDIF_FILE
    fi
    if grep -iq changetype $LDIF_FILE ; then
        ldapmodify -Y EXTERNAL -Q -H ldapi:/// -f $LDIF_FILE 2>&1 | log-helper debug || ldapmodify -h localhost -p 389 -D cn=admin,$LDAP_BASE_DN -w $LDAP_ADMIN_PASSWORD -f $LDIF_FILE 2>&1 | log-helper debug
    else
        ldapadd -Y EXTERNAL -Q -H ldapi:/// -f $LDIF_FILE |& log-helper debug || ldapadd -h localhost -p 389 -D cn=admin,$LDAP_BASE_DN -w $LDAP_ADMIN_PASSWORD -f $LDIF_FILE 2>&1 | log-helper debug
    fi
  }

  #
  # Global variables
  #
  BOOTSTRAP=false

  #
  # database and config directory are empty
  # setup bootstrap config - Part 1
  #
  if [ -z "$(ls -A -I lost+found -I .rmtab -I .gitignore /var/lib/ldap)" ] && \
    [ -z "$(ls -A -I lost+found -I .rmtab -I .gitignore /etc/ldap/slapd.d)" ]; then

    BOOTSTRAP=true
    log-helper info "Database and config directory are empty..."
    log-helper info "Init new ldap server..."

    cat <<EOF | debconf-set-selections
slapd slapd/internal/generated_adminpw password ${LDAP_ADMIN_PASSWORD}
slapd slapd/internal/adminpw password ${LDAP_ADMIN_PASSWORD}
slapd slapd/password2 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/password1 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/dump_database_destdir string /var/backups/slapd-VERSION
slapd slapd/domain string ${LDAP_DOMAIN}
slapd shared/organization string ${LDAP_ORGANISATION}
slapd slapd/backend string ${LDAP_BACKEND^^}
slapd slapd/purge_database boolean true
slapd slapd/move_old_database boolean true
slapd slapd/allow_ldap_v2 boolean false
slapd slapd/no_configuration boolean false
slapd slapd/dump_database select when needed
EOF

    dpkg-reconfigure -f noninteractive slapd

    # RFC2307bis schema
    if [ "${LDAP_RFC2307BIS_SCHEMA,,}" == "true" ]; then

      log-helper info "Switching schema to RFC2307bis..."
      cp ${CONTAINER_SERVICE_DIR}/slapd/assets/config/bootstrap/schema/rfc2307bis.* /etc/ldap/schema/

      rm -f /etc/ldap/slapd.d/cn=config/cn=schema/*

      mkdir -p /tmp/schema
      slaptest -f ${CONTAINER_SERVICE_DIR}/slapd/assets/config/bootstrap/schema/rfc2307bis.conf -F /tmp/schema
      mv /tmp/schema/cn=config/cn=schema/* /etc/ldap/slapd.d/cn=config/cn=schema
      rm -r /tmp/schema

      chown -R openldap:openldap /etc/ldap/slapd.d/cn=config/cn=schema
    fi

    rm ${CONTAINER_SERVICE_DIR}/slapd/assets/config/bootstrap/schema/rfc2307bis.*

  #
  # Error: the database directory (/var/lib/ldap) is empty but not the config directory (/etc/ldap/slapd.d)
  #
  elif [ -z "$(ls -A -I lost+found -I .rmtab /var/lib/ldap)" ] && [ ! -z "$(ls -A -I lost+found -I .rmtab /etc/ldap/slapd.d)" ]; then
    log-helper error "Error: the database directory (/var/lib/ldap) is empty but not the config directory (/etc/ldap/slapd.d)"
    exit 1

  #
  # Error: the config directory (/etc/ldap/slapd.d) is empty but not the database directory (/var/lib/ldap)
  #
  elif [ ! -z "$(ls -A -I lost+found -I .rmtab /var/lib/ldap)" ] && [ -z "$(ls -A -I lost+found -I .rmtab /etc/ldap/slapd.d)" ]; then
    log-helper error "Error: the config directory (/etc/ldap/slapd.d) is empty but not the database directory (/var/lib/ldap)"
    exit 1
  fi

  log-helper info "Configuring smbldap-tools..."

  get_ldap_base_dn
  get_samba_domain

  # TODO Convert all local varibles to global, so scripts can use the entire range of available env strings.
  # Update configuration values for smbldap-tools and the fake samba conf
  SAMBA_DOMAIN=$SAMBA_DOMAIN LDAP_BASE_DN=$LDAP_BASE_DN perl -pe 's/\$([_A-Z]+)/$ENV{$1}/g' < /etc/samba/smb.conf.tmpl > /etc/samba/smb.conf
  LDAP_ADMIN_PASSWORD=$LDAP_ADMIN_PASSWORD LDAP_BASE_DN=$LDAP_BASE_DN perl -pe 's/\$([_A-Z]+)/$ENV{$1}/g' < /etc/smbldap-tools/smbldap_bind.conf.tmpl > /etc/smbldap-tools/smbldap_bind.conf
  SAMBA_DOMAIN=$SAMBA_DOMAIN SAMBA_SID=$SAMBA_SID LDAP_BASE_DN=$LDAP_BASE_DN perl -pe 's/\$([_A-Z]+)/$ENV{$1}/g' < /etc/smbldap-tools/smbldap.conf.tmpl > /etc/smbldap-tools/smbldap.conf

  if [ "${KEEP_EXISTING_CONFIG,,}" == "true" ]; then
    log-helper info "/!\ KEEP_EXISTING_CONFIG = true configration will not be updated"
  else
    #
    # start OpenLDAP
    #

    # get previous hostname if OpenLDAP was started with replication
    # to avoid configuration pbs
    PREVIOUS_HOSTNAME_PARAM=""
    if [ -e "$WAS_STARTED_WITH_REPLICATION" ]; then

      source $WAS_STARTED_WITH_REPLICATION

      # if previous hostname != current hostname
      # set previous hostname to a loopback ip in /etc/hosts
      if [ "$PREVIOUS_HOSTNAME" != "$HOSTNAME" ]; then
        echo "127.0.0.2 $PREVIOUS_HOSTNAME" >> /etc/hosts
        PREVIOUS_HOSTNAME_PARAM="ldap://$PREVIOUS_HOSTNAME"
      fi
    fi

    # if the config was bootstraped with TLS
    # to avoid error (#6) (#36) and (#44)
    # we create fake temporary certificates if they do not exists
    if [ -e "$WAS_STARTED_WITH_TLS" ]; then
      source $WAS_STARTED_WITH_TLS

      log-helper debug "Check previous TLS certificates..."

      # fix for #73
      # image started with an existing database/config created before 1.1.5
      [[ -z "$PREVIOUS_LDAP_TLS_CA_CRT_PATH" ]] && PREVIOUS_LDAP_TLS_CA_CRT_PATH="${CONTAINER_SERVICE_DIR}/slapd/assets/certs/$LDAP_TLS_CA_CRT_FILENAME"
      [[ -z "$PREVIOUS_LDAP_TLS_CRT_PATH" ]] && PREVIOUS_LDAP_TLS_CRT_PATH="${CONTAINER_SERVICE_DIR}/slapd/assets/certs/$LDAP_TLS_CRT_FILENAME"
      [[ -z "$PREVIOUS_LDAP_TLS_KEY_PATH" ]] && PREVIOUS_LDAP_TLS_KEY_PATH="${CONTAINER_SERVICE_DIR}/slapd/assets/certs/$LDAP_TLS_KEY_FILENAME"
      [[ -z "$PREVIOUS_LDAP_TLS_DH_PARAM_PATH" ]] && PREVIOUS_LDAP_TLS_DH_PARAM_PATH="${CONTAINER_SERVICE_DIR}/slapd/assets/certs/dhparam.pem"

      ssl-helper $LDAP_SSL_HELPER_PREFIX $PREVIOUS_LDAP_TLS_CRT_PATH $PREVIOUS_LDAP_TLS_KEY_PATH $PREVIOUS_LDAP_TLS_CA_CRT_PATH
      [ -f ${PREVIOUS_LDAP_TLS_DH_PARAM_PATH} ] || openssl dhparam -out ${LDAP_TLS_DH_PARAM_PATH} 2048

      chmod 600 ${PREVIOUS_LDAP_TLS_DH_PARAM_PATH}
      chown openldap:openldap $PREVIOUS_LDAP_TLS_CRT_PATH $PREVIOUS_LDAP_TLS_KEY_PATH $PREVIOUS_LDAP_TLS_CA_CRT_PATH $PREVIOUS_LDAP_TLS_DH_PARAM_PATH
    fi

    # start OpenLDAP
    log-helper info "Start OpenLDAP..."

    if log-helper level ge debug; then
      slapd -h "ldap://$HOSTNAME $PREVIOUS_HOSTNAME_PARAM ldap://localhost ldapi:///" -u openldap -g openldap -d $LDAP_LOG_LEVEL 2>&1 &
    else
      slapd -h "ldap://$HOSTNAME $PREVIOUS_HOSTNAME_PARAM ldap://localhost ldapi:///" -u openldap -g openldap
    fi


    log-helper info "Waiting for OpenLDAP to start..."
    while [ ! -e /run/slapd/slapd.pid ]; do sleep 0.1; done

    #
    # setup bootstrap config - Part 2
    #
    if $BOOTSTRAP; then

      log-helper info "Add ppolicy schema..."

      # add ppolicy schema
      ldapadd -c -Y EXTERNAL -Q -H ldapi:/// -f /etc/ldap/schema/ppolicy.ldif 2>&1 | log-helper debug

      log-helper info "Add bootstrap schemas..."

      # convert schemas to ldif
      SCHEMAS=""
      for f in $(find ${CONTAINER_SERVICE_DIR}/slapd/assets/config/bootstrap/schema -name \*.schema -type f); do
        SCHEMAS="$SCHEMAS ${f}"
      done
      ${CONTAINER_SERVICE_DIR}/slapd/assets/schema-to-ldif.sh "$SCHEMAS"

      log-helper info "Step 2..."

      # add converted schemas
      for f in $(find ${CONTAINER_SERVICE_DIR}/slapd/assets/config/bootstrap/schema -name \*.ldif -type f|sort); do
        # add schema if not already exists
        SCHEMA=$(basename "${f}" .ldif)
        ADD_SCHEMA=$(is_new_schema $SCHEMA)
        if [ "$ADD_SCHEMA" -eq 1 ]; then
          cat $f | LDAP_BACKEND=$LDAP_BACKEND perl -pe 's/\$([_A-Z]+)/$ENV{$1}/g' | ldapadd -c -Y EXTERNAL -Q -H ldapi:/// 2>&1 | log-helper debug
          log-helper info "schema ${f} succceded"
        else
          log-helper info "schema ${f} already exists"
        fi
      done

      log-helper info "Step 3..."

      # set config password
      LDAP_CONFIG_PASSWORD_ENCRYPTED=$(slappasswd -s $LDAP_CONFIG_PASSWORD)
      sed -i "s|{{ LDAP_CONFIG_PASSWORD_ENCRYPTED }}|${LDAP_CONFIG_PASSWORD_ENCRYPTED}|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/bootstrap/ldif/01-config-password.ldif

      # adapt security config file
      get_ldap_base_dn
      sed -i "s|{{ LDAP_BASE_DN }}|${LDAP_BASE_DN}|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/bootstrap/ldif/02-security.ldif

      # process config files (*.ldif) in bootstrap directory (do no process files in subdirectories)
      log-helper info "Add image bootstrap ldif..."
      for f in $(find ${CONTAINER_SERVICE_DIR}/slapd/assets/config/bootstrap/ldif -mindepth 1 -maxdepth 1 -type f -name \*.ldif  | sort); do
        log-helper debug "Processing file ${f}"
        ldap_add_or_modify "$f"
      done

      # read only user
      if [ "${LDAP_READONLY_USER,,}" == "true" ]; then
        log-helper info "Add read only user..."

        LDAP_READONLY_USER_PASSWORD_ENCRYPTED=$(slappasswd -s $LDAP_READONLY_USER_PASSWORD)

        ldap_add_or_modify "${CONTAINER_SERVICE_DIR}/slapd/assets/config/bootstrap/ldif/readonly-user/readonly-user.ldif"
        ldap_add_or_modify "${CONTAINER_SERVICE_DIR}/slapd/assets/config/bootstrap/ldif/readonly-user/readonly-user-acl.ldif"
      fi

      log-helper info "Add custom bootstrap ldif..."
      for f in $(find ${CONTAINER_SERVICE_DIR}/slapd/assets/config/bootstrap/ldif/custom -type f -name \*.ldif  | sort); do
        ldap_add_or_modify "$f"
      done

      # Preload LDAP with Samba Directory using smbldap-tools
      if [ "${LDAP_NOPRELOAD,,}" == "false" ]; then
		log-helper info "Preloading SAMBA database..."
        echo ${LDAP_ADMIN_PASSWORD} | /usr/sbin/smbldap-populate -p
      fi

    fi

    #
    # TLS config
    #
    if [ -e "$WAS_STARTED_WITH_TLS" ] && [ "${LDAP_TLS,,}" != "true" ]; then
      log-helper error "/!\ WARNING: LDAP_TLS=false but the container was previously started with LDAP_TLS=true"
      log-helper error "TLS can't be disabled once added. Ignoring LDAP_TLS=false."
      LDAP_TLS=true
    fi

    if [ -e "$WAS_STARTED_WITH_TLS_ENFORCE" ] && [ "${LDAP_TLS_ENFORCE,,}" != "true" ]; then
      log-helper error "/!\ WARNING: LDAP_TLS_ENFORCE=false but the container was previously started with LDAP_TLS_ENFORCE=true"
      log-helper error "TLS enforcing can't be disabled once added. Ignoring LDAP_TLS_ENFORCE=false."
      LDAP_TLS_ENFORCE=true
    fi

    if [ "${LDAP_TLS,,}" == "true" ]; then

      log-helper info "Add TLS config..."

      # generate a certificate and key with ssl-helper tool if LDAP_CRT and LDAP_KEY files don't exists
      # https://github.com/osixia/docker-light-baseimage/blob/stable/image/service-available/:ssl-tools/assets/tool/ssl-helper
      ssl-helper $LDAP_SSL_HELPER_PREFIX $LDAP_TLS_CRT_PATH $LDAP_TLS_KEY_PATH $LDAP_TLS_CA_CRT_PATH

      # create DHParamFile if not found
      [ -f ${LDAP_TLS_DH_PARAM_PATH} ] || openssl dhparam -out ${LDAP_TLS_DH_PARAM_PATH} 2048
      chmod 600 ${LDAP_TLS_DH_PARAM_PATH}

      # fix file permissions
      chown -R openldap:openldap ${CONTAINER_SERVICE_DIR}/slapd

      # adapt tls ldif
      sed -i "s|{{ LDAP_TLS_CA_CRT_PATH }}|${LDAP_TLS_CA_CRT_PATH}|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/tls/tls-enable.ldif
      sed -i "s|{{ LDAP_TLS_CRT_PATH }}|${LDAP_TLS_CRT_PATH}|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/tls/tls-enable.ldif
      sed -i "s|{{ LDAP_TLS_KEY_PATH }}|${LDAP_TLS_KEY_PATH}|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/tls/tls-enable.ldif
      sed -i "s|{{ LDAP_TLS_DH_PARAM_PATH }}|${LDAP_TLS_DH_PARAM_PATH}|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/tls/tls-enable.ldif

      sed -i "s|{{ LDAP_TLS_CIPHER_SUITE }}|${LDAP_TLS_CIPHER_SUITE}|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/tls/tls-enable.ldif
      sed -i "s|{{ LDAP_TLS_VERIFY_CLIENT }}|${LDAP_TLS_VERIFY_CLIENT}|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/tls/tls-enable.ldif

      ldapmodify -Y EXTERNAL -Q -H ldapi:/// -f ${CONTAINER_SERVICE_DIR}/slapd/assets/config/tls/tls-enable.ldif 2>&1 | log-helper debug

      [[ -f "$WAS_STARTED_WITH_TLS" ]] && rm -f "$WAS_STARTED_WITH_TLS"
      echo "export PREVIOUS_LDAP_TLS_CA_CRT_PATH=${LDAP_TLS_CA_CRT_PATH}" > $WAS_STARTED_WITH_TLS
      echo "export PREVIOUS_LDAP_TLS_CRT_PATH=${LDAP_TLS_CRT_PATH}" >> $WAS_STARTED_WITH_TLS
      echo "export PREVIOUS_LDAP_TLS_KEY_PATH=${LDAP_TLS_KEY_PATH}" >> $WAS_STARTED_WITH_TLS
      echo "export PREVIOUS_LDAP_TLS_DH_PARAM_PATH=${LDAP_TLS_DH_PARAM_PATH}" >> $WAS_STARTED_WITH_TLS

      # enforce TLS
      if [ "${LDAP_TLS_ENFORCE,,}" == "true" ]; then
        log-helper info "Add enforce TLS..."
        ldapmodify -Y EXTERNAL -Q -H ldapi:/// -f ${CONTAINER_SERVICE_DIR}/slapd/assets/config/tls/tls-enforce-enable.ldif 2>&1 | log-helper debug
        touch $WAS_STARTED_WITH_TLS_ENFORCE

      # disable tls enforcing (not possible for now)
      #else
        #log-helper info "Disable enforce TLS..."
        #ldapmodify -Y EXTERNAL -Q -H ldapi:/// -f ${CONTAINER_SERVICE_DIR}/slapd/assets/config/tls/tls-enforce-disable.ldif 2>&1 | log-helper debug || true
        #[[ -f "$WAS_STARTED_WITH_TLS_ENFORCE" ]] && rm -f "$WAS_STARTED_WITH_TLS_ENFORCE"
      fi

    # disable tls (not possible for now)
    #else
      #log-helper info "Disable TLS config..."
      #ldapmodify -c -Y EXTERNAL -Q -H ldapi:/// -f ${CONTAINER_SERVICE_DIR}/slapd/assets/config/tls/tls-disable.ldif 2>&1 | log-helper debug || true
      #[[ -f "$WAS_STARTED_WITH_TLS" ]] && rm -f "$WAS_STARTED_WITH_TLS"
    fi



    #
    # Replication config
    #

    function disableReplication() {
      sed -i "s|{{ LDAP_BACKEND }}|${LDAP_BACKEND}|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/replication/replication-disable.ldif
      ldapmodify -c -Y EXTERNAL -Q -H ldapi:/// -f ${CONTAINER_SERVICE_DIR}/slapd/assets/config/replication/replication-disable.ldif 2>&1 | log-helper debug || true
      [[ -f "$WAS_STARTED_WITH_REPLICATION" ]] && rm -f "$WAS_STARTED_WITH_REPLICATION"
    }

    if [ "${LDAP_REPLICATION,,}" == "true" ]; then

      log-helper info "Add replication config..."
      disableReplication || true

      i=1
      for host in $(complex-bash-env iterate LDAP_REPLICATION_HOSTS)
      do
        sed -i "s|{{ LDAP_REPLICATION_HOSTS }}|olcServerID: $i ${!host}\n{{ LDAP_REPLICATION_HOSTS }}|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/replication/replication-enable.ldif
        sed -i "s|{{ LDAP_REPLICATION_HOSTS_CONFIG_SYNC_REPL }}|olcSyncRepl: rid=00$i provider=${!host} ${LDAP_REPLICATION_CONFIG_SYNCPROV}\n{{ LDAP_REPLICATION_HOSTS_CONFIG_SYNC_REPL }}|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/replication/replication-enable.ldif
        sed -i "s|{{ LDAP_REPLICATION_HOSTS_DB_SYNC_REPL }}|olcSyncRepl: rid=10$i provider=${!host} ${LDAP_REPLICATION_DB_SYNCPROV}\n{{ LDAP_REPLICATION_HOSTS_DB_SYNC_REPL }}|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/replication/replication-enable.ldif

        ((i++))
      done

      get_ldap_base_dn
      sed -i "s|\$LDAP_BASE_DN|$LDAP_BASE_DN|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/replication/replication-enable.ldif
      sed -i "s|\$LDAP_ADMIN_PASSWORD|$LDAP_ADMIN_PASSWORD|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/replication/replication-enable.ldif
      sed -i "s|\$LDAP_CONFIG_PASSWORD|$LDAP_CONFIG_PASSWORD|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/replication/replication-enable.ldif

      sed -i "/{{ LDAP_REPLICATION_HOSTS }}/d" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/replication/replication-enable.ldif
      sed -i "/{{ LDAP_REPLICATION_HOSTS_CONFIG_SYNC_REPL }}/d" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/replication/replication-enable.ldif
      sed -i "/{{ LDAP_REPLICATION_HOSTS_DB_SYNC_REPL }}/d" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/replication/replication-enable.ldif

      sed -i "s|{{ LDAP_BACKEND }}|${LDAP_BACKEND}|g" ${CONTAINER_SERVICE_DIR}/slapd/assets/config/replication/replication-enable.ldif

      ldapmodify -c -Y EXTERNAL -Q -H ldapi:/// -f ${CONTAINER_SERVICE_DIR}/slapd/assets/config/replication/replication-enable.ldif 2>&1 | log-helper debug || true

      [[ -f "$WAS_STARTED_WITH_REPLICATION" ]] && rm -f "$WAS_STARTED_WITH_REPLICATION"
      echo "export PREVIOUS_HOSTNAME=${HOSTNAME}" > $WAS_STARTED_WITH_REPLICATION

    else

      log-helper info "Disable replication config..."
      disableReplication || true

    fi

    #
    # stop OpenLDAP
    #
    log-helper info "Stop OpenLDAP..."

    SLAPD_PID=$(cat /run/slapd/slapd.pid)
    kill -15 $SLAPD_PID
    while [ -e /proc/$SLAPD_PID ]; do sleep 0.1; done # wait until slapd is terminated
  fi

  #
  # ldap client config
  #
  if [ "${LDAP_TLS,,}" == "true" ]; then
    log-helper info "Configure ldap client TLS configuration..."
    sed -i --follow-symlinks "s,TLS_CACERT.*,TLS_CACERT ${LDAP_TLS_CA_CRT_PATH},g" /etc/ldap/ldap.conf
    echo "TLS_REQCERT ${LDAP_TLS_VERIFY_CLIENT}" >> /etc/ldap/ldap.conf
    cp -f /etc/ldap/ldap.conf ${CONTAINER_SERVICE_DIR}/slapd/assets/ldap.conf

    [[ -f "$HOME/.ldaprc" ]] && rm -f $HOME/.ldaprc
    echo "TLS_CERT ${LDAP_TLS_CRT_PATH}" > $HOME/.ldaprc
    echo "TLS_KEY ${LDAP_TLS_KEY_PATH}" >> $HOME/.ldaprc
    cp -f $HOME/.ldaprc ${CONTAINER_SERVICE_DIR}/slapd/assets/.ldaprc
  fi

  #
  # remove container config files
  #
  if [ "${LDAP_REMOVE_CONFIG_AFTER_SETUP,,}" == "true" ]; then
    log-helper info "Remove config files..."
    rm -rf ${CONTAINER_SERVICE_DIR}/slapd/assets/config
  fi

  #
  # setup done :)
  #
  log-helper info "First start is done..."
  touch $FIRST_START_DONE
fi

ln -sf ${CONTAINER_SERVICE_DIR}/slapd/assets/.ldaprc $HOME/.ldaprc
ln -sf ${CONTAINER_SERVICE_DIR}/slapd/assets/ldap.conf /etc/ldap/ldap.conf

# force OpenLDAP to listen on all interfaces
ETC_HOSTS=$(cat /etc/hosts | sed "/$HOSTNAME/d")
echo "0.0.0.0 $HOSTNAME" > /etc/hosts
echo "$ETC_HOSTS" >> /etc/hosts

exit 0
