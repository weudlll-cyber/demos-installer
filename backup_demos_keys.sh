#!/bin/bash
mkdir -p ~/demos-keys

# Find and copy publickey
PUBKEY=$(find /root/node -type f -name 'publickey' | head -n 1)
if [ -n "$PUBKEY" ]; then
  cp "$PUBKEY" ~/demos-keys/publickey
  echo "✅ Backed up publickey from: $PUBKEY"
else
  echo "❌ publickey not found"
fi

# Find and copy privatekey
PRIVKEY=$(find /root/node -type f -name 'privatekey' | head -n 1)
if [ -n "$PRIVKEY" ]; then
  cp "$PRIVKEY" ~/demos-keys/privatekey
  chmod 600 ~/demos-keys/privatekey
  echo "✅ Backed up privatekey from: $PRIVKEY"
else
  echo "❌ privatekey not found"
fi

# Show results
ls -l ~/demos-keys
