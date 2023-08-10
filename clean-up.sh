#!/bin/bash

export HOME=/root
export BUILD_DIR=$HOME/l3a

apt-get install -y knockd
cat << EOF > /etc/knockd.conf
[options]
  UseSyslog
  Interface = bond0

[openSSH]
  sequence    = 700:udp,707:udp,777:udp
  seq_timeout = 2
  start_command = /sbin/iptables -I INPUT -s %IP% -p tcp --dport 22 -j ACCEPT
  stop_command = /sbin/iptables -D INPUT -s %IP% -p tcp --dport 22 -j ACCEPT
  tcpflags    = syn,ack

[kubectl]
  sequence    = 600:udp,606:udp,666:udp
  seq_timeout = 2
  start_command = /sbin/iptables -I INPUT -s %IP% -p tcp --dport 6443 -j ACCEPT
  stop_command = /sbin/iptables -D INPUT -s %IP% -p tcp --dport 6443 -j ACCEPT
  cmd_timeout = 600
  tcpflags    = syn,ack

[closeSSH]
  sequence    = 900:udp,909:udp,999:udp
  seq_timeout = 5
  command     = /sbin/iptables -D INPUT -s %IP% -p tcp --dport 22 -j ACCEPT
  tcpflags    = syn
EOF

systemctl enable knockd && \
  systemctl restart knockd && \
  /sbin/iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT && \
  /sbin/iptables -A INPUT -i bond0 -p tcp --dport 22 -j DROP && \
  /sbin/iptables -P OUTPUT ACCEPT

rm -rf $BUILD_DIR
