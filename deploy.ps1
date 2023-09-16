# Deploy an Apache Cassandra cluster using Ubuntu 22.04 LTS OVA image
#
# Requires:
#   - Downloaded Ubuntu appliance OVA image file with path in $OVAFile
#   - Internet access from deployed nodes to grab package updates from archive.ubuntu.com
#     and cassandra files from debian.cassandra.apache.org
#   - openssl (configured path in gencsrs.ps1)
#   - You must be connected to vCenter (Connect-VIServer...) prior to running this script

# Node sizing configuration:
$nodeHD     = 60                                  # Node disk size (in GB) - minimum 10GB
$nodeCPUs   = 2                                   # Number of CPUs per Node
$nodeMem    = 8                                   # Node vRAM (in GB)

# OVA image & tools:
$OVAFile    = 'C:\OVA\ubuntu-22.04-server-cloudimg-amd64.ova'

# Bring in vCenter target and Cassandra cluster definitions (dot source):
. .\cluster.ps1

# Check and read certificate files:
Write-Host -ForegroundColor DarkGreen ("Checking we have all node key and certificate files")
if (-not(Test-Path -Path "$($CertPath)chain.crt")) {
  Write-Host -ForegroundColor Red ("Can't find '$($CertPath)chain.crt' file containing the Root CA / Issuing CA certificates, exiting")
  Break
}
$CertChain = Get-Content -Raw -Path "$($CertPath)chain.crt"
$CertChainBytes = [System.Text.Encoding]::UTF8.GetBytes($CertChain)
$CertChainB64 = [Convert]::ToBase64String($CertChainBytes)

$CassCerts = @{}
$CassNodes.GetEnumerator() | Sort-Object -Property Key | ForEach-Object {  
  if (-not(Test-Path -Path "$($CertPath)$($_.Key).key" -PathType Leaf)) {
    Write-Host -ForegroundColor Red ("No SSL key found for $($_.Key), did you run 'gencsrs.ps1' first?, exiting")
    Break
  }
  if (-not(Test-Path -Path "$($CertPath)$($_.Key).crt" -PathType Leaf)) {
    Write-Host -ForegroundColor Red ("Missing certificate file '$($CertPath)$($_.Key).crt', these should be generated from the Issuing CA from '$($_.Key).csr', exiting")
    Break
  }
  $key = Get-Content -Raw -Path "$($CertPath)$($_.Key).key"
  $cert = Get-Content -Raw -Path "$($CertPath)$($_.Key).crt"
  $NodeCert = $key + $cert + $CertChain
  $NodeCertBytes = [System.Text.Encoding]::UTF8.GetBytes($NodeCert)
  $NodeCertB64 = [Convert]::ToBase64String($NodeCertBytes)
  $CassCerts[$_.Key] = $NodeCertB64
} 
Write-Host -ForegroundColor Green ("Found all required key and certificate files, continuing")

$OVFConfig = Get-OvfConfiguration $OVAFile

# Deploy each node in turn using cloud-init:
$CassNodes.GetEnumerator() | Sort-Object -Property Key | ForEach-Object {
  Write-Host -ForegroundColor DarkGreen ("Creating VM $($_.key) ($($_.value))")

  # Build cloud-init cloud-config (user-data):
  $CloudConfig = 
@"
#cloud-config
package_update: true
package_upgrade: true

preserve_hostname: false
hostname: $($_.key)
fqdn: $($_.key).$($CassDomain)

timezone: "Pacific/Auckland"

chpasswd: {expire: False}
ssh_pwath: True

apt:
  sources:
    cassandra:
      source: deb https://debian.cassandra.apache.org 41x main
      keyid: 32F35CB2F546D93E

packages: ['default-jdk','net-tools','cassandra']

write_files:

- content: |
    network: {config: disabled}
  permissions: '0644'
  path: /etc/cloud/cloud.cfg.d/99-custom-networking.cfg

- content: |
    network:
      version: 2
      ethernets:
        ens192:
          dhcp4: no
          addresses: [$($_.value)$($CassNetMask)]
          nameservers:
            addresses: [$($CassDNS)]
            search: [$($CassDomain)]
          routes:
            - to: default
              via: $($CassGW)
  permissions: '0644'
  path: /etc/netplan/network-config.yaml

- content: $($CassCerts[$_.Key])
  permissions: '0644'
  encoding: b64
  path: /etc/cassandra/certs/$($_.Key).pem
  
- content: $($CertChainB64)
  permissions: '0644'
  encoding: b64
  path: /etc/cassandra/certs/truststore.pem

- content: |
    cluster_name: 'vCD Performance Metrics'
    authenticator: PasswordAuthenticator
    authorizer: CassandraAuthorizer
    partitioner: org.apache.cassandra.dht.Murmur3Partitioner
    seed_provider:
      - class_name: org.apache.cassandra.locator.SimpleSeedProvider
        parameters:
          - seeds: "$($CassSeeds)"
    listen_address: $($_.value)
    rpc_address: $($_.value)
    endpoint_snitch: GossipingPropertyFileSnitch
    commitlog_sync: periodic
    commitlog_sync_period: 10s
    server_encryption_options:
      ssl_context_factory:
        class_name: org.apache.cassandra.security.PEMBasedSslContextFactory
      internode_encryption: all
      keystore: /etc/cassandra/certs/$($_.Key).pem
      truststore: /etc/cassandra/certs/truststore.pem
    client_encryption_options:
      ssl_context_factory:
        class_name: org.apache.cassandra.security.PEMBasedSslContextFactory
      enabled: true
      optional: false
      keystore: /etc/cassandra/certs/$($_.Key).pem
      truststore: /etc/cassandra/certs/truststore.pem
  path: /etc/cassandra/cassandra.yaml
  permissions: '0644'

"@

# If we're deploying the last node create a script to set cluster password on 'cassandra' user:
if ($($_.key) -eq $CassLastNode) {
  $CloudConfig +=
@"
- content: |
    #!/usr/bin/bash
    systemctl restart cassandra
    echo "Waiting for Cassandra service to be listending on tcp/9042"
    while ! netstat -tna | grep 'LISTEN\>' | grep -q ':9042\>'
    do
      echo -n "." && sleep 5
    done
    echo "Cassandra service is available, sleeping 30 seconds before attempting password change..."
    sleep 30
    export SSL_CERTFILE=/etc/cassandra/certs/truststore.pem
    cqlsh $($_.value) -u cassandra -p 'cassandra' --ssl -e "ALTER USER cassandra WITH PASSWORD '$($CassPass)';"
    rm -- `$0
  permissions: '0755'
  path: /etc/cassandra/firstboot.sh

"@ }

  $CloudConfig +=
@"
runcmd:
  - |
    rm /etc/netplan/50-cloud-init.yaml
    netplan generate
    netplan apply
    echo "blacklist floppy" | tee /etc/modprobe.d/blacklist-floppy.conf
    dpkg-reconfigure initramfs-tools
    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw
    ufw enable
    ufw default deny incoming
    ufw allow ssh
    ufw allow 7000/tcp
    ufw allow 7001/tcp
    ufw allow 9042/tcp
    ufw allow 7199/tcp

"@

  if ($($_.key) -eq $CassLastNode) {
    $CloudConfig +=
@"
    /etc/cassandra/firstboot.sh

"@
  }

  $CloudConfig += 
@"
power_state:
  mode: reboot

"@

  # Handy for debugging to see cloud-init user-data (uncomment if needed):
  #Write-Host -ForegroundColor Cyan ($CloudConfig)

  $CloudConfigBytes = [System.Text.Encoding]::UTF8.GetBytes($CloudConfig)
  $CloudConfigB64 = [Convert]::ToBase64String($CloudConfigBytes)

  $OVFConfig.NetworkMapping.VM_Network.Value  = $Network
  $OVFConfig.Common.hostname.Value            = $($_.key)
  $OVFConfig.Common.instance_id.Value         = $($_.key)
  $OVFConfig.Common.public_keys.Value         = $($CassSshKey)
  $OVFConfig.Common.password.Value            = $($UbuntuPass)
  $OVFConfig.Common.user_data.Value           = $($CloudConfigB64)

  # Deploy the VM:
  $VMHost = Get-Cluster -Name $Cluster | Get-VMHost | Get-Random
  $VMfolder = Get-Folder -Name $folder

  $CassVM = Import-VApp -VMHost $VMHost `
    -Source $OVAFile `
    -OvfConfiguration $OVFConfig `
    -InventoryLocation $VMfolder `
    -Name $($_.key) `
    -Datastore $($DataStore) `
    -DiskStorageFormat $DiskFormat

  # Expand the VM hard disk to specified size:
  Write-Host -ForegroundColor Green ("Expanding VM hard disk to $($nodeHD)GB")
  $CassVM | Get-HardDisk | Set-HardDisk -CapacityGB $nodeHD -Confirm:$false

  # Set node VM CPU/RAM:
  Write-Host -ForegroundColor Green ("Setting VM vCPU=$($nodeCPUs) cores, vRAM=$($nodeMem)GB")
  $CassVM | Set-VM -MemoryGB $nodeMem -NumCpu $nodeCPUs -Confirm:$false | Out-Null

  # PowerOn the VM:
  Write-Host -ForegroundColor Green ("Starting VM $($CassVM.Name)")
  $CassVM | Start-VM | Out-Null

  # For all but last node, wait between deployments to give Cassandra time to initialise:
  if ($_.key -ne $CassLastNode) {
    Write-Host -ForegroundColor Yellow ("Waiting 5 minutes before next deployment to allow cassandra cluster to settle")
    Start-Sleep -Seconds 300
  }
}

Write-Host -ForegroundColor DarkGreen ("All nodes deployed, check for proper operation then configure VCD:")
Write-Host ("/opt/vmware/vcloud-director/bin/cell-management-tool cassandra \")
Write-Host ("  --configure --ttl 30 --port 9042 --create-schema \")
Write-Host ("  --cluster-nodes $($($CassNodes.Values | Sort-Object) -join ',') \")
Write-Host ("  --username cassandra --password $($CassPass)")
Write-Host -ForegroundColor DarkGreen ("`nVCD services will need to be restarted on each cell after configuration")
