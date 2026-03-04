# qmail-install

Bootstraps `netqmail` from source with `daemontools` and `ucspi-tcp`.

## Supported Linux Flavors

- Rocky / RHEL-family (`dnf`)
- Debian / Ubuntu-family (`apt-get`)
- Alpine (`apk`)

## What This Installer Sets Up

- qmail users/groups and queue layout
- `netqmail` build and install from source
- `daemontools` supervision (`qmail-send`, `qmail-smtpd`)
- `ucspi-tcp` SMTP listener wiring
- `qmail-helper` command in PATH (`/usr/local/bin` and `/usr/bin`)
- SELinux policy adjustments when SELinux tooling is present

## Quick Start

```bash
chmod +x install.sh
sudo ./install.sh
```

Optional hostname override:

```bash
sudo QMAIL_HOSTNAME=mail.example.com ./install.sh
```

## Daily Operations

```bash
qmail-qstat
qmail-qread
/command/svstat /service/*
qmail-helper status
qmail-helper smtp-test you@example.com
```

## Security Note

The installer currently creates an open relay rule by default for convenience during bootstrap/testing.
Lock it down after install:

```bash
qmail-helper config-set relay-localhost
```

## Project Files

- `install.sh` — main installer
- `Vagrantfile` — local VM workflow

## License

See `LICENSE`.
