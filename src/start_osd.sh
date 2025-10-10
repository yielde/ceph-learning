#!/bin/bash

for i in `ps aux|grep "ceph-osd -i"|grep -v color|awk '{print $2}'`;do kill -9 $i;done
ps aux|grep "ceph-osd -i"|grep -v color|awk '{print $2}'

sleep 5

if [ -d /data200/ceph-16.2.15-0-g618f4408920/build ];then
	/data200/ceph-16.2.15-0-g618f4408920/build/bin/ceph-osd -i 0 -c /data200/ceph-16.2.15-0-g618f4408920/build/ceph.conf
	/data200/ceph-16.2.15-0-g618f4408920/build/bin/ceph-osd -i 1 -c /data200/ceph-16.2.15-0-g618f4408920/build/ceph.conf
else
	/data/ceph-learning/build/bin/ceph-osd -i 0 -c /data/ceph-learning/build/ceph.conf
	/data/ceph-learning/build/bin/ceph-osd -i 1 -c /data/ceph-learning/build/ceph.conf
fi
