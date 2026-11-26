#!/bin/sh
set -eu
printf 'bblp:%s\n' "$FTP_PASSWORD" | chpasswd >/dev/null 2>&1
touch /var/log/vsftpd.log
exec vsftpd /etc/vsftpd/vsftpd.conf
