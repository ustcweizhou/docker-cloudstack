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

fix_mariadb_db01() {
    # It may not be safe to bootstrap the cluster from this node. 
    # It was not the last one to leave the cluster and may not contain all the updates.
    # To force cluster bootstrap with this node, edit the grastate.dat file manually and set safe_to_bootstrap to 1 .
    mkdir -p ${DIR_NAME}/db01 ${DIR_NAME}/db02 ${DIR_NAME}/db03
    if [ -f "${DIR_NAME}/db01/grastate.dat" ];then
        sed -i "s,safe_to_bootstrap: 0,safe_to_bootstrap: 1,g" ${DIR_NAME}/db01/grastate.dat
    fi
}

fix_mariadb_utf8() {
    # Illegal mix of collations (utf8_unicode_ci,IMPLICIT) and (utf8_general_ci,IMPLICIT) for operation '='
    cmd="sed -i 's,^collation-server,;collation-server,g' /etc/mysql/conf.d/utf8.cnf"
    ./docker-compose -f galera-cluster.yaml -p galera-cluster exec db01 /bin/bash -c "$cmd"
    ./docker-compose -f galera-cluster.yaml -p galera-cluster exec db02 /bin/bash -c "$cmd"
    ./docker-compose -f galera-cluster.yaml -p galera-cluster exec db03 /bin/bash -c "$cmd"
    fix_mariadb_db01
    ./docker-compose -f galera-cluster.yaml -p galera-cluster restart db01
    check_database
    ./docker-compose -f galera-cluster.yaml -p galera-cluster restart db02
    ./docker-compose -f galera-cluster.yaml -p galera-cluster restart db03
}

check_database() {
    set +e
    retry=$CHECK_RETRIES
    echo -n "Checking database connection .."
    while [ $retry -gt 0 ];do
        echo -n "."
        host=$(MYSQL_PWD=cloudstack mysql -h ${DB_VIP} -uroot -NB -e "SELECT @@hostname" 2>&1)
        if [ $? -eq 0 ] && [ "$host" != "" ];then
            echo " connected"
            log_it "Connected to mariadb galera cluster"
            break
        fi
        let retry=retry-1
        sleep $CHECK_INTERVAL
    done
    if [ $retry -eq 0 ];then
        echo " timeout"
        log_it "Failed to connect to mariadb galera cluster, exiting"
        exit 1
    fi
    set -e
}

check_mgtserver() {
    set +e
    retry=$CHECK_RETRIES
    echo -n "Checking CloudStack management server mgt01 .."
    cmk_cmd="/usr/bin/cmk list accounts filter=name"
    while [ $retry -gt 0 ];do
        echo -n "."
        cmk_listaccounts=$(./docker-compose -f cloudstack-mgtservers.yaml -p cloudstack-mgt exec mgt01 /bin/bash -c "$cmk_cmd" 2>&1)
        if [ $? -eq 0 ] && [ "$cmk_listaccounts" != "" ];then
            echo " connected"
            log_it "Connected to CloudStack management server mgt01"
            break
        fi
        let retry=retry-1
        sleep $CHECK_INTERVAL
    done
    if [ $retry -eq 0 ];then
        echo " timeout"
        log_it "Failed to connect to CloudStack management server mgt01, exiting"
        exit 1
    fi
    set -e
}

if [ -d ".git" ];then
    git checkout *.yaml *.conf
fi

source cloudstack.cnf

sed -i "s,{{ dir }},${DIR_NAME},g" *.yaml *.conf
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

if [ "$action" = "create" ];then
    # Copy files
    cp nginx-galera.conf ${DIR_NAME}/
    cp nginx-cloudstack.conf ${DIR_NAME}/

    # Create docker network
    is_bridged=$(docker network ls --filter name=${BRIDGE_NAME})
    if [ "$is_bridged" != "" ];then
        log_it "docker network ${BRIDGE_NAME} already exists"
    else
        log_it "Creating docker network ${BRIDGE_NAME} ..."
        docker network create -d bridge \
            --subnet=${SUBNET} \
            --gateway=${HOST_IP} \
            --ip-range=${SUBNET} \
            -o "com.docker.network.bridge.name=breth1" ${BRIDGE_NAME}
    fi

    # Create mariadb cluster (run only once)
    fix_mariadb_db01
    ./docker-compose -f galera-cluster-setup.yaml -p galera-cluster up -d
    check_database
    fix_mariadb_utf8

    # Create CloudStack management server mgt01/mgt02/mgt03 and setup cloudstack database
    ./docker-compose -f cloudstack-mgtservers-setup.yaml -p cloudstack-mgt up -d
    check_mgtserver

elif [ "$action" = "delete" ];then
    ./docker-compose -f cloudstack-mgtservers.yaml -p cloudstack-mgt down
    ./docker-compose -f galera-cluster.yaml -p galera-cluster down
    rm -rf ${DIR_NAME}/db0*/*
elif [ "$action" = "restart" ];then
    fix_mariadb_db01
    ./docker-compose -f galera-cluster.yaml -p galera-cluster up -d
    check_database
    fix_mariadb_utf8
    ./docker-compose -f cloudstack-mgtservers.yaml -p cloudstack-mgt up -d
    check_mgtserver
elif [ "$action" = "stop" ];then
    ./docker-compose -f cloudstack-mgtservers.yaml -p cloudstack-mgt down
    ./docker-compose -f galera-cluster.yaml -p galera-cluster down
elif [ "$action" = "cmd" ];then
    shift
    server=$2
    if [[ $server == db* ]];then
        ./docker-compose -f galera-cluster.yaml -p galera-cluster $@
    elif [[ $server == mgt* ]];then
        ./docker-compose -f cloudstack-mgtservers.yaml -p cloudstack-mgt $@
    fi
fi
