#!/bin/bash
set -e

action=$1
help() {
    echo "Examples: "
    echo "$0 create     # Create a CloudStack environment with cloudstack.cnf"
    echo "$0 delete     # Delete a CloudStack environment with cloudstack.cnf"
    echo "$0 start      # Start a CloudStack environment with cloudstack.cnf"
    echo "$0 stop       # Stop a CloudStack environment with cloudstack.cnf"
}

if [ "$action" = "" ]; then
    help
    exit 1
fi

log_it() {
    echo "$(date +%T) : $*"
}

fix_mariadb_bootstrap() {
    # It may not be safe to bootstrap the cluster from this node. 
    # It was not the last one to leave the cluster and may not contain all the updates.
    # To force cluster bootstrap with this node, edit the grastate.dat file manually and set safe_to_bootstrap to 1 .
    db=$1
    if [ -f "${DATA_DIR}/$db/grastate.dat" ];then
        sed -i "s,safe_to_bootstrap: 0,safe_to_bootstrap: 1,g" ${DATA_DIR}/$db/grastate.dat
        log_it "Updated safe_to_bootstrap in ${DATA_DIR}/$db/grastate.dat to 1"
    fi
}

fix_mariadb_utf8() {
    # Illegal mix of collations (utf8_unicode_ci,IMPLICIT) and (utf8_general_ci,IMPLICIT) for operation '='
    db=$1
    cmd="sed -i 's,^collation-server,;collation-server,g' /etc/mysql/conf.d/utf8.cnf"
    ./docker-compose -f ${PROJECT}/galera-cluster.yaml -p ${PROJECT_GALERA} exec $db /bin/bash -c "$cmd"
#    cmd="MYSQL_PWD=cloudstack mysql -uroot -e 'SET GLOBAL wsrep_provider_options=\"pc.bootstrap=1\"'"
#    ./docker-compose -f ${PROJECT}/galera-cluster.yaml -p ${PROJECT_GALERA} exec $db /bin/bash -c "$cmd"
    ./docker-compose -f ${PROJECT}/galera-cluster.yaml -p ${PROJECT_GALERA} stop $db
    fix_mariadb_bootstrap $db
    ./docker-compose -f ${PROJECT}/galera-cluster.yaml -p ${PROJECT_GALERA} start $db
}

check_database() {
    set +e
    db=$1
    cmd="MYSQL_PWD=cloudstack mysql -h $db -uroot -NB -e 'SELECT @@hostname' 2>&1"
    retry=$HEALTHCHECK_RETRIES
    echo -n "Checking $db database connection .."
    while [ $retry -gt 0 ];do
        echo -n "."
        host=$(./docker-compose -f ${PROJECT}/galera-cluster.yaml -p ${PROJECT_GALERA} exec $db /bin/bash -c "$cmd")
        if [ $? -eq 0 ] && [ "$host" != "" ];then
            echo " connected"
            log_it "Connected to $db"
            break
        fi
        let retry=retry-1
        sleep $HEALTHCHECK_INTERVAL
    done
    if [ $retry -eq 0 ];then
        echo " timeout"
        log_it "Failed to connect to $db, exiting"
        exit 1
    fi
    set -e
}

check_mgtserver() {
    set +e
    mgt=$1
    retry=$HEALTHCHECK_RETRIES
    echo -n "Checking CloudStack management server $mgt .."
    cmk_cmd="/usr/bin/cmk list accounts filter=name"
    while [ $retry -gt 0 ];do
        echo -n "."
        cmk_listaccounts=$(./docker-compose -f ${PROJECT}/cloudstack-mgtservers.yaml -p ${PROJECT_CLOUDSTACK} exec $mgt /bin/bash -c "$cmk_cmd" 2>&1)
        if [ $? -eq 0 ] && [ "$cmk_listaccounts" != "" ];then
            echo " connected"
            log_it "Connected to CloudStack management server $mgt"
            break
        fi
        let retry=retry-1
        sleep $HEALTHCHECK_INTERVAL
    done
    if [ $retry -eq 0 ];then
        echo " timeout"
        log_it "Failed to connect to CloudStack management server $mgt, exiting"
        exit 1
    fi
    set -e
}

load_conf() {
    source cloudstack.cnf

    if [ -z "${PROJECT}" ];then
        log_it "You must specify the PROJECT in conf file"
        exit 1
    fi    

    DATA_DIR="${DIR_NAME}/${PROJECT}"
    PROJECT_GALERA=${PROJECT}-galera-cluster
    PROJECT_CLOUDSTACK=${PROJECT}-cloudstack-mgt

    mkdir -p ${PROJECT}
    cp cloudstack.cnf ${PROJECT}/cloudstack.cnf
    echo "DATA_DIR=$DATA_DIR" >> ${PROJECT}/cloudstack.cnf
    echo "PROJECT_GALERA=$PROJECT_GALERA" >> ${PROJECT}/cloudstack.cnf
    echo "PROJECT_CLOUDSTACK=$PROJECT_CLOUDSTACK" >> ${PROJECT}/cloudstack.cnf

    cp *.yaml *.conf ${PROJECT}
    cd ${PROJECT}
    sed -i "s,{{ dir }},${DATA_DIR},g" *.yaml *.conf
    sed -i "s,{{ host_ip }},${HOST_IP},g" *.yaml *.conf
    sed -i "s,{{ subnet }},${SUBNET},g" *.yaml
    sed -i "s,{{ bridge }},${BRIDGE_NAME},g" *.yaml
    sed -i "s,{{ db01_ip }},${DB01_IP},g" *.yaml *.conf
    sed -i "s,{{ db02_ip }},${DB02_IP},g" *.yaml *.conf
    sed -i "s,{{ db03_ip }},${DB03_IP},g" *.yaml *.conf
    sed -i "s,{{ db_vip }},${DB_VIP},g" *.yaml *.conf
    sed -i "s,{{ mgt01_ip }},${MGT01_IP},g" *.yaml *.conf
    sed -i "s,{{ mgt02_ip }},${MGT02_IP},g" *.yaml *.conf
    sed -i "s,{{ mgt03_ip }},${MGT03_IP},g" *.yaml *.conf
    sed -i "s,{{ mgt_vip }},${MGT_VIP},g" *.yaml *.conf

    sed -i "s,{{ check_interval }},${HEALTHCHECK_INTERVAL},g" *.yaml *.conf
    sed -i "s,{{ check_timeout }},${HEALTHCHECK_TIMEOUT},g" *.yaml *.conf
    sed -i "s,{{ check_retries }},${HEALTHCHECK_RETRIES},g" *.yaml *.conf

    mkdir -p ${DATA_DIR}
    cp nginx-galera.conf ${DATA_DIR}/
    cp nginx-cloudstack.conf ${DATA_DIR}/
    cd ..
}

load_conf

if [ "$action" = "create" ];then
    # Copy files
    mkdir -p ${DATA_DIR}/db01 ${DATA_DIR}/db02 ${DATA_DIR}/db03
    mkdir -p ${DATA_DIR}/mgt01/etc ${DATA_DIR}/mgt01/log
    mkdir -p ${DATA_DIR}/mgt02/etc ${DATA_DIR}/mgt02/log
    mkdir -p ${DATA_DIR}/mgt03/etc ${DATA_DIR}/mgt03/log
    mkdir -p ${DATA_DIR}/packages/
    cp packages/* ${DATA_DIR}/packages/

    # Create docker network
    if [ -z "${BRIDGE_NAME}" ];then
        BRIDGE_NAME="br-{PROJECT}"
    fi
    is_bridged=$(docker network ls --filter name=${BRIDGE_NAME} | grep -v "NETWORK ID" || true)
    if [ "$is_bridged" != "" ];then
        log_it "docker network ${BRIDGE_NAME} already exists"
    else
        log_it "Creating docker network ${BRIDGE_NAME} ..."
        docker network create -d bridge \
            --subnet=${SUBNET} \
            --gateway=${HOST_IP} \
            --ip-range=${SUBNET} \
            -o "com.docker.network.bridge.name=${BRIDGE_NAME}" ${BRIDGE_NAME}
    fi

    # Create mariadb cluster (run only once)
    fix_mariadb_bootstrap "db01"
    ./docker-compose -f ${PROJECT}/galera-cluster-setup.yaml -p ${PROJECT_GALERA} up -d
    check_database "db01"
    check_database "db02"
    check_database "db03"
    fix_mariadb_utf8 "db01"
    check_database "db01"
    check_database "db02"
    check_database "db03"

    exit 0
    # Create CloudStack management server mgt01/mgt02/mgt03 and setup cloudstack database
    ./docker-compose -f ${PROJECT}/cloudstack-mgtservers-setup.yaml -p ${PROJECT_CLOUDSTACK} up -d
    check_mgtserver "mgt01"
    check_mgtserver "mgt02"
    check_mgtserver "mgt03"

elif [ "$action" = "delete" ];then
    ./docker-compose -f ${PROJECT}/cloudstack-mgtservers.yaml -p ${PROJECT_CLOUDSTACK} down
    ./docker-compose -f ${PROJECT}/galera-cluster.yaml -p ${PROJECT_GALERA} down
    rm -rf ${DATA_DIR}/
elif [ "$action" = "restart" ];then
    fix_mariadb_bootstrap "db01"
    ./docker-compose -f ${PROJECT}/galera-cluster.yaml -p ${PROJECT_GALERA} up -d
    check_database "db01"
    check_database "db02"
    check_database "db03"
    fix_mariadb_utf8
    ./docker-compose -f ${PROJECT}/cloudstack-mgtservers.yaml -p ${PROJECT_CLOUDSTACK} up -d
    check_mgtserver "mgt01"
    check_mgtserver "mgt02"
    check_mgtserver "mgt03"
elif [ "$action" = "stop" ];then
    ./docker-compose -f ${PROJECT}/cloudstack-mgtservers.yaml -p ${PROJECT_CLOUDSTACK} down
    ./docker-compose -f ${PROJECT}/galera-cluster.yaml -p ${PROJECT_GALERA} down
elif [ "$action" = "cmd" ];then
    shift
    server=$2
    if [[ $server == -* ]];then
        server=$3
    fi
    if [[ $server == db* ]];then
        cmd="./docker-compose -f ${PROJECT}/galera-cluster.yaml -p ${PROJECT_GALERA} $@"
    elif [[ $server == mgt* ]];then
        cmd="./docker-compose -f ${PROJECT}/cloudstack-mgtservers.yaml -p ${PROJECT_CLOUDSTACK} $@"
    fi
    if [ "$cmd" != "" ];then
        log_it "Executing: $cmd"
        $cmd
    fi
fi
