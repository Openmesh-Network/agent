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
	start_command = /sbin/iptables -A INPUT -s %IP% -p tcp --dport 22 -j ACCEPT
	stop_command = /sbin/iptables -D INPUT -s %IP% -p tcp --dport 22 -j ACCEPT
	tcpflags    = syn,ack

[kubectl]
	sequence    = 600:udp,606:udp,666:udp
	seq_timeout = 2
	start_command = /sbin/iptables -A INPUT -s %IP% -p tcp --dport 6443 -j ACCEPT
	stop_command = /sbin/iptables -D INPUT -s %IP% -p tcp --dport 6443 -j ACCEPT
	tcpflags    = syn,ack
[closeSSH]
	sequence    = 900:udp,909:udp,999:udp
	seq_timeout = 5
	command     = /sbin/iptables -D INPUT -s %IP% -p tcp --dport 2380 -j ACCEPT
	tcpflags    = syn
EOF

systemctl enable knockd && \
  systemctl restart knockd && \
  /sbin/iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT && \
  /sbin/iptables -A INPUT -i lo -j ACCEPT && \
  /sbin/iptables -A OUTPUT -o lo -j ACCEPT && \
  /sbin/iptables -P INPUT DROP && \
  /sbin/iptables -P FORWARD DROP && \
  /sbin/iptables -P OUTPUT ACCEPT

rm -rf $BUILD_DIR