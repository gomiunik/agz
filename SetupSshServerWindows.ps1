# --- CONFIGURATION ---
$NewPort = 2322  # Change port for better security to avoid scanners
# Backup server SSH key (you can find it on the server under the user 'backupuser')
$YourPublicKey = "ssh-ed25519 <paste-your-public-key-here> backup-server"
$SshdPath = "$env:SystemRoot\System32\OpenSSH\sshd.exe" #local path to sshd service after it has been provisioned

# 1. Install OpenSSH Server
Write-Host "Installing OpenSSH Server..." -ForegroundColor Cyan
$capability = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
if ($capability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name $capability.Name
}

# 1.a If sshd service didn't register, register it manually
if (!(Test-Path $SshdPath)) {
    Write-Error "sshd.exe not found at $SshdPath. Installation may have failed."
    return
}
$SshdService = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
if ($null -eq $SshdService) {
    Write-Host "Service 'sshd' not found. Manually registering..." -ForegroundColor Yellow
    
    # Register the service manually using New-Service
    New-Service -Name "sshd" `
                -BinaryPathName "$SshdPath" `
                -DisplayName "OpenSSH SSH Server" `
                -Description "OpenSSH based secure shell server" `
                -StartupType Automatic
    
    # Verify registration
    $SshdService = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
    if ($null -ne $SshdService) {
        Write-Host "Successfully registered 'sshd' service." -ForegroundColor Green
    } else {
        Write-Error "Failed to register 'sshd' service."
        return
    }
}

# 2. Configure the Service
if ($SshdService.Status -ne 'Running') {
    Start-Service sshd
}
Set-Service -Name sshd -StartupType 'Automatic'

# 3. Modify sshd_config
$configPath = "$env:ProgramData\ssh\sshd_config"
$config = Get-Content $configPath

# Update Port, Disable Passwords, Ensure Key Auth
$config = $config -replace '#Port 22', "Port $NewPort"
$config = $config -replace 'Port 22', "Port $NewPort"
$config = $config -replace '#PubkeyAuthentication yes', 'PubkeyAuthentication yes'
$config = $config -replace 'PubkeyAuthentication no', 'PubkeyAuthentication yes'
$config = $config -replace '#PasswordAuthentication yes', 'PasswordAuthentication no'

# Add strict Authentication Method (Disables Passwords entirely)
if (!($config -match "AuthenticationMethods publickey")) {
    $config += "`nAuthenticationMethods publickey"
}

# Ensure PasswordAuthentication is explicitly no
if ($config -match "PasswordAuthentication yes") {
    $config = $config -replace "PasswordAuthentication yes", "PasswordAuthentication no"
} else {
    $config += "`nPasswordAuthentication no"
}

$config | Set-Content $configPath

# 4. Handle SSH Keys for Administrators
$authKeyPath = "$env:ProgramData\ssh\administrators_authorized_keys"
$YourPublicKey | Set-Content $authKeyPath -Encoding Ascii

# CRITICAL: Set correct ACLs (Windows OpenSSH is very picky)
# Only SYSTEM and Administrators should have access.
$acl = Get-Acl $authKeyPath
$acl.SetAccessRuleProtection($true, $false) # Disable inheritance
$administratorsRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","Allow")
$systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM","FullControl","Allow")
$acl.SetAccessRule($administratorsRule)
$acl.SetAccessRule($systemRule)
$acl | Set-Acl $authKeyPath

# 5. Update Firewall
Write-Host "Configuring Firewall on port $NewPort..." -ForegroundColor Cyan
Remove-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
    -DisplayName "OpenSSH Server (Port $NewPort)" `
    -Enabled True `
    -Direction Inbound `
    -Protocol TCP `
    -Action Allow `
    -LocalPort $NewPort

# 6. Set PowerShell as default shell (Optional but recommended for your rsync/scripts)
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force

# 7. Restart Service to apply changes
Restart-Service sshd
Write-Host "Setup Complete. SSH is running on port $NewPort with Public Key only." -ForegroundColor Green