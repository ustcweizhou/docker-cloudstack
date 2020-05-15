
# Build docker image
docker build -f Dockerfile -t cloudstack-management:ubuntu1604 .

# Create mariadb cluster (run only once)
docker-compose -f galera_cluster.yml up -d

# Start mariadb cluster (run if mariadb cluster is stopped)
docker-compose -f galera_cluster_created.yml up -d

# Start CloudStack management server mgt01 and setup cloudstack database
docker-compose -f cloudstack-mgt01-setup.yaml up -d

# Start other CloudStack management server mgt02/mgt03/nginx
docker-compose -f cloudstack-mgt02-03-vip-install.yaml up -d

# Start all CloudStack management servers mgt01/mgt02/mgt03/nginx if stopped 
docker-compose -f cloudstack-mgtservers-start.yaml up -d
