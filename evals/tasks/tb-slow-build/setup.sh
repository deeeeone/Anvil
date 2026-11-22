#!/bin/bash
cat > slow_build.sh <<'EOT'
#!/bin/bash
# A build that takes about 50 seconds and prints progress the whole time.
mkdir -p dist
: > dist/.partial
for i in $(seq 1 25); do
  echo "[$(printf '%02d' $i)/25] compiling module-$i ..."
  sleep 2
  echo "module-$i:$((i * 7919 % 1000))" >> dist/.partial
done
mv dist/.partial dist/app.bin
echo "BUILD SUCCESSFUL"
EOT
chmod +x slow_build.sh
