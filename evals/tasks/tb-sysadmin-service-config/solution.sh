mkdir -p var/log/myservice etc/myservice/tls
openssl req -x509 -newkey rsa:2048 -nodes -days 400 -subj "/CN=myservice.local" -keyout etc/myservice/tls/server.key -out etc/myservice/tls/server.crt 2>/dev/null
chmod 600 etc/myservice/tls/server.key
sed -i '' -e 's/^port=.*/port=8443/' -e 's/^user=.*/user=svc-myservice/' -e 's/^workers=.*/workers=4/' -e 's/^allow_origin=.*/allow_origin=https:\/\/app.example.com/' etc/myservice/service.conf
