#!/system/bin/sh
sdate=$(date "+%Y-%m-%d-%H:%M:%S.txt")
apath='/mnt/sdcard/android'
kpath='/mnt/sdcard/kernel'
temp=$apath+$sdate
temp2=$kpath+$sdate
logcat > $temp &
dmesg > $temp2
cat /proc/kmsg >> $temp2 &
