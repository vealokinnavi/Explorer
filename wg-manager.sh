#!/bin/bash -e

APP=$(basename $0)
LOCKFILE="/tmp/$APP.lock"

trap "rm -f ${LOCKFILE}; exit" INT TERM EXIT
if ! ln -s $APP $LOCKFILE 2>/dev/null; then
    echo "ERROR: script LOCKED" >&2
    exit 15
fi

function usage {
  echo "Usage: $0 [<options>] [command [arg]]"
  echo "Options:"
  echo " -i : Init (Create server keys and configs)"
  echo " -c : Create new user"
  echo " -d : Delete user"
  echo " -L : Lock user"
  echo " -U : Unlock user"
  echo " -p : Print user config"
  echo " -q : Print user QR code"
  echo " -u <user> : User identifier (uniq field for vpn account)"
  echo " -s <server> : Server host for user connection"
  echo " -I : Interface (default auto)"
  echo " -h : Usage"
  exit 1
}

unset USER
umask 0077

HOME_DIR="/etc/wireguard"
SERVER_NAME="wg-server"
SERVER_IP_PREFIX="172.16.52"
SERVER_PORT=39547
SERVER_INTERFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

while getopts ":icdpqhLUu:I:s:" opt; do
  case $opt in
     i) INIT=1 ;;
     c) CREATE=1 ;;
     d) DELETE=1 ;;
     L) LOCK=1 ;;
     U) UNLOCK=1 ;;
     p) PRINT_USER_CONFIG=1 ;;
     q) PRINT_QR_CODE=1 ;;
     u) USER="$OPTARG" ;;
     I) SERVER_INTERFACE="$OPTARG" ;;
     h) usage ;;
     s) SERVER_ENDPOINT="$OPTARG" ;;
    \?) echo "Invalid option: -$OPTARG" ; exit 1 ;;
     :) echo "Option -$OPTARG requires an argument" ; exit 1 ;;
  esac
done

[ $# -lt 1 ] && usage

function reload_server {
    wg syncconf ${SERVER_NAME} <(wg-quick strip ${SERVER_NAME})
}

function get_new_ip {
    declare -A IP_EXISTS

    for IP in $(grep -i 'Address\s*=\s*' keys/*/*.conf | sed 's/\/[0-9]\+$//' | grep -Po '\d+$')
    do
        IP_EXISTS[$IP]=1
    done

    for IP in {2..255}
    do
        [ ${IP_EXISTS[$IP]} ] || break
    done

    if [ $IP -eq 255 ]; then
        echo "ERROR: can't determine new address" >&2
        exit 3
    fi

    echo "${SERVER_IP_PREFIX}.${IP}/32"
}

function add_user_to_server {
    if [ ! -f "keys/${USER}/public.key" ]; then
        echo "ERROR: User not exists" >&2
        exit 1
    fi

    local USER_PUB_KEY=$(cat "keys/${USER}/public.key")
    local USER_IP=$(grep -i Address "keys/${USER}/${USER}.conf" | sed 's/Address\s*=\s*//i; s/\/.*//')

    if grep "# BEGIN ${USER}$" "$SERVER_NAME.conf" >/dev/null ; then
        echo "User already exists"
        exit 0
    fi

cat <<EOF >> "$SERVER_NAME.conf"
# BEGIN ${USER}
[Peer]
PublicKey = ${USER_PUB_KEY}
AllowedIPs = ${USER_IP}
# END ${USER}
EOF

    ip -4 route add ${USER_IP}/32 dev ${SERVER_NAME} || true
}

function remove_user_from_server {
    sed -i "/# BEGIN ${USER}$/,/# END ${USER}$/d" "$SERVER_NAME.conf"
    if [ -f "keys/${USER}/${USER}.conf" ]; then
        local USER_IP=$(grep -i Address "keys/${USER}/${USER}.conf" | sed 's/Address\s*=\s*//i; s/\/.*//')
        ip -4 route del ${USER_IP}/32 dev ${SERVER_NAME} || true
    fi
}

function init {
    if [ -z "$SERVER_ENDPOINT" ]; then
        echo "ERROR: Server required" >&2
        exit 1
    fi

    if [ -z "$SERVER_INTERFACE" ]; then
        echo "ERROR: Can't determine server interface" >&2
        echo "DEBUG: 'ip route':"
        ip route
        exit 1
    fi

    echo "Interface: $SERVER_INTERFACE"

    mkdir -p "keys/${SERVER_NAME}"
    echo -n "$SERVER_ENDPOINT" > "keys/.server"

    if [ ! -f "keys/${SERVER_NAME}/private.key" ]; then
        wg genkey | tee "keys/${SERVER_NAME}/private.key" | wg pubkey > "keys/${SERVER_NAME}/public.key"
    fi

    if [ -f "$SERVER_NAME.conf" ]; then
        echo "Server already initialized"
        exit 0
    fi

    SERVER_PVT_KEY=$(cat "keys/$SERVER_NAME/private.key")

cat <<EOF > "$SERVER_NAME.conf"
[Interface]
Address = ${SERVER_IP_PREFIX}.1/32
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PVT_KEY}
PostUp = iptables -P FORWARD ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_INTERFACE} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_INTERFACE} -j MASQUERADE

EOF

    echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf
    sysctl -p

    systemctl enable wg-quick@${SERVER_NAME}
    wg-quick up ${SERVER_NAME} || true

    echo "Server initialized successfully"
    exit 0
}

function create {
    if [ -f "keys/${USER}/${USER}.conf" ]; then
        echo "WARNING: key ${USER}.conf already exists" >&2
        return 0
    fi

    SERVER_ENDPOINT=$(cat "keys/.server")
    USER_IP=$( get_new_ip )

    mkdir "keys/${USER}"
    wg genkey | tee "keys/${USER}/private.key" | wg pubkey > "keys/${USER}/public.key"

    USER_PVT_KEY=$(cat "keys/${USER}/private.key")
    USER_PUB_KEY=$(cat "keys/${USER}/public.key")
    SERVER_PUB_KEY=$(cat "keys/$SERVER_NAME/public.key")

cat <<EOF > "keys/${USER}/${USER}.conf"
[Interface]
Address = ${USER_IP}
PrivateKey = ${USER_PVT_KEY}
DNS = 8.8.8.8,77.88.8.8,8.8.4.4,77.88.8.1,1.1.1.1

[Peer]
PublicKey = ${SERVER_PUB_KEY}
Endpoint = ${SERVER_ENDPOINT}:${SERVER_PORT}
PersistentKeepalive = 25
AllowedIPs = 0.0.0.0/0
EOF

    add_user_to_server
    reload_server
}

cd $HOME_DIR

if [ $INIT ]; then
    init
    exit 0;
fi

if [ ! -f "keys/$SERVER_NAME/public.key" ]; then
    echo "ERROR: Run init script before" >&2
    exit 2
fi

if [ -z "${USER}" ]; then
    echo "ERROR: User required" >&2
    exit 1
fi

if [ $CREATE ]; then
    create
fi

if [ $DELETE ]; then
    remove_user_from_server
    reload_server
    rm -rf "keys/${USER}"
    exit 0
fi

if [ $LOCK ]; then
    remove_user_from_server
    reload_server
    exit 0
fi

if [ $UNLOCK ]; then
    add_user_to_server
    reload_server
    exit 0
fi

if [ $PRINT_USER_CONFIG ]; then
    cat "keys/${USER}/${USER}.conf"
elif [ $PRINT_QR_CODE ]; then
    qrencode -t ansiutf8 < "keys/${USER}/${USER}.conf"
fi

exit 0
