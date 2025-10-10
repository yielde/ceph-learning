if [ -e /data200/ceph-16.2.15-0-g618f4408920/build ];then
	rm -rf /data200/ceph-16.2.15-0-g618f4408920/build/out/*
	rm -rf /data200/ceph-16.2.15-0-g618f4408920/build/dev/*
else
	rm -rf /data/ceph-learning/build/out/*
	rm -rf /data/ceph-learning/build/dev/*
fi
