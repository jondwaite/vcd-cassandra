# Use existing openssl.exe from git (or change to your own one):
$OpenSSL    = 'C:\Program Files\git\mingw64\bin\openssl.exe'

# Bring in Cassandra cluster configuration variables
. .\cluster.ps1

# Subject Name (subj) root:
$SNRoot = "/C=NZ/ST=Canterbury/ST=Christchurch/O=Home/OU=Lab/"

# Generate RSA keys for each cluster node, will be named '<nodename>.key' in current folder
$CassNodes.GetEnumerator() | Sort-Object -Property Key | ForEach-Object {

    Write-Host -ForegroundColor DarkGreen ("Generating Key and CSR for $($_.Key):")

    if (Test-Path -Path "$($CertPath)$($_.Key).key" -PathType Leaf) {
        Write-Host -ForegroundColor Yellow ("Key file '$($CertPath)$($_.Key).key' already exists for $($_.Key), skipping.")
        Write-Host -ForegroundColor Yellow ("Delete this file if a new private key for $($_.Key) is required")
    } else {
        & $OpenSSL genpkey -out "$($CertPath)$($_.Key).key" -algorithm RSA -pkeyopt rsa_keygen_bits:4096
        Write-Host -ForegroundColor Green ("Created key for $($_.key)")
    }
  
    if (Test-Path -Path "$($CertPath)$($_.Key).csr" -PathType Leaf) {
        Write-Host -ForegroundColor Yellow ("CSR file '$($CertPath)$($_.Key).csr' already exists for $($_.Key), skipping.")
        Write-Host -ForegroundColor Yellow ("Delete this file if a new CSR for $($_.Key) is required")

    } else {
        & $OpenSSL req -config openssl.cnf -new -key "$($CertPath)$($_.Key).key" -subj "$($SNRoot)CN=$($_.Value)" -out "$($CertPath)$($_.Key).csr"
        Write-Host -ForegroundColor Green ("Created CSR for $($_.key)")
    }
}

Write-Host -ForegroundColor Green ("gencsrs.ps1 ended")