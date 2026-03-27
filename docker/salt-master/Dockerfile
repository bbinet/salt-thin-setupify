FROM debian:bullseye

LABEL maintainer="Bruno Binet <bruno.binet@helioslite.com>"

ENV container=docker
ENV DEBIAN_FRONTEND=noninteractive

# Locale setup
RUN apt-get update && \
    apt-get install -y --no-install-recommends locales && \
    rm -rf /var/lib/apt/lists/* && \
    localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG=en_US.utf8

# Install system packages (without salt — installed via pip below)
RUN apt-get update && apt-get install -yq --no-install-recommends \
    systemd systemd-sysv dbus \
    vim less net-tools procps lsb-release git patch \
    openssh-client make gnupg curl sudo \
    python3-apt python3-git python3-openssl \
    python3-pip python3-setuptools python3-wheel python3-venv \
    python3-zmq python3-msgpack python3-jinja2 python3-yaml \
    python3-markupsafe python3-certifi python3-dateutil \
    python3-requests python3-tornado python3-distro \
    expect \
    && rm -rf /var/lib/apt/lists/*

# Install Salt 3003 and dependencies via pip
RUN pip3 install --no-cache-dir \
        salt==3003 \
        CherryPy \
        https://github.com/salt-formulas/reclass/archive/v1.7.0.zip

# Dirty fix issue https://github.com/saltstack/salt/issues/59990
# (reverting: https://github.com/saltstack/salt/pull/59866)
COPY salt_v3003_master_tops.patch /tmp/salt_v3003_master_tops.patch
RUN patch /usr/local/lib/python3.9/dist-packages/salt/master.py /tmp/salt_v3003_master_tops.patch

# Create salt systemd service (since we installed via pip, no service file is provided)
RUN cat <<'EOF' > /etc/systemd/system/salt-master.service
[Unit]
Description=The Salt Master Server
Documentation=man:salt-master(1) file:///usr/share/doc/salt/html/contents.html https://docs.saltproject.io/en/latest/contents.html
After=network.target

[Service]
Type=notify
NotifyAccess=all
LimitNOFILE=100000
ExecStart=/usr/local/bin/salt-master
WatchdogSec=60

[Install]
WantedBy=multi-user.target
EOF

RUN cat <<'EOF' > /etc/systemd/system/salt-api.service
[Unit]
Description=The Salt API
Documentation=man:salt-api(1) file:///usr/share/doc/salt/html/contents.html https://docs.saltproject.io/en/latest/contents.html
After=network.target salt-master.service

[Service]
Type=simple
LimitNOFILE=100000
ExecStart=/usr/local/bin/salt-api

[Install]
WantedBy=multi-user.target
EOF

RUN systemctl enable salt-master.service salt-api.service

# Set default target to multi-user (not graphical)
RUN systemctl set-default multi-user.target

# Mask unnecessary systemd services for container usage
RUN systemctl mask \
    dev-hugepages.mount \
    sys-fs-fuse-connections.mount \
    sys-kernel-config.mount \
    display-manager.service \
    getty@.service \
    systemd-logind.service \
    systemd-remount-fs.service \
    getty.target \
    graphical.target

# Fix dbus OOMScoreAdjust (not allowed in containers)
RUN cp /lib/systemd/system/dbus.service /etc/systemd/system/; \
    sed -i 's/OOMScoreAdjust=.*//' /etc/systemd/system/dbus.service

# Install entrypoint and service files
COPY entry.sh /usr/bin/entry.sh
RUN chmod +x /usr/bin/entry.sh
COPY resin.service /etc/systemd/system/resin.service
RUN systemctl enable /etc/systemd/system/resin.service

COPY override.conf /etc/systemd/system/salt-master.service.d/override.conf
COPY pre-salt-master.sh /usr/local/bin/pre-salt-master.sh
RUN chmod +x /usr/local/bin/pre-salt-master.sh

# Molten web UI
ENV MOLTEN_VERSION=0.3.2
ENV MOLTEN_MD5=4bce824944e6a2f5d09d703af53d596d
ADD https://github.com/martinhoefling/molten/releases/download/v${MOLTEN_VERSION}/molten-${MOLTEN_VERSION}.tar.gz molten-${MOLTEN_VERSION}.tar.gz
RUN echo "${MOLTEN_MD5}  molten-${MOLTEN_VERSION}.tar.gz" | md5sum --check && \
    mkdir -p /opt/molten && tar -xf molten-${MOLTEN_VERSION}.tar.gz -C /opt/molten --strip-components=1 && \
    rm -f molten-${MOLTEN_VERSION}.tar.gz

# salt-master, salt-api
EXPOSE 4505 4506 443 8000

ENV BEFORE_EXEC_SCRIPT=/etc/salt/before-exec.sh

STOPSIGNAL 37
ENTRYPOINT ["/usr/bin/entry.sh"]
CMD ["/bin/date"]
