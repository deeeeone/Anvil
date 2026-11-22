#!/bin/bash
set -e
cat > validate.sh <<'EOT'
#!/bin/bash
# Validates the service layout. Exit 0 only if everything is right.
fail() { echo "FAIL: $1"; exit 1; }
CONF=etc/myservice/service.conf
[ -f "$CONF" ] || fail "missing $CONF"
get() { grep -E "^$1=" "$CONF" | head -1 | cut -d= -f2-; }
[ "$(get port)" -ge 1024 ] 2>/dev/null && [ "$(get port)" -le 65535 ] || fail "port must be 1024-65535"
[ "$(get user)" = "svc-myservice" ] || fail "user must be svc-myservice"
[ "$(get workers)" -ge 2 ] 2>/dev/null || fail "workers must be at least 2"
LOGDIR=$(get log_dir); [ -d "$LOGDIR" ] || fail "log_dir $LOGDIR is not a directory"
[ -w "$LOGDIR" ] || fail "log_dir not writable"
CERT=$(get tls_cert); KEY=$(get tls_key)
[ -f "$CERT" ] && [ -f "$KEY" ] || fail "tls_cert/tls_key files must exist"
perm=$(stat -f '%Lp' "$KEY"); [ "$perm" = "600" ] || fail "tls_key must be mode 600 (is $perm)"
subj=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null) || fail "tls_cert is not a certificate"
echo "$subj" | grep -q "CN *= *myservice.local" || fail "certificate CN must be myservice.local ($subj)"
openssl x509 -in "$CERT" -noout -checkend $((300*24*3600)) >/dev/null || fail "certificate must be valid for at least 300 more days"
mod_c=$(openssl x509 -in "$CERT" -noout -modulus 2>/dev/null | sed 's/Modulus=//'); mod_k=$(openssl rsa -in "$KEY" -noout -modulus 2>/dev/null | sed 's/Modulus=//')
if [ -z "$mod_c" ]; then mod_c=$(openssl x509 -in "$CERT" -noout -pubkey | openssl pkey -pubin -outform der | shasum); mod_k=$(openssl pkey -in "$KEY" -pubout -outform der | shasum); fi
[ "$mod_c" = "$mod_k" ] || fail "certificate and key don't match"
[ "$(get allow_origin)" != "*" ] || fail "allow_origin must not be *"
grep -q '^# managed by ops$' "$CONF" || fail "the conf must keep its '# managed by ops' line"
echo "OK"
EOT
chmod +x validate.sh
mkdir -p etc/myservice
cat > etc/myservice/service.conf <<'EOT'
# managed by ops
port=80
user=root
workers=1
log_dir=var/log/myservice
tls_cert=etc/myservice/tls/server.crt
tls_key=etc/myservice/tls/server.key
allow_origin=*
EOT
