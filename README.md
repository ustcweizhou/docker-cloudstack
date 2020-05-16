
# Build docker image
docker build -f Dockerfile -t cloudstack-management:ubuntu1604 .

# Create mariadb cluster (run only once)
docker-compose -f galera-cluster-setup.yaml -p galera-cluster up -d

# Start mariadb cluster (run if mariadb cluster is stopped)
docker-compose -f galera-cluster.yaml -p galera-cluster up -d

# Create CloudStack management server mgt01/mgt02/mgt03 and setup cloudstack database
docker-compose -f cloudstack-mgtservers-setup.yaml -p cloudstack-mgt up -d

# Start all CloudStack management servers mgt01/mgt02/mgt03/nginx if stopped 
docker-compose -f cloudstack-mgtservers.yaml -p cloudstack-mgt up -d
