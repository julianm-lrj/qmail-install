#!/bin/bash
# qmail Installation Script for Linux
# Installs netqmail-1.06 from source with daemontools and ucspi-tcp

set -euo pipefail

NETQMAIL_VERSION="1.06"
DAEMONTOOLS_VERSION="0.76"
UCSPI_TCP_VERSION="0.88"
SRC_DIR="/usr/local/src"
PKG_MANAGER=""
INIT_SYSTEM="none"
DISTRO_ID="unknown"
NOLOGIN_SHELL="/sbin/nologin"
APT_UPDATED=false

detect_distro_and_init() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
  fi

  if command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  else
    echo "ERROR: Unsupported package manager. Need one of: dnf, apt-get, apk"
    exit 1
  fi

  if command -v systemctl >/dev/null 2>&1; then
    INIT_SYSTEM="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYSTEM="openrc"
  fi
}

detect_nologin_shell() {
  if [ -x /sbin/nologin ]; then
    NOLOGIN_SHELL="/sbin/nologin"
  elif [ -x /usr/sbin/nologin ]; then
    NOLOGIN_SHELL="/usr/sbin/nologin"
  else
    NOLOGIN_SHELL="/bin/false"
  fi
}

install_packages() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi

  case "$PKG_MANAGER" in
    dnf)
      dnf install -y "$@"
      ;;
    apt)
      if [ "$APT_UPDATED" = false ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y
        APT_UPDATED=true
      fi
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    *)
      echo "ERROR: Unknown package manager '$PKG_MANAGER'"
      exit 1
      ;;
  esac
}

install_build_dependencies() {
  case "$PKG_MANAGER" in
    dnf)
      install_packages gcc make patch wget tar gzip perl procmail curl
      ;;
    apt)
      install_packages gcc make patch wget tar gzip perl procmail curl ca-certificates
      ;;
    apk)
      install_packages build-base patch wget tar gzip perl curl shadow ca-certificates
      install_packages procmail 2>/dev/null || true
      ;;
  esac
}

install_selinux_tooling_if_needed() {
  if [ "$SELINUX_ENABLED" != true ]; then
    return 0
  fi

  case "$PKG_MANAGER" in
    dnf)
      install_packages policycoreutils-python-utils checkpolicy
      ;;
    apt)
      install_packages policycoreutils selinux-utils checkpolicy 2>/dev/null || true
      install_packages policycoreutils-python-utils 2>/dev/null || true
      ;;
    apk)
      echo "SELinux tooling is not available via apk; policy module setup may be skipped"
      ;;
  esac
}

download_if_missing() {
  local output_file="$1"
  local primary_url="$2"
  local fallback_url="$3"
  local label="$4"

  if [ ! -f "$output_file" ]; then
    echo "Downloading $label..."
    wget "$primary_url" || wget "$fallback_url"
  fi
}

patch_errno_if_needed() {
  local file_path="$1"

  if [ -f "$file_path" ] && grep -q "extern int errno;" "$file_path"; then
    echo "Applying errno fix to $file_path..."
    sed -i 's/extern int errno;/#include <errno.h>/' "$file_path"
  fi
}

ensure_group() {
  local group_name="$1"
  local group_id="$2"

  if command -v groupadd >/dev/null 2>&1; then
    groupadd -g "$group_id" "$group_name" 2>/dev/null || true
    return
  fi

  if command -v addgroup >/dev/null 2>&1; then
    addgroup -g "$group_id" "$group_name" 2>/dev/null || \
    addgroup --gid "$group_id" "$group_name" 2>/dev/null || \
    addgroup "$group_name" 2>/dev/null || true
    return
  fi

  echo "ERROR: No supported group creation command found"
  exit 1
}

ensure_user() {
  local user_name="$1"
  local user_id="$2"
  local primary_group="$3"
  local home_dir="$4"

  if command -v useradd >/dev/null 2>&1; then
    useradd -u "$user_id" -g "$primary_group" -d "$home_dir" -s "$NOLOGIN_SHELL" "$user_name" 2>/dev/null || true
    return
  fi

  if command -v adduser >/dev/null 2>&1; then
    adduser -D -H -u "$user_id" -G "$primary_group" -h "$home_dir" -s "$NOLOGIN_SHELL" "$user_name" 2>/dev/null || \
    adduser --uid "$user_id" --ingroup "$primary_group" --home "$home_dir" --shell "$NOLOGIN_SHELL" --disabled-password --gecos "" "$user_name" 2>/dev/null || true
    return
  fi

  echo "ERROR: No supported user creation command found"
  exit 1
}

get_group_gid() {
  local group_name="$1"

  if command -v getent >/dev/null 2>&1; then
    getent group "$group_name" | cut -d: -f3
    return
  fi

  awk -F: -v g="$group_name" '$1 == g { print $3; exit }' /etc/group
}

expose_qmail_cli_tools_in_path() {
  local src_bin tool_name dest

  for src_bin in /var/qmail/bin/qmail-*; do
    [ -x "$src_bin" ] || continue
    tool_name="$(basename "$src_bin")"
    dest="/usr/bin/$tool_name"

    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      continue
    fi

    ln -sf "$src_bin" "$dest"
  done
}

set_fcontext_rule() {
  local pattern="$1"
  local selinux_type="$2"

  if ! semanage fcontext -a -t "$selinux_type" "$pattern" 2>/dev/null; then
    semanage fcontext -m -t "$selinux_type" "$pattern" 2>/dev/null || true
  fi
}

set_fcontext_link_rule() {
  local pattern="$1"
  local selinux_type="$2"

  if ! semanage fcontext -a -f l -t "$selinux_type" "$pattern" 2>/dev/null; then
    semanage fcontext -m -f l -t "$selinux_type" "$pattern" 2>/dev/null || true
  fi
}

get_qmail_split_count() {
  local split_file="$SRC_DIR/netqmail-${NETQMAIL_VERSION}/conf-split"
  local split_count="23"

  if [ -f "$split_file" ]; then
    local candidate
    candidate="$(tr -cd '0-9' < "$split_file")"
    if [ -n "$candidate" ] && [ "$candidate" -gt 0 ]; then
      split_count="$candidate"
    fi
  fi

  echo "$split_count"
}

ensure_qmail_split_dirs() {
  local parent_dir="$1"
  local split_count="$2"
  local owner_uid="$3"
  local group_gid="$4"
  local dir_mode="$5"
  local index child_dir

  mkdir -p "$parent_dir"
  chown "$owner_uid:$group_gid" "$parent_dir"
  chmod "$dir_mode" "$parent_dir"

  for ((index=0; index<split_count; index++)); do
    child_dir="$parent_dir/$index"
    if [ ! -d "$child_dir" ]; then
      mkdir -p "$child_dir"
    fi

    chown "$owner_uid:$group_gid" "$child_dir"
    chmod "$dir_mode" "$child_dir"
  done
}

remove_legacy_numeric_subdirs() {
  local parent_dir="$1"
  local split_count="$2"
  local index legacy_dir

  for ((index=0; index<split_count; index++)); do
    legacy_dir="$parent_dir/$index"
    if [ -d "$legacy_dir" ]; then
      rmdir "$legacy_dir" 2>/dev/null || rm -rf "$legacy_dir" 2>/dev/null || true
    fi
  done
}

ensure_qmail_queue_layout() {
  local split_count="$1"

  if [ ! -d /var/qmail/queue ]; then
    echo "ERROR: /var/qmail/queue not found after setup"
    exit 1
  fi

  chown "${QMAILQ_UID}:${QMAIL_GID}" /var/qmail/queue
  chmod 750 /var/qmail/queue

  mkdir -p /var/qmail/queue/pid /var/qmail/queue/intd /var/qmail/queue/todo /var/qmail/queue/bounce /var/qmail/queue/lock

  chown "${QMAILQ_UID}:${QMAIL_GID}" /var/qmail/queue/pid /var/qmail/queue/intd /var/qmail/queue/todo /var/qmail/queue/lock
  chown "${QMAILS_UID}:${QMAIL_GID}" /var/qmail/queue/bounce

  chmod 700 /var/qmail/queue/pid /var/qmail/queue/intd /var/qmail/queue/bounce
  chmod 750 /var/qmail/queue/todo /var/qmail/queue/lock

  remove_legacy_numeric_subdirs /var/qmail/queue/pid "$split_count"
  remove_legacy_numeric_subdirs /var/qmail/queue/intd "$split_count"
  remove_legacy_numeric_subdirs /var/qmail/queue/todo "$split_count"
  remove_legacy_numeric_subdirs /var/qmail/queue/bounce "$split_count"

  ensure_qmail_split_dirs /var/qmail/queue/mess "$split_count" "${QMAILQ_UID}" "${QMAIL_GID}" 750
  ensure_qmail_split_dirs /var/qmail/queue/info "$split_count" "${QMAILS_UID}" "${QMAIL_GID}" 700
  ensure_qmail_split_dirs /var/qmail/queue/local "$split_count" "${QMAILS_UID}" "${QMAIL_GID}" 700
  ensure_qmail_split_dirs /var/qmail/queue/remote "$split_count" "${QMAILS_UID}" "${QMAIL_GID}" 700
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This installer must be run as root"
    exit 1
  fi
}

require_root
detect_distro_and_init
detect_nologin_shell

SELINUX_MODE="Disabled"
if command -v getenforce >/dev/null 2>&1; then
  SELINUX_MODE="$(getenforce 2>/dev/null || echo Disabled)"
fi

SELINUX_ENABLED=false
if [ "$SELINUX_MODE" != "Disabled" ]; then
  SELINUX_ENABLED=true
fi

echo "=== Installing netqmail from source ==="
echo "Detected distro: $DISTRO_ID (pkg: $PKG_MANAGER, init: $INIT_SYSTEM)"
echo "SELinux mode detected: $SELINUX_MODE"

# Install build dependencies
install_build_dependencies

# Install SELinux policy toolchain only when SELinux is enabled
install_selinux_tooling_if_needed

# Create qmail users and groups
echo "Creating qmail users and groups..."
ensure_group nofiles 2107
ensure_group qmail 2108

ensure_user alias 7790 nofiles /var/qmail/alias
ensure_user qmaild 7791 nofiles /var/qmail
ensure_user qmaill 7792 nofiles /var/qmail
ensure_user qmailp 7793 nofiles /var/qmail
ensure_user qmailq 7794 qmail /var/qmail
ensure_user qmailr 7795 qmail /var/qmail
ensure_user qmails 7796 qmail /var/qmail

# Resolve UID/GID values for qmail paths and service runtime
ALIAS_UID="$(id -u alias)"
QMAILL_UID="$(id -u qmaill)"
QMAILS_UID="$(id -u qmails)"
QMAILQ_UID="$(id -u qmailq)"
QMAILR_UID="$(id -u qmailr)"
NOFILES_GID="$(get_group_gid nofiles)"
QMAIL_GID="$(get_group_gid qmail)"

if [ "$(id -g qmails)" != "$QMAIL_GID" ]; then
  echo "ERROR: qmails primary group does not match qmail group"
  id qmails || true
  exit 1
fi

# Download and compile netqmail
cd "$SRC_DIR"
download_if_missing "netqmail-${NETQMAIL_VERSION}.tar.gz" \
  "http://qmail.org/netqmail-${NETQMAIL_VERSION}.tar.gz" \
  "https://schmonz.com/qmail/netqmail-${NETQMAIL_VERSION}.tar.gz" \
  "netqmail-${NETQMAIL_VERSION}"

if [ ! -d "netqmail-${NETQMAIL_VERSION}" ]; then
  tar xzf "netqmail-${NETQMAIL_VERSION}.tar.gz"
fi

cd "netqmail-${NETQMAIL_VERSION}"
patch_errno_if_needed "error.h"

# Compile and install qmail
echo "Compiling netqmail..."
make setup check

# Configure qmail - use hostname if set, otherwise default
QMAIL_HOSTNAME="${QMAIL_HOSTNAME:-test.example.com}"
echo "Configuring qmail for $QMAIL_HOSTNAME..."
./config-fast "$QMAIL_HOSTNAME"

# Set up control files
cd /var/qmail/control
echo "$QMAIL_HOSTNAME" > me
echo "$QMAIL_HOSTNAME" > defaulthost
echo "$QMAIL_HOSTNAME" > plusdomain
cp me locals
cp me rcpthosts

# Create qmail aliases
echo "root" > /var/qmail/alias/.qmail-postmaster
echo "root" > /var/qmail/alias/.qmail-mailer-daemon
echo "root" > /var/qmail/alias/.qmail-root
chmod 644 /var/qmail/alias/.qmail-*

# Set qmail path ownership using numeric UID/GID
echo "Applying qmail path ownership using UID/GID..."
chown -R "${ALIAS_UID}:${NOFILES_GID}" /var/qmail/alias
chown -R "${QMAILQ_UID}:${QMAIL_GID}" /var/qmail/control

# Keep queue internals as created by qmail setup; only enforce top-level queue owner
# and qmail-send mutex directory ownership.
if [ -d /var/qmail/queue ]; then
  QMAIL_SPLIT_COUNT="$(get_qmail_split_count)"
  ensure_qmail_queue_layout "$QMAIL_SPLIT_COUNT"
  rm -f /var/qmail/queue/lock/sendmutex

  : > /var/qmail/queue/lock/sendmutex
  chown "${QMAILS_UID}:${QMAIL_GID}" /var/qmail/queue/lock/sendmutex 2>/dev/null || true
  chmod 600 /var/qmail/queue/lock/sendmutex 2>/dev/null || true

  if [ ! -e /var/qmail/queue/lock/tcpto ]; then
    truncate -s 1024 /var/qmail/queue/lock/tcpto 2>/dev/null || dd if=/dev/zero of=/var/qmail/queue/lock/tcpto bs=1024 count=1 2>/dev/null || true
  fi
  chown "${QMAILR_UID}:${QMAIL_GID}" /var/qmail/queue/lock/tcpto 2>/dev/null || true
  chmod 644 /var/qmail/queue/lock/tcpto 2>/dev/null || true

  if [ -e /var/qmail/queue/lock/trigger ] && [ ! -p /var/qmail/queue/lock/trigger ]; then
    rm -f /var/qmail/queue/lock/trigger
  fi
  if [ ! -p /var/qmail/queue/lock/trigger ]; then
    mkfifo /var/qmail/queue/lock/trigger 2>/dev/null || true
  fi
  chown "${QMAILS_UID}:${QMAIL_GID}" /var/qmail/queue/lock/trigger 2>/dev/null || true
  chmod 622 /var/qmail/queue/lock/trigger 2>/dev/null || true
fi

# Ensure qmail queue binary has privilege bits for UID/GID switching
# Note: 6644 is not suitable for alias files; setuid/setgid belongs on executables.
if [ -x /var/qmail/bin/qmail-queue ]; then
  chown "${QMAILQ_UID}:${QMAIL_GID}" /var/qmail/bin/qmail-queue
  chmod 4711 /var/qmail/bin/qmail-queue
fi

# Expose qmail CLI tools in /usr/bin so root and sudo can call them via PATH
echo "Linking qmail CLI tools into /usr/bin..."
expose_qmail_cli_tools_in_path

# Install daemontools
echo "Installing daemontools..."
cd "$SRC_DIR"
if [ ! -d "/package/admin/daemontools-${DAEMONTOOLS_VERSION}" ] && [ ! -d "/package/admin/daemontools" ]; then
  download_if_missing "daemontools-${DAEMONTOOLS_VERSION}.tar.gz" \
    "http://cr.yp.to/daemontools/daemontools-${DAEMONTOOLS_VERSION}.tar.gz" \
    "https://schmonz.com/software/daemontools/daemontools-${DAEMONTOOLS_VERSION}.tar.gz" \
    "daemontools-${DAEMONTOOLS_VERSION}"

  mkdir -p /package
  chmod 1755 /package
  cd /package
  tar xzf "$SRC_DIR/daemontools-${DAEMONTOOLS_VERSION}.tar.gz"
  cd "admin/daemontools-${DAEMONTOOLS_VERSION}"

  patch_errno_if_needed "src/error.h"
  package/install
fi

# Ensure daemontools command binaries are executable for systemd ExecStart
if [ -d "/package/admin/daemontools/command" ]; then
  chmod 755 /package/admin/daemontools/command/* 2>/dev/null || true
elif [ -d "/package/admin/daemontools-${DAEMONTOOLS_VERSION}/command" ]; then
  chmod 755 /package/admin/daemontools-${DAEMONTOOLS_VERSION}/command/* 2>/dev/null || true
fi
chmod 755 /command/svscanboot 2>/dev/null || true

# Install ucspi-tcp
echo "Installing ucspi-tcp..."
cd "$SRC_DIR"
if [ ! -d "ucspi-tcp-${UCSPI_TCP_VERSION}" ]; then
  download_if_missing "ucspi-tcp-${UCSPI_TCP_VERSION}.tar.gz" \
    "http://cr.yp.to/ucspi-tcp/ucspi-tcp-${UCSPI_TCP_VERSION}.tar.gz" \
    "https://schmonz.com/software/ucspi-tcp/ucspi-tcp-${UCSPI_TCP_VERSION}.tar.gz" \
    "ucspi-tcp-${UCSPI_TCP_VERSION}"

  tar xzf "ucspi-tcp-${UCSPI_TCP_VERSION}.tar.gz"
  cd "ucspi-tcp-${UCSPI_TCP_VERSION}"

  patch_errno_if_needed "error.h"
  make && make setup check
fi

# Create qmail rc script
cat > /var/qmail/rc << 'EOF'
#!/bin/sh
exec env - PATH="/var/qmail/bin:$PATH" \
qmail-start '|preline -f /usr/bin/procmail -o -a $LOGNAME -d $LOGNAME || /var/qmail/bin/qmail-lspawn ./Mailbox' \
splogger qmail
EOF
chmod 755 /var/qmail/rc

# Set up qmail service directories
echo "Setting up qmail supervision..."
mkdir -p /var/qmail/supervise/qmail-send/log
mkdir -p /var/qmail/supervise/qmail-smtpd/log
mkdir -p /var/log/qmail/smtpd
chown -R "${QMAILL_UID}:${NOFILES_GID}" /var/log/qmail

# qmail-send service run script
cat > /var/qmail/supervise/qmail-send/run << 'EOF'
#!/bin/sh
exec /var/qmail/rc
EOF
chmod 755 /var/qmail/supervise/qmail-send/run

# qmail-send log run script
cat > /var/qmail/supervise/qmail-send/log/run << 'EOF'
#!/bin/sh
exec /usr/local/bin/setuidgid qmaill /usr/local/bin/multilog t /var/log/qmail
EOF
chmod 755 /var/qmail/supervise/qmail-send/log/run

# qmail-smtpd service run script
cat > /var/qmail/supervise/qmail-smtpd/run << 'EOF'
#!/bin/sh
QMAILDUID=$(id -u qmaild)
QMAILDGID=$(id -g qmaild)
MAXSMTPD=$(cat /var/qmail/control/concurrencyincoming 2>/dev/null || echo 20)
LOCAL=$(head -1 /var/qmail/control/me)

if [ -z "$QMAILDUID" -o -z "$QMAILDGID" -o -z "$MAXSMTPD" -o -z "$LOCAL" ]; then
    echo "ERROR: Required variables not set"
    exit 1
fi

exec /usr/local/bin/softlimit -m 64000000 \
    /usr/local/bin/tcpserver -v -R -l "$LOCAL" -x /etc/tcp.smtp.cdb \
    -c "$MAXSMTPD" -u "$QMAILDUID" -g "$QMAILDGID" 0 smtp \
    /var/qmail/bin/qmail-smtpd 2>&1
EOF
chmod 755 /var/qmail/supervise/qmail-smtpd/run

# qmail-smtpd log run script
cat > /var/qmail/supervise/qmail-smtpd/log/run << 'EOF'
#!/bin/sh
exec /usr/local/bin/setuidgid qmaill /usr/local/bin/multilog t /var/log/qmail/smtpd
EOF
chmod 755 /var/qmail/supervise/qmail-smtpd/log/run

# Create TCP access rules for SMTP (allow relay from all - WARNING!)
echo "Configuring SMTP access rules..."
echo '127.0.0.1:allow,RELAYCLIENT=""' > /etc/tcp.smtp
echo ':allow,RELAYCLIENT=""' >> /etc/tcp.smtp
/usr/local/bin/tcprules /etc/tcp.smtp.cdb /etc/tcp.smtp.tmp < /etc/tcp.smtp
chmod 644 /etc/tcp.smtp*

# Install qmail-helper into PATH
echo "Installing qmail-helper..."
cat > /usr/local/bin/qmail-helper << 'EOFHELPER'
#!/bin/bash
set -euo pipefail

TCP_SMTP_FILE="/etc/tcp.smtp"
TCP_SMTP_CDB="/etc/tcp.smtp.cdb"
TCP_SMTP_TMP="/etc/tcp.smtp.tmp"
TCPRULES_BIN="/usr/local/bin/tcprules"

rebuild_tcp_rules() {
  if [ ! -x "$TCPRULES_BIN" ]; then
    echo "ERROR: tcprules not found at $TCPRULES_BIN"
    exit 1
  fi

  "$TCPRULES_BIN" "$TCP_SMTP_CDB" "$TCP_SMTP_TMP" < "$TCP_SMTP_FILE"
  chmod 644 "$TCP_SMTP_FILE" "$TCP_SMTP_CDB" "$TCP_SMTP_TMP"
}

set_relay_mode() {
  mode="${1:-}"

  case "$mode" in
    relay-localhost)
      cat > "$TCP_SMTP_FILE" << 'EOFRULES'
127.0.0.1:allow,RELAYCLIENT=""
:deny
EOFRULES
      rebuild_tcp_rules
      echo "Relay mode set to localhost-only"
      ;;
    relay-open)
      cat > "$TCP_SMTP_FILE" << 'EOFRULES'
127.0.0.1:allow,RELAYCLIENT=""
:allow,RELAYCLIENT=""
EOFRULES
      rebuild_tcp_rules
      echo "Relay mode set to open (WARNING: insecure)"
      ;;
    *)
      echo "ERROR: Unknown relay mode '$mode'"
      echo "Valid modes: relay-localhost, relay-open"
      exit 1
      ;;
  esac
}

show_status() {
  if grep -q '^:allow,RELAYCLIENT=""' "$TCP_SMTP_FILE" 2>/dev/null; then
    echo "Relay mode: open"
  elif grep -q '^:deny' "$TCP_SMTP_FILE" 2>/dev/null; then
    echo "Relay mode: localhost-only"
  else
    echo "Relay mode: custom"
  fi

  echo ""
  echo "Current rules ($TCP_SMTP_FILE):"
  cat "$TCP_SMTP_FILE"
}

smtp_test() {
  local recipient="${1:-postmaster@$(cat /var/qmail/control/me 2>/dev/null || echo localhost)}"
  local sender="${2:-test@$(cat /var/qmail/control/me 2>/dev/null || echo localhost)}"
  local smtp_target="smtp://127.0.0.1:25"

  if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required for smtp-test"
    exit 1
  fi

  printf 'From: %s\r\nTo: %s\r\nSubject: qmail-helper SMTP test\r\n\r\nTest message from qmail-helper at %s\r\n' \
    "$sender" "$recipient" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" \
  | curl --silent --show-error --url "$smtp_target" \
      --mail-from "$sender" --mail-rcpt "$recipient" --upload-file - --crlf

  echo "SMTP test submitted to $recipient via $smtp_target"
}

usage() {
  cat << 'EOFUSAGE'
Usage:
  qmail-helper config-set relay-localhost
  qmail-helper config-set relay-open
  qmail-helper status
  qmail-helper smtp-test [recipient] [sender]
EOFUSAGE
}

command="${1:-}"
case "$command" in
  config-set)
    set_relay_mode "${2:-}"
    ;;
  status)
    show_status
    ;;
  smtp-test)
    smtp_test "${2:-}" "${3:-}"
    ;;
  *)
    usage
    exit 1
    ;;
esac
EOFHELPER
chmod 755 /usr/local/bin/qmail-helper

# Ensure qmail-helper is available for root/sudo secure_path
if [ -e /usr/bin/qmail-helper ] && [ ! -L /usr/bin/qmail-helper ]; then
  echo "Skipping /usr/bin/qmail-helper link (non-symlink file exists)"
else
  ln -sf /usr/local/bin/qmail-helper /usr/bin/qmail-helper
fi

ln -sf /usr/local/bin/qmail-helper /usr/local/bin/qmail-helper.sh

# Configure svscan service for detected init system
SVSCANBOOT_PATH="/command/svscanboot"
if [ -x "/package/admin/daemontools-${DAEMONTOOLS_VERSION}/command/svscanboot" ]; then
  SVSCANBOOT_PATH="/package/admin/daemontools-${DAEMONTOOLS_VERSION}/command/svscanboot"
elif [ -x "/package/admin/daemontools/command/svscanboot" ]; then
  SVSCANBOOT_PATH="/package/admin/daemontools/command/svscanboot"
fi

if [ "$INIT_SYSTEM" = "systemd" ]; then
  cat > /etc/systemd/system/svscan.service << EOF
[Unit]
Description=Daemontools svscan
After=network.target

[Service]
Type=simple
ExecStart=$SVSCANBOOT_PATH
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
elif [ "$INIT_SYSTEM" = "openrc" ]; then
  cat > /etc/init.d/svscan << EOF
#!/sbin/openrc-run
description="Daemontools svscan"
command="$SVSCANBOOT_PATH"
command_background=true
pidfile="/run/svscan.pid"

depend() {
  need net
}
EOF
  chmod 755 /etc/init.d/svscan
else
  echo "No managed init system detected; svscan will be started in background"
fi

# Link qmail services to /service
mkdir -p /service
ln -sf /var/qmail/supervise/qmail-send /service/qmail-send
ln -sf /var/qmail/supervise/qmail-smtpd /service/qmail-smtpd

# Configure firewall
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-service=smtp 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
fi

# Configure SELinux policy for daemontools
SELINUX_POLICY_STATUS="Not configured (SELinux is $SELINUX_MODE)"
if [ "$SELINUX_ENABLED" = true ] && \
  command -v checkmodule >/dev/null 2>&1 && \
  command -v semodule_package >/dev/null 2>&1 && \
  command -v semodule >/dev/null 2>&1 && \
  command -v semanage >/dev/null 2>&1; then
  echo "Creating SELinux policy for daemontools..."
  
  cat > /tmp/qmail-daemontools.te << 'EOFPOLICY'
module qmail-daemontools 1.0;

require {
    type init_t;
    type default_t;
    class file { execute execute_no_trans map read open getattr };
}

# Allow init_t to map and execute daemontools binaries
allow init_t default_t:file { execute execute_no_trans map read open getattr };
EOFPOLICY
  
  checkmodule -M -m -o /tmp/qmail-daemontools.mod /tmp/qmail-daemontools.te
  semodule_package -o /tmp/qmail-daemontools.pp -m /tmp/qmail-daemontools.mod
  semodule -i /tmp/qmail-daemontools.pp
  
  # Set proper contexts
  set_fcontext_link_rule "/package/admin/daemontools" bin_t
  set_fcontext_rule "/package/admin/daemontools/command(/.*)?" bin_t
  set_fcontext_rule "/package/admin/daemontools-.*/command(/.*)?" bin_t
  set_fcontext_link_rule "/command/.*" bin_t
  set_fcontext_rule "/var/qmail/bin/.*" bin_t
  set_fcontext_rule "/usr/local/bin/.*" bin_t
  
  restorecon -h /package/admin/daemontools /command/* 2>/dev/null || true
  restorecon -Rv /package /command /var/qmail/bin /usr/local/bin 2>/dev/null || true
  
  rm -f /tmp/qmail-daemontools.*
  
  SELINUX_POLICY_STATUS="Custom policy installed (mode: $SELINUX_MODE)"
  echo "SELinux policy configured"
elif [ "$SELINUX_ENABLED" = true ]; then
  SELINUX_POLICY_STATUS="Skipped (SELinux enabled, policy tooling unavailable)"
fi

# Validate qmail-send queue write paths
if [ -d /var/qmail/queue/lock ] && [ -d /var/qmail/queue/info/0 ]; then
  LOCK_WRITE_OK=false
  INFO_WRITE_OK=false

  if command -v runuser >/dev/null 2>&1; then
    runuser -u qmails -- sh -c ': > /var/qmail/queue/lock/sendmutex' 2>/dev/null && LOCK_WRITE_OK=true
    runuser -u qmails -- sh -c ': > /var/qmail/queue/info/0/.permcheck && rm -f /var/qmail/queue/info/0/.permcheck' 2>/dev/null && INFO_WRITE_OK=true
  elif command -v su >/dev/null 2>&1; then
    su -s /bin/sh -c ': > /var/qmail/queue/lock/sendmutex' qmails 2>/dev/null && LOCK_WRITE_OK=true
    su -s /bin/sh -c ': > /var/qmail/queue/info/0/.permcheck && rm -f /var/qmail/queue/info/0/.permcheck' qmails 2>/dev/null && INFO_WRITE_OK=true
  fi

  if [ "$LOCK_WRITE_OK" != true ]; then
    echo "ERROR: qmails cannot write /var/qmail/queue/lock/sendmutex"
    ls -ldZ /var/qmail/queue /var/qmail/queue/lock 2>/dev/null || ls -ld /var/qmail/queue /var/qmail/queue/lock
    ls -lZ /var/qmail/queue/lock/sendmutex 2>/dev/null || ls -l /var/qmail/queue/lock/sendmutex 2>/dev/null || true
    exit 1
  fi

  if [ "$INFO_WRITE_OK" != true ]; then
    echo "ERROR: qmails cannot write /var/qmail/queue/info/0"
    ls -ldZ /var/qmail/queue/info /var/qmail/queue/info/0 2>/dev/null || ls -ld /var/qmail/queue/info /var/qmail/queue/info/0
    exit 1
  fi
fi

# Enable and start services
if [ "$INIT_SYSTEM" = "systemd" ]; then
  systemctl daemon-reload
  systemctl enable svscan
  systemctl start svscan
elif [ "$INIT_SYSTEM" = "openrc" ]; then
  rc-update add svscan default 2>/dev/null || true
  rc-service svscan start
else
  nohup "$SVSCANBOOT_PATH" >/var/log/svscan.log 2>&1 &
fi

# Wait for services to start
sleep 3

# Hard validation: qmail-queue must exist, be owned by qmailq:qmail, and keep setuid bit
if [ ! -e /var/qmail/bin/qmail-queue ]; then
  echo "ERROR: /var/qmail/bin/qmail-queue not found"
  exit 1
fi

CURRENT_QMAIL_QUEUE_MODE="$(stat -c '%a' /var/qmail/bin/qmail-queue)"
CURRENT_QMAIL_QUEUE_UID="$(stat -c '%u' /var/qmail/bin/qmail-queue)"
CURRENT_QMAIL_QUEUE_GID="$(stat -c '%g' /var/qmail/bin/qmail-queue)"
MODE_OCTAL=$((8#$CURRENT_QMAIL_QUEUE_MODE))

if (( (MODE_OCTAL & 04000) == 0 )); then
  echo "ERROR: /var/qmail/bin/qmail-queue is missing setuid bit (mode $CURRENT_QMAIL_QUEUE_MODE)"
  ls -l /var/qmail/bin/qmail-queue
  exit 1
fi

if [ "$CURRENT_QMAIL_QUEUE_UID" != "$QMAILQ_UID" ] || [ "$CURRENT_QMAIL_QUEUE_GID" != "$QMAIL_GID" ]; then
  echo "ERROR: /var/qmail/bin/qmail-queue ownership is ${CURRENT_QMAIL_QUEUE_UID}:${CURRENT_QMAIL_QUEUE_GID} (expected ${QMAILQ_UID}:${QMAIL_GID})"
  ls -l /var/qmail/bin/qmail-queue
  exit 1
fi

echo ""
echo "========================================="
echo "    qmail Installation Complete!"
echo "========================================="
echo ""
echo "Hostname: $QMAIL_HOSTNAME"
echo ""
echo "Services:"
echo "  • qmail-send  - Mail delivery & queue"
echo "  • qmail-smtpd - SMTP server (port 25)"
echo ""
echo "Commands:"
echo "  Status:  /command/svstat /service/*"
echo "  Logs:    tail -f /var/log/qmail/current"
echo "  Queue:   qmail-qstat"
echo "  Test:    echo 'Hello' | qmail-inject root"
echo "  Helper:  qmail-helper status"
echo "  SMTP:    qmail-helper smtp-test <recipient@domain>"
echo "  Verify:  getenforce && ls -l /var/qmail/bin/qmail-queue"
echo ""
echo "SELinux: $SELINUX_POLICY_STATUS"
echo "WARNING: Relay is enabled for all connections!"
echo "Use qmail-helper config-set relay-localhost to secure it."
echo ""

echo "Post-install verification:"
if command -v getenforce >/dev/null 2>&1; then
  echo "  SELinux mode: $(getenforce)"
else
  echo "  SELinux mode: getenforce not available"
fi

if [ -e /var/qmail/bin/qmail-queue ]; then
  echo "  qmail-queue perms: $(ls -l /var/qmail/bin/qmail-queue)"
  echo "  qmail-queue mode check: PASS ($CURRENT_QMAIL_QUEUE_MODE)"
else
  echo "  qmail-queue perms: /var/qmail/bin/qmail-queue not found"
fi
