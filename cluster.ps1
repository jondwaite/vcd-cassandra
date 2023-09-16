# vCenter Deployment Target:
$vCenter    = '<fqdn of vcenter server>'          # vCenter where VMs will be deployed
$Cluster    = '<vCenter cluster to deploy to>'    # vCenter cluster where VMs will be deployed
$Folder     = '<VM folder for deployed VMs>'      # vCenter VM Folder for created VMs
$DataStore  = '<Datastore>'                       # vCenter Datastore for VMs
$Network    = '<Network>'                         # Portgroup for VM networking
$DiskFormat = 'Thin' # Allowed 'Thick', 'Thin', 'EagerZeroedThick', 'Thick2GB' or 'Thin2GB'

# Relative path for certificate files
$CertPath = "certs\"

# Cassandra Cluster Configuration:

# Hash of node names with static IP addresses to be assigned to each node
$CassNodes    = @{
    'lab-cass01'='10.0.210.71'
    'lab-cass02'='10.0.210.72'
    'lab-cass03'='10.0.210.73'
    'lab-cass04'='10.0.210.74'
    }

$CassSeeds   = '10.0.210.71,10.0.210.72'        # Servers to be configured as 'seed' Cassandra servers

# Get name last node for use in deploy script:
$CassLastNode = ($CassNodes.GetEnumerator() | Sort-Object -Property Key | Select-Object -Last 1).Name

# Optional public SSH key to be added to the 'ubuntu' user for passwordless login:
$CassSshKey  = '<ssh public key>'
  
$CassGW      = '10.0.210.1'                     # Default gateway
$CassNetMask = '/24'                            # Subnet mask bits
$CassDNS     = '10.0.210.10,10.0.210.20'        # DNS Servers (comma separated)
$CassDomain  = 'my.lab.domain.name'             # DNS domainname
$UbuntuPass  = 'VMware123!'                     # Password to be assigned to the local 'ubuntu' user
$CassPass    = 'VMware123!'                     # Password to be assigned to the cassandra database user
