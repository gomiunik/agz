#!/bin/bash

# Configuration
REPORT_FILE="/var/www/html/pool-health.html"
POOL_NAME="backup-pool"

# Gather Data
FRAG=$(zpool list -H -o frag $POOL_NAME)
CAP=$(zpool list -H -o capacity $POOL_NAME)
COMP=$(zfs get -H -o value compressratio $POOL_NAME)
FREE=$(zfs list -H -o avail $POOL_NAME)
STATUS=$(zpool status $POOL_NAME)
CURRENT_DATE=$(date '+%Y-%m-%d %H:%M:%S')

# Generate HTML
cat <<EOF > $REPORT_FILE
<html>
<head>
    <style>
        body { font-family: sans-serif; background: #f4f4f4; padding: 20px; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
        .stat { font-size: 24px; font-weight: bold; color: #2c3e50; }
        pre { background: #eee; padding: 10px; overflow-x: auto; }
        .warning { color: red; }
    </style>
</head>
<body>
    <div class="card">
        <h1>ZFS Storage Vault Health</h1>
        <p><strong>Last Updated:</strong> $(date)</p>
        <hr>
        <p>Fragmentation: <span class="stat">$FRAG</span></p>
        <p>Compression Ratio: <span class="stat">$COMP</span></p>
        <p>Capacity Used: <span class="stat">$CAP</span></p>
        <p>Available Space: <span class="stat">$FREE</span></p>
        <hr>
        <h3>Raw Pool Status:</h3>
        <pre>$STATUS</pre>
        <hr>
        <p>Last update on: $CURRENT_DATE</p>
    </div>
    <h3>Backup pools</h3>
    <div class="card"><pre>
EOF

zfs list -o name,used,refer,compressratio,mountpoint -r backup-pool >> $REPORT_FILE

cat <<EOF >> $REPORT_FILE
</div>
</pre>
<h3>Snapshots</h3>
<div class="card"><pre>
EOF

zfs list -t snapshot -o name,creation -s creation -r backup-pool >> $REPORT_FILE

cat <<EOF >> $REPORT_FILE
</pre>
</div>
</body>
</html>
EOF