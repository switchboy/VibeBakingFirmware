#!/system/bin/sh

export TOP_PID=$$
trap 'exit 1' TERM

exit_script(){
    kill -s TERM $TOP_PID
}

check_exit(){
	HCT_NAT=$(getprop hct.nat.state)
	if [ $HCT_NAT == "0" ];then
		echo "need close nat function..."
		ndc netd 6001 tether stop
		busybox ifconfig eth0 down
		sleep 1
		busybox ifconfig eth0 up
		exit_script
	fi
}

init_state=0

ppp_mode(){
	while [ -z "`busybox ifconfig |grep ppp0`" ];do
		echo "ppp0 is down,then wait ..."
		check_exit
		sleep 1
	done

	if [ -z "`busybox ifconfig wlan0|grep "inet addr"`" ];then
		sleep 0.1
	else			
		echo "wlan0 is online,then shut it ..."
		wifi_state=1
		svc wifi disable
	fi
	
	while [ -z "`busybox ifconfig ppp0|grep "inet addr"`" ];do
			echo "ppp0 is offline,then wait ..."
			check_exit
			busybox ifconfig eth0 down
			sleep 1
	done

	while [ -z "`getprop net.dns1`" ];do
			echo "net.dns1 is null,then wait ..."
			check_exit
			busybox ifconfig eth0 down
			sleep 1
	done
				
	while [ -z "`busybox ifconfig |grep eth0`"  ];do
			echo "eth0 is off,then go to up"
			check_exit
			busybox ifconfig eth0 up
			sleep 1
	done

	while [ -z "`busybox ifconfig eth0|grep "inet addr"`" ];do
			echo "eth0 is offline,then wait.."
			check_exit
			busybox ifconfig eth0 192.168.43.1
			sleep 1
	done
	if [ $init_state == 0 ];then
		init_state=1
		echo "need open set nat..."
		ndc tether start 192.168.43.2 192.168.43.254
		echo 1 > /proc/sys/net/ipv4/ip_forward
		ndc nat enable eth0 ppp0 1 192.168.43.1/24
		ip rule add from all lookup main pref 9999
		SYSTEM_DNS=$(getprop net.dns1)
		iptables -t nat -I PREROUTING -i eth0  -p udp --dport 53 -j DNAT --to-destination $SYSTEM_DNS
	fi
}

WLAN_GATEWAY="NONE"

wlan_mode(){

	if [ -z "`busybox ifconfig |grep wlan0`" ];then
		echo "wlan0 is offline ,then open ..."
		svc wifi open
		sleep 1
	fi
	
	while [ -z "`busybox ifconfig wlan0|grep "inet addr"`" ];do
		echo "wlan0 is offline,then wait ..."
		check_exit
		busybox ifconfig eth0 down
		sleep 1
	done
	
	if [ $WLAN_GATEWAY == "NONE" ]; then
		WLAN_GATEWAY=$(ip route list table 0 | grep via | awk '{print $3;}')
	fi
	
	while [ -z "`getprop net.dns1`" ];do
			echo "net.dns1 is null,then wait ..."
			check_exit
			busybox ifconfig eth0 down
			sleep 1
	done
					
	while [ -z "`busybox ifconfig |grep eth0`"  ];do
			echo "eth0 is off,then go to up"
			check_exit
			busybox ifconfig eth0 up
			sleep 1
	done
	
	while [ -z "`busybox ifconfig eth0|grep "inet addr"`" ];do
			echo "eth0 is offline,then wait.."
			check_exit
			busybox ifconfig eth0 192.168.43.1
			sleep 1
	done
		
	if [ $init_state == 0 ];then
		init_state=1
		echo "need open set nat..."
		ndc tether start 192.168.43.2 192.168.43.254
		echo 1 > /proc/sys/net/ipv4/ip_forward			
		ndc nat enable eth0 wlan0 1 192.168.43.1/24
		ip rule add from all lookup main pref 9999
		ip route add default via $WLAN_GATEWAY dev wlan0 proto static
		
		SYSTEM_DNS=$(getprop net.dns1)
		iptables -t nat -I PREROUTING -i eth0  -p udp --dport 53 -j DNAT --to-destination $SYSTEM_DNS
	fi	
}

exit_mode(){
	echo "need close nat function..."
	SYSTEM_DNS=$(getprop net.dns1)
	iptables -t nat -D PREROUTING -i eth0  -p udp --dport 53 -j DNAT --to-destination $SYSTEM_DNS
	ip rule del from all lookup main pref 9999
	echo 0 > /proc/sys/net/ipv4/ip_forward
	check_exit
}

sleep 1

while :
do
	HCT_NAT=$(getprop hct.nat.state)
	if [ $HCT_NAT == "1" ];then
		ppp_mode
	elif [ $HCT_NAT == "2" ];then
		wlan_mode
	else
		exit_mode
	fi
done




