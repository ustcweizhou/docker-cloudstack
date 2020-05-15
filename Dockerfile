FROM        ubuntu:16.04
MAINTAINER  Wei Zhou <w.zhou@global.leaseweb.com>

ENV         DEBIAN_FRONTEND noninteractive

RUN         apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 0xB1998361219BD9C9 && \
            echo 'deb http://repos.azulsystems.com/ubuntu stable main' >/etc/apt/sources.list.d/azul.list && \
            apt update -qq

RUN         apt install -y python genisoimage nfs-common \
                zulu-11 sudo python-mysql.connector augeas-tools mysql-client \
                bzip2 ipmitool file gawk iproute2 qemu-utils python-dnspython lsb-release \
                python-pip python-dev libffi-dev

RUN         apt install -y curl && \
            curl -LO https://github.com/apache/cloudstack-cloudmonkey/releases/download/6.0.0/cmk.linux.x86-64 && \
            mv cmk.linux.x86-64 /usr/bin/cmk && \
            chmod +x /usr/bin/cmk && \
            cmk -v

EXPOSE      8080

COPY        entrypoint.sh /entrypoint.sh

ENTRYPOINT  ["/entrypoint.sh"]

CMD         ["start"]
