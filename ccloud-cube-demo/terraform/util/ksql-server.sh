#!/bin/bash

########### Update and Install ###########

yum update -y
yum install wget -y
yum install unzip -y
yum install java-1.8.0-openjdk-devel.x86_64 -y
yum install git -y
yum install maven -y

########### Initial Bootstrap ###########

cd /tmp
curl -O ${confluent_platform_location}
unzip confluent-5.1.0-2.11.zip
mkdir /etc/confluent
mv confluent-5.1.0 /etc/confluent
mkdir /etc/confluent/confluent-5.1.0/data

############ Jaeger Tracing #############

cd /tmp
git clone https://github.com/riferrei/jaeger-tracing-support.git
cd jaeger-tracing-support
mvn clean
mvn compile
mvn install
cd target
cp jaeger-tracing-support-1.0.jar /etc/confluent/confluent-5.1.0/share/java/monitoring-interceptors

cd /tmp
curl -O https://riferrei.net/wp-content/uploads/2019/03/dependencies.zip
unzip dependencies.zip
cp *.jar /etc/confluent/confluent-5.1.0/share/java/monitoring-interceptors
cp kafka-rest-run-class ksql-run-class /etc/confluent/confluent-5.1.0/bin

cd /tmp
wget ${jaeger_tracing_location}
tar -xvzf jaeger-1.10.0-linux-amd64.tar.gz
mkdir /etc/jaeger
mv jaeger-1.10.0-linux-amd64 /etc/jaeger

cat > /etc/jaeger/jaeger-1.10.0-linux-amd64/jaeger-agent.yaml <<- "EOF"
reporter:
  type: tchannel
  tchannel:
    host-port: ${jaeger_collector}
EOF

########### Generating Props File ###########

cd /etc/confluent/confluent-5.1.0/etc/ksql

cat > ksql-server-ccloud.properties <<- "EOF"
${ksql_server_properties}
EOF

cat > interceptorsConfig.json <<- "EOF"
{
   "services":[
      {
         "service":"KSQL Server",
         "config":{
            "sampler":{
               "type" : "const",
               "param" : 1
            },
            "reporter":{
               "logSpans":true
            }
         },
         "topics":[
            "_EVENTS",
            "EVENTS",
            "EVENTS_ENRICHED",
            "SELECTED_WINNERS"
         ]
      }
   ]
}
EOF

########### Creating the Service ############

cat > /lib/systemd/system/jaeger-agent.service <<- "EOF"
[Unit]
Description=Jaeger Agent
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=1
ExecStart=/etc/jaeger/jaeger-1.10.0-linux-amd64/jaeger-agent --config-file=/etc/jaeger/jaeger-1.10.0-linux-amd64/jaeger-agent.yaml

[Install]
WantedBy=multi-user.target
EOF

cat > /lib/systemd/system/ksql-server.service <<- "EOF"
[Unit]
Description=Confluent KSQL Server
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=1
ExecStart=/etc/confluent/confluent-5.1.0/bin/ksql-server-start /etc/confluent/confluent-5.1.0/etc/ksql/ksql-server-ccloud.properties
ExecStop=/etc/confluent/confluent-5.1.0/bin/ksql-server-stop /etc/confluent/confluent-5.1.0/etc/ksql/ksql-server-ccloud.properties

[Install]
WantedBy=multi-user.target
EOF

########### Enable and Start ###########

systemctl enable jaeger-agent
systemctl start jaeger-agent

KSQL_JVM_PERFORMANCE_OPTS=$KSQL_JVM_PERFORMANCE_OPTS -Dsun.net.maxDatagramSockets=1024
systemctl enable ksql-server
systemctl start ksql-server

############# Populate Data ############

bash -c 'while netstat -lnt | awk '$4 ~ /:8088/ {exit 1}'; do sleep 10; done'

bash -c '/etc/confluent/confluent-5.1.0/bin/kafka-console-producer --broker-list ${broker_list} --producer.config /etc/confluent/confluent-5.1.0/etc/ksql/ksql-server-ccloud.properties --topic _NUMBERS --property "parse.key=true" --property "key.separator=:" <<EOF
1:{"NUMBER" : 1, "X": 1, "Y" : 0, "Z" : 0}
2:{"NUMBER" : 2, "X": 1, "Y" : -90, "Z" : 1}
3:{"NUMBER" : 3, "X": -180, "Y" : 0, "Z" : 180}
4:{"NUMBER" : 4, "X": 1, "Y" : 90, "Z" : -1}
EOF'