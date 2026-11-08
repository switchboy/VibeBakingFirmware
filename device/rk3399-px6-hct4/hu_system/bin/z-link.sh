#!/system/bin/sh

#############################################
CHANNEL=hengchangtong
EXE_PATH=/system/bin/
#############################################

echo "86364000">/proc/sys/net/core/rmem_max
echo '1' > /config/usb_gadget/g1/configs/b.1/MaxPower

mkdir /config/usb_gadget/g1/functions/iap.gs0
mkdir /config/usb_gadget/g1/functions/ncm.gs1

#export LD_LIBRARY_PATH=/data/data/com.zjinnova.zlink/lib

if  command -v busybox > /dev/null; then
	echo "busybox md5sum is found"
	busybox md5sum $EXE_PATH/z-link > /dev/z-md5.txt
	busybox md5sum $EXE_PATH/z-mdnsd >> /dev/z-md5.txt
	busybox chmod 777 /dev/z-md5.txt
else
	if  command -v md5sum > /dev/null; then
		echo "md5sum is found"
		md5sum $EXE_PATH/z-link > /dev/z-md5.txt
		md5sum $EXE_PATH/z-mdnsd >> /dev/z-md5.txt
		chmod 777 /dev/z-md5.txt
	fi
fi

while true;do
#	ps -fe|grep z-mdnsd |grep -v grep
#	if [ $? -ne 0 ];then
		setprop rw.zlink.loader.version 2.0
		export LD_LIBRARY_PATH=/data/data/com.zjinnova.zlink/lib
		echo "start z-link....."
		$EXE_PATH/z-mdnsd&
		$EXE_PATH/z-link -c $CHANNEL
		sleep 1
#	else
#		break
#	fi
done


