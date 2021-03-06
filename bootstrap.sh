#!/usr/bin/env bash

set -ex

bootstrap=$0
bootstrap_dir=$(dirname $bootstrap)
fqdn=$(hostname --fqdn)
workdir=$(mktemp -d)

slimta_edge_instance=${SLIMTA_EDGE_INSTANCE:-edge}
slimta_relay_instance=${SLIMTA_RELAY_INSTANCE:-relay}
pymap_instance=${PYMAP_INSTANCE:-default}

trap "rm -rf $workdir" EXIT INT

function setup_user {
	useradd -M -d /nonexistent -s /bin/false -G mail slimta || :
	passwd -l slimta
}

function setup_python {
	if ! dpkg -s python3.8 > /dev/null; then
		apt-get update
		apt-get install -y \
			python3.8 \
			python3.8-dev \
			python3.8-venv \
			python3-wheel
	fi
	if ! dpkg -s python2.7 > /dev/null; then
		apt-get update
		apt-get install -y \
			python2.7
	fi
}

function setup_redis {
	if ! dpkg -s redis-server > /dev/null; then
		apt-get update
		apt-get install -y \
			redis-server \
			redis-tools
	fi
	systemctl start redis-server
	systemctl enable redis-server
	if [ -d $workdir/json ]; then
		for json in $workdir/json/*.json; do
			key=$(basename $json .json)
			cat $json | redis-cli -x set $key
		done
	fi
}

function setup_letsencrypt {
	dehydrated_url=https://raw.githubusercontent.com/lukas2511/dehydrated/585ed5404bd8a89002ea9f250a24f075ddd52d6f/dehydrated
	if ! dpkg -s curl > /dev/null; then
		apt-get update
		apt-get install -y \
			curl
	fi
	if ! /opt/letsencrypt/bin/python -V; then
		python3.8 -m venv /opt/letsencrypt
	fi
	/opt/letsencrypt/bin/pip install -U pip wheel setuptools dns-lexicon
	cp -u $bootstrap_dir/etc/letsencrypt/letsencrypt-cron /opt/letsencrypt/bin/
	cp -u $bootstrap_dir/etc/letsencrypt/lexicon-hook.sh /opt/letsencrypt/bin/
	curl -o /opt/letsencrypt/bin/dehydrated $dehydrated_url
	chmod +x /opt/letsencrypt/bin/dehydrated
	mkdir -p /opt/letsencrypt/etc
	if [ -d $workdir/certs ]; then
		cp -f $workdir/certs/lexicon-secrets.sh /opt/letsencrypt/etc/
		cp -af $workdir/certs/$fqdn/ /etc/ssl/certs/
	fi
	chown root:root /opt/letsencrypt/etc/lexicon-secrets.sh
	chown root:root /etc/ssl/certs/$fqdn/
	chmod og-rwx /opt/letsencrypt/etc/lexicon-secrets.sh
	chmod og-rwx /etc/ssl/certs/$fqdn/
	/opt/letsencrypt/bin/letsencrypt-cron
	ln -sf /etc/ssl/certs/$fqdn/ /etc/ssl/certs/local
	ln -sf /opt/letsencrypt/bin/letsencrypt-cron /etc/cron.daily/letsencrypt
}

function setup_spamassassin {
	if ! dpkg -s spamassassin > /dev/null; then
		apt-get update
		apt-get install -y \
			spamassassin
	fi
	systemctl start spamassassin
	systemctl enable spamassassin
}

function setup_slimta {
	if ! /opt/slimta/bin/python -V; then
		python3.8 -m venv /opt/slimta
	fi
	/opt/slimta/bin/pip install -U pip wheel setuptools \
		git+https://github.com/slimta/python-slimta.git@master \
		git+https://github.com/slimta/python-slimta-spf.git@master \
		git+https://github.com/slimta/python-slimta-redisstorage.git@master \
		git+https://github.com/slimta/slimta.git@master
		# python-slimta \
		# python-slimta-spf \
		# python-slimta-redisstorage \
		# slimta
	mkdir -p /etc/slimta
	mkdir -p /var/log/slimta
	cp -f $bootstrap_dir/etc/slimta/slimta@.service /etc/systemd/system/
	cp -f $bootstrap_dir/etc/slimta/slimta.logrotate /etc/logrotate.d/slimta
	cp -f $bootstrap_dir/etc/slimta/slimta-relay /etc/default/
	cp -f $bootstrap_dir/etc/slimta/*.yaml /etc/slimta/
	systemctl daemon-reload
	systemctl start slimta@$slimta_edge_instance
	systemctl start slimta@$slimta_relay_instance
	systemctl enable slimta@$slimta_edge_instance
	systemctl enable slimta@$slimta_relay_instance
}

function setup_pymap {
	if ! dpkg -s libsystemd-dev > /dev/null; then
		apt-get update
		apt-get install -y \
			gcc \
			pkg-config \
			libsystemd-dev
	fi
	venv_dir=/opt/pymap-$pymap_instance
	if ! $venv_dir/bin/python -V; then
		python3.8 -m venv $venv_dir
	fi
	$venv_dir/bin/pip install -U pip wheel setuptools \
		hiredis \
		passlib \
		systemd-python \
		'pymap[redis,sieve,grpc]'
	cp -f $bootstrap_dir/etc/pymap/pymap@.service /etc/systemd/system/
	cp -f $bootstrap_dir/etc/pymap/pymap@.socket /etc/systemd/system/
	cp -f $bootstrap_dir/etc/pymap/pymap-defaults /etc/default/pymap
	cp -f $bootstrap_dir/etc/pymap/pymap.args /etc/
	rm -f /opt/pymap
	ln -s $venv_dir /opt/pymap
	systemctl daemon-reload
	systemctl start pymap@$pymap_instance
	if [ "$pymap_instance" = "default" ]; then
		systemctl enable pymap@$pymap_instance
	fi
}

if [ "$(id -u)" != "0" ]; then
	>&2 echo "usage: sudo $bootstrap [<backup-tar>]"
	exit 1
fi

if [ -n "$1" ]; then
	tar xf $1 -C $workdir
fi

declare -a actions=(
	setup_user
	setup_python
	setup_redis
	setup_letsencrypt
	setup_spamassassin
	setup_slimta
	setup_pymap
)

for act in "${actions[@]}"; do
	$act
done

systemctl restart slimta@$slimta_edge_instance
systemctl restart slimta@$slimta_relay_instance
systemctl restart pymap@$pymap_instance
