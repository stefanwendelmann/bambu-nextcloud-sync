# Stand-in for a Bambu Lab printer: vsftpd with implicit TLS on port 990, a self-signed
# certificate, mandatory TLS session reuse on data connections and no write access.
FROM alpine:3.24
RUN apk add --no-cache vsftpd openssl \
    && adduser -D -h /srv/ftp bblp \
    && openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=MOCK-PRINTER" \
        -keyout /etc/vsftpd/key.pem -out /etc/vsftpd/cert.pem
COPY vsftpd.conf /etc/vsftpd/vsftpd.conf
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["sh", "/entrypoint.sh"]
