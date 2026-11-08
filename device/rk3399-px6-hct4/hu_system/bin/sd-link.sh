#!/system/bin/sh

#############################################
CHANNEL=hengchangtong
EXE_PATH=/system/bin/
#############################################

echo "86364000">/proc/sys/net/core/rmem_max
echo '1' > /config/usb_gadget/g1/configs/b.1/MaxPower

mkdir /config/usb_gadget/g1/functions/iap.gs0
mkdir /config/usb_gadget/g1/functions/ncm.gs1

export LD_LIBRARY_PATH=/data/data/com.suding.speedplay/lib

$EXE_PATH/sd_mdnsd&

while true;do
	setprop sys.suding.speedplay.apk com.suding.speedplay
	if [ -f /data/data/com.suding.speedplay/lib/libspeedplay.so ]; then
		$EXE_PATH/sd_carplay -c $CHANNEL
	fi
	sleep 1
done
