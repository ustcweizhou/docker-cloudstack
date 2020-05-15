#!/bin/bash
set -e

install_apt_packages() {
    version=$1
    echo "Installing CloudStack $version packages from APT repo"
    apt install -y --allow-downgrades cloudstack-{common,management,marvin,usage}=$version
}

install_local_packages() {
    version=$1
    echo "Installing CloudStack $version packages from local"
    dpkg -i /root/packages/cloudstack-{common,management,marvin,usage}_${version}_all.deb
}

setup_cloudstack() {
    action=$1
    ip=$(hostname --ip-address | cut -d" " -f1)
    if [ -z "${MYSQL_CLOUD_PASSWORD}" ] || [ -z "${MYSQL_ADDRESS}" ] \
            || [ -z "${MANAGEMENT_KEY}" ] || [ -z "${DATABASE_KEY}" ];then
        echo >&2 'Missing MYSQL_CLOUD_PASSWORD or MYSQL_ADDRESS or MANAGEMENT_KEY or DATABASE_KEY'
        exit 1
    fi
    if [ "$action" = "install" ];then
        command="cloudstack-setup-databases cloud:${MYSQL_CLOUD_PASSWORD}@${MYSQL_ADDRESS} -e file -m ${MANAGEMENT_KEY} -k ${DATABASE_KEY} -i $ip"
    elif [ "$action" = "setup" ];then
        if [ -z "${MYSQL_ROOT_PASSWORD}" ];then
            echo >&2 'Missing MYSQL_ROOT_PASSWORD'
            exit 1
        fi
        command="cloudstack-setup-databases cloud:${MYSQL_CLOUD_PASSWORD}@${MYSQL_ADDRESS} --deploy-as=root:${MYSQL_ROOT_PASSWORD} -e file -m ${MANAGEMENT_KEY} -k ${DATABASE_KEY} -i $ip"
    fi
    $command
    cloudstack-setup-management --no-start
}

start_cloudstack() {
    action=$1

    source /etc/default/cloudstack-management
    /usr/bin/java $JAVA_DEBUG $JAVA_OPTS -cp $CLASSPATH $BOOTSTRAP_CLASS > /dev/null 2>&1 & 

    source /etc/default/cloudstack-usage
    /usr/bin/java -Dpid=$$ $JAVA_OPTS $JAVA_DEBUG -cp $CLASSPATH $JAVA_CLASS > /dev/null 2>&1 &
}

for f in `ls /root/packages/*.asc`;do
    apt-key add $f;
done

for f in `ls /root/packages/*.list`;do
    cp $f /etc/apt/sources.list.d/;
done

apt update -qq

if [ "$1" = "start" ] || [ "$1" = "restart" ];then
    start_cloudstack $1
    exit 0
fi

if [ "$1" = "setup" ] || [ "$1" = "install" ];then
    echo "Installing CloudStack management server"
    apt_version=$(apt-cache madison cloudstack-common | grep -w "$CLOUDSTACK_VERSION" | head -n1 |awk '{print $3}')
    if [ "$?" != "0" ] || [ "$apt_version" = "" ];then
        echo "Cannot find CloudStack $CLOUDSTACK_VERSION packages in APT repo"
        local_file=$(find /root/packages -name cloudstack-common_${CLOUDSTACK_VERSION}_all.deb >/dev/null 2>&1)
        if [ "$?" != "0" ] || [ "local_file" = "" ];then
            echo "Cannot find CloudStack $CLOUDSTACK_VERSION packages locally"
        else
            echo "Found CloudStack $CLOUDSTACK_VERSION packages locally"
            install_local_packages $CLOUDSTACK_VERSION
        fi
    else
        echo "Found CloudStack $apt_version packages in APT repo"
        install_apt_packages $apt_version
    fi
    echo "Setting up CloudStack management server"
    setup_cloudstack $1
    start_cloudstack "restart"
fi
