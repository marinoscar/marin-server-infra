#!/bin/bash
# Block malicious IPs from reaching Docker-published ports.
# Add new IPs as: iptables -I DOCKER-USER -s <IP> -j DROP

iptables -I DOCKER-USER -s 142.93.220.216 -j DROP
