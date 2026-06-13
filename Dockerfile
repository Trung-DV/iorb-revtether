FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    dnsmasq ethtool iproute2 iptables kmod procps tcpdump \
    python3 python3-usb usbutils \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh usb_setup.py /
RUN chmod +x /entrypoint.sh /usb_setup.py

ENTRYPOINT ["/entrypoint.sh"]
