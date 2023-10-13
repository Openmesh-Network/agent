#!/bin/bash

export HOME=/root
export PRODUCT_NAME=openmesh
export BUILD_DIR=$HOME/$PRODUCT_NAME-install

apt-get install -y knockd

PUBLIC_IP=$(curl -s http://metadata.platformequinix.com/metadata | jq -r '.network.addresses[] | select(.public == true) | select(.management == true) | select(.address_family == 4) | .address')
PRIVATE_IP=$(curl -s http://metadata.platformequinix.com/metadata | jq -r '.network.addresses[] | select(.public == false) | select(.management == true) | select(.address_family == 4) | .address')
NETWORK=$(curl -s http://metadata.platformequinix.com/metadata | jq -r '.network.addresses[] | select(.public == false) | select(.management == true) | select(.address_family == 4) | .parent_block.network')
CIDR=$(curl -s http://metadata.platformequinix.com/metadata | jq -r '.network.addresses[] | select(.public == false) | select(.management == true) | select(.address_family == 4) | .parent_block.cidr')

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

cat << EOF > /etc/network/if-up.d/fw
#!/bin/sh

/sbin/iptables -A INPUT -i lo -j ACCEPT
/sbin/iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 
/sbin/iptables -A INPUT -p icmp -j ACCEPT
/sbin/iptables -A INPUT -p tcp --dport 179 -j ACCEPT
/sbin/iptables -A INPUT -p tcp --dport 5473 -j ACCEPT
/sbin/iptables -A INPUT -s $NETWORK/$CIDR -p tcp --dport 10250 -j ACCEPT
/sbin/iptables -A INPUT -s $NETWORK/$CIDR -p tcp --dport 10256 -j ACCEPT
/sbin/iptables -A INPUT -s $NETWORK/$CIDR -p tcp --dport 6443 -j ACCEPT
/sbin/iptables -A INPUT -s $NETWORK/$CIDR -p tcp --dport 9100 -j ACCEPT
/sbin/iptables -A INPUT -s $NETWORK/$CIDR -p tcp --dport 7472 -j ACCEPT
/sbin/iptables -P INPUT DROP
EOF
chmod +x /etc/network/if-up.d/fw

systemctl enable knockd && \
  systemctl restart knockd && \
  /etc/network/if-up.d/fw

rm -rf $BUILD_DIR
